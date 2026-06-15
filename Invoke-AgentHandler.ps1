#requires -Version 5.1
<#
.SYNOPSIS
    Bundles human-readable SQL Agent job source files into deployable T-SQL scripts.

.DESCRIPTION
    Invoke-AgentHandler reads a directory of "job source" folders and emits one ready-to-deploy
    T-SQL script per job. Each job folder contains:

        job.json            Job-level metadata (name, category, description, schedules).
        notifications.json  (optional) Operator notification settings.
        nn_<step name>.sql  A T-SQL job step. The nn_ prefix sets the step number/order.
        nn_<step name>.ps1  A PowerShell job step (PowerShell subsystem).

    Step files may carry "special comment" directives on their own lines to control
    advanced job-step settings. These lines are parsed out and removed from the command
    body before it is embedded in the generated script. The directive marker matches the
    step language so it stays a valid comment: a leading "-->" in a .sql step, or a
    leading "##" then ">" in a .ps1 step.

        --> StepName:      <step name>          (default: file name, sans the nn_ prefix)
        --> Database:      <DBName>             (TSQL steps only; default: master)
        --> Runas:         <proxy account>      (default: omitted / runs as Agent service)
        --> SuccessAction: next|success|failure (default: next)
        --> FailAction:    next|success|failure (default: failure)
        --> RetryAttempts: <N>                  (default: 0)
        --> RetryInterval: <N minutes>          (default: 0)

    Presence-only flags (include the line to turn the option on):

        --> LogToTable
        --> AppendOutputToExistingEntryInTable
        --> IncludeStepOutputInHistory

    The generated script is idempotent: it calls the Agent_Upsert_* helper procedures,
    which create each object if it's missing and update it in place otherwise. Re-running
    a generated script against the same instance reconciles the job to the source files.

.PARAMETER SourcePath
    Path to the job-source directory. Defaults to .\job-source relative to this script.

.PARAMETER OutputPath
    Path to the directory where generated .sql files are written. Defaults to
    .\job-tsql relative to this script. Created if it does not exist.

.PARAMETER JobName
    Optional. Build only the job folder(s) whose directory name matches this value
    (supports wildcards). Default builds every folder under SourcePath.

.PARAMETER HelperDatabase
    Name of the database that holds the Agent_Upsert_* helper procedures. The generated
    scripts call e.g. [<HelperDatabase>].dbo.Agent_Upsert_Job. Defaults to 'dba'; rarely
    needs to be changed.

.EXAMPLE
    .\Invoke-AgentHandler.ps1

    Builds every job under .\job-source into .\job-tsql.

.EXAMPLE
    .\Invoke-AgentHandler.ps1 -SourcePath .\job-source -OutputPath .\out -JobName scratch-db-purge

    Builds only the scratch-db-purge job folder.

.NOTES
    Limitations (by design): no replication-agent job support, no MSX/multiserver support.
#>
[CmdletBinding()]
param(
    [string] $SourcePath,
    [string] $OutputPath,
    [string] $JobName = '*',
    [string] $HelperDatabase = 'dba'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve path defaults relative to this script. $PSScriptRoot can be empty in some
# hosts, so fall back to the script file's directory, then the current location.
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($SourcePath)) { $SourcePath = Join-Path $scriptDir 'job-source' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $scriptDir 'job-tsql' }

#region Helpers ----------------------------------------------------------------

# Escape a string for safe embedding inside a T-SQL N'...' literal.
function ConvertTo-SqlLiteral {
    param([AllowNull()][string] $Value)
    if ($null -eq $Value) { return 'NULL' }
    return "N'" + ($Value -replace "'", "''") + "'"
}

# Map a friendly action keyword to an sp_add_jobstep on_*_action code.
#   next    -> 3 (go to the next step)         | on the last step "next" collapses to quit
#   success -> 1 (quit reporting success)
#   failure -> 2 (quit reporting failure)
function Get-StepActionCode {
    param(
        [Parameter(Mandatory)][ValidateSet('next', 'success', 'failure')][string] $Action,
        [Parameter(Mandatory)][bool] $IsLastStep,
        [Parameter(Mandatory)][ValidateSet('success', 'failure')][string] $LastStepCollapse
    )
    switch ($Action) {
        'success' { return 1 }
        'failure' { return 2 }
        'next' {
            if ($IsLastStep) { if ($LastStepCollapse -eq 'success') { return 1 } else { return 2 } }
            return 3
        }
    }
}

# Convert structured schedule JSON into the freq_* arguments sp_add_jobschedule wants.
function ConvertTo-ScheduleArgs {
    param([Parameter(Mandatory)] $Schedule)

    $dayBits = @{
        sunday = 1; monday = 2; tuesday = 4; wednesday = 8
        thursday = 16; friday = 32; saturday = 64
    }

    $frequency = ([string] $Schedule.frequency).ToLowerInvariant()
    # "every N" recurrence multiplier. Reads naturally with frequency:
    #   weekly + everyN 2 = every 2 weeks; daily + everyN 3 = every 3 days. Default 1.
    $everyN = if ($Schedule.PSObject.Properties.Name -contains 'everyN' -and $Schedule.everyN) { [int] $Schedule.everyN } else { 1 }

    switch ($frequency) {
        'daily' {
            $freqType = 4
            $freqInterval = $everyN          # every N days
            $recurrence = 0
        }
        'weekly' {
            $freqType = 8
            if (-not ($Schedule.PSObject.Properties.Name -contains 'daysOfWeek') -or -not $Schedule.daysOfWeek) {
                throw "Weekly schedule '$($Schedule.name)' must specify daysOfWeek."
            }
            $bitmask = 0
            foreach ($d in $Schedule.daysOfWeek) {
                $key = ([string] $d).ToLowerInvariant()
                if (-not $dayBits.ContainsKey($key)) { throw "Unknown day of week '$d' in schedule '$($Schedule.name)'." }
                $bitmask = $bitmask -bor $dayBits[$key]
            }
            $freqInterval = $bitmask
            $recurrence = $everyN            # every N weeks
        }
        'monthly' {
            $freqType = 16
            if (-not ($Schedule.PSObject.Properties.Name -contains 'dayOfMonth') -or -not $Schedule.dayOfMonth) {
                throw "Monthly schedule '$($Schedule.name)' must specify dayOfMonth (1-31)."
            }
            $freqInterval = [int] $Schedule.dayOfMonth
            $recurrence = $everyN            # every N months
        }
        default {
            throw "Unsupported schedule frequency '$($Schedule.frequency)' in schedule '$($Schedule.name)'. Use daily, weekly, or monthly."
        }
    }

    # Time "HH:MM" or "HH:MM:SS" -> integer HHMMSS for @active_start_time.
    $time = if ($Schedule.PSObject.Properties.Name -contains 'time' -and $Schedule.time) { [string] $Schedule.time } else { '00:00' }
    $parts = $time.Split(':')
    $hh = [int] $parts[0]
    $mm = if ($parts.Count -ge 2) { [int] $parts[1] } else { 0 }
    $ss = if ($parts.Count -ge 3) { [int] $parts[2] } else { 0 }
    $startTime = ($hh * 10000) + ($mm * 100) + $ss

    return [pscustomobject]@{
        FreqType        = $freqType
        FreqInterval    = $freqInterval
        FreqRecurrence  = $recurrence
        ActiveStartTime = $startTime
    }
}

# Parse the leading "<marker> Key: Value" directives out of a step file.
# The directive marker depends on the step language so it reads as a comment in that
# language: "-->" for T-SQL (.sql), "##>" for PowerShell (.ps1).
# Returns the settings plus the command body with directive lines removed.
function Read-StepFile {
    param([Parameter(Mandatory)][System.IO.FileInfo] $File)

    $marker = if ($File.Extension -ieq '.ps1') { '##>' } else { '-->' }
    $directiveRegex = '^\s*' + [regex]::Escape($marker) + '\s*(?<key>\w+)\s*:?\s*(?<val>.*?)\s*$'

    $settings = [ordered]@{
        StepName                          = $null
        Database                          = 'master'
        Runas                             = $null
        SuccessAction                     = 'next'
        FailAction                        = 'failure'
        RetryAttempts                     = 0
        RetryInterval                     = 0
        LogToTable                        = $false
        AppendOutputToExistingEntryInTable = $false
        IncludeStepOutputInHistory        = $false
    }

    $valueKeys = 'StepName', 'Database', 'Runas', 'SuccessAction', 'FailAction', 'RetryAttempts', 'RetryInterval'
    $flagKeys  = 'LogToTable', 'AppendOutputToExistingEntryInTable', 'IncludeStepOutputInHistory'

    $bodyLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $File.FullName)) {
        $m = [regex]::Match($line, $directiveRegex)
        if (-not $m.Success) {
            $bodyLines.Add($line)
            continue
        }
        $key = $m.Groups['key'].Value
        $val = $m.Groups['val'].Value
        $matched = $valueKeys | Where-Object { $_ -ieq $key } | Select-Object -First 1
        if ($matched) {
            $settings[$matched] = $val
            continue
        }
        $matchedFlag = $flagKeys | Where-Object { $_ -ieq $key } | Select-Object -First 1
        if ($matchedFlag) {
            $settings[$matchedFlag] = $true
            continue
        }
        Write-Warning "  Unknown directive '$marker $key' in $($File.Name); leaving the line in the command body."
        $bodyLines.Add($line)
    }

    # Normalize / validate the value-typed settings.
    foreach ($actionKey in 'SuccessAction', 'FailAction') {
        $settings[$actionKey] = ([string] $settings[$actionKey]).ToLowerInvariant().Trim()
        if ($settings[$actionKey] -notin 'next', 'success', 'failure') {
            throw "Invalid $actionKey '$($settings[$actionKey])' in $($File.Name). Use next, success, or failure."
        }
    }
    $settings.RetryAttempts = [int] $settings.RetryAttempts
    $settings.RetryInterval = [int] $settings.RetryInterval
    if ([string]::IsNullOrWhiteSpace([string] $settings.Runas)) { $settings.Runas = $null }
    if ([string]::IsNullOrWhiteSpace([string] $settings.Database)) { $settings.Database = 'master' }
    if ([string]::IsNullOrWhiteSpace([string] $settings.StepName)) { $settings.StepName = $null }
    else { $settings.StepName = ([string] $settings.StepName).Trim() }

    return [pscustomobject]@{
        Settings = $settings
        Command  = ($bodyLines -join "`r`n").Trim()
    }
}

# Compute the sp_add_jobstep @flags bitmask from the boolean directives.
#   8  = write log to table (overwrite)
#   16 = write log to table (append)  -- replaces 8 when AppendOutputToExistingEntryInTable
#   32 = include step output in job history
function Get-StepFlags {
    param([Parameter(Mandatory)] $Settings)
    $flags = 0
    if ($Settings.LogToTable) {
        if ($Settings.AppendOutputToExistingEntryInTable) { $flags = $flags -bor 16 } else { $flags = $flags -bor 8 }
    }
    if ($Settings.IncludeStepOutputInHistory) {
        $flags = $flags -bor 32
    }
    return $flags
}

#endregion Helpers -------------------------------------------------------------

#region Per-job build ----------------------------------------------------------

function Build-JobScript {
    param(
        [Parameter(Mandatory)][System.IO.DirectoryInfo] $JobFolder,
        [Parameter(Mandatory)][string] $HelperDatabase
    )

    # Qualified prefix for the idempotent helper procs, e.g. [dba].dbo.
    $helper = "[$HelperDatabase].dbo."

    $metaPath = Join-Path $JobFolder.FullName 'job.json'
    if (-not (Test-Path -LiteralPath $metaPath)) {
        throw "Job folder '$($JobFolder.Name)' is missing job.json."
    }
    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json

    foreach ($required in 'name', 'category') {
        if (-not ($meta.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace([string] $meta.$required)) {
            throw "job.json in '$($JobFolder.Name)' is missing required property '$required'."
        }
    }

    $jobName     = [string] $meta.name
    $category    = [string] $meta.category
    $description = if ($meta.PSObject.Properties.Name -contains 'description') { [string] $meta.description } else { '' }
    $enabled     = if ($meta.PSObject.Properties.Name -contains 'enabled') { [bool] $meta.enabled } else { $true }
    $owner       = if ($meta.PSObject.Properties.Name -contains 'owner' -and -not [string]::IsNullOrWhiteSpace([string] $meta.owner)) { [string] $meta.owner } else { 'sa' }

    # Optional email notifications. These are job-level properties, so they ride along
    # on the Agent_Upsert_Job call rather than a separate update.
    $emailLevel = 0
    $emailOperator = $null
    $notifyPath = Join-Path $JobFolder.FullName 'notifications.json'
    if (Test-Path -LiteralPath $notifyPath) {
        $notify = Get-Content -LiteralPath $notifyPath -Raw | ConvertFrom-Json
        $levelMap = @{ never = 0; success = 1; failure = 2; always = 3 }
        if ($notify.PSObject.Properties.Name -contains 'email' -and $notify.email) {
            $on = ([string]$notify.email.on).ToLowerInvariant()
            if (-not $levelMap.ContainsKey($on)) { throw "notifications.json email.on '$on' must be never/success/failure/always." }
            $emailLevel = $levelMap[$on]
            $emailOperator = [string] $notify.email.operator
        }
    }

    # Collect numbered step files. nn_ prefix drives ordering and step id.
    $stepFiles = @(Get-ChildItem -LiteralPath $JobFolder.FullName -File |
        Where-Object { $_.Extension -in '.sql', '.ps1' -and $_.BaseName -match '^\d+' } |
        Sort-Object { [int]([regex]::Match($_.BaseName, '^\d+').Value) })

    if (-not $stepFiles) {
        throw "Job folder '$($JobFolder.Name)' has no numbered step files (expected nn_<name>.sql or .ps1)."
    }

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("/*")
    $null = $sb.AppendLine("    SQL Agent job deploy script -- generated by Invoke-AgentHandler.ps1")
    $null = $sb.AppendLine("    Source folder: $($JobFolder.Name)")
    $null = $sb.AppendLine("    Job name:      $jobName")
    $null = $sb.AppendLine("    Idempotent: reconciles the job via the ${helper}Agent_Upsert_* procedures.")
    $null = $sb.AppendLine("    MACHINE-GENERATED by SQL Agent's Handler -- DO NOT EDIT. Edit job-source instead.")
    $null = $sb.AppendLine("*/")
    $null = $sb.AppendLine("SET NOCOUNT ON;")
    $null = $sb.AppendLine("SET XACT_ABORT ON;")
    $null = $sb.AppendLine("GO")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("BEGIN TRY")
    $null = $sb.AppendLine("    BEGIN TRANSACTION;")
    $null = $sb.AppendLine()

    # Ensure the job category exists, then upsert the job itself.
    $null = $sb.AppendLine("    EXEC ${helper}Agent_Upsert_JobCategory @name = $(ConvertTo-SqlLiteral $category);")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("    EXEC ${helper}Agent_Upsert_Job")
    $null = $sb.AppendLine("        @job_name = $(ConvertTo-SqlLiteral $jobName),")
    $null = $sb.AppendLine("        @enabled = $([int][bool]$enabled),")
    $null = $sb.AppendLine("        @description = $(ConvertTo-SqlLiteral $description),")
    $null = $sb.AppendLine("        @category_name = $(ConvertTo-SqlLiteral $category),")
    $null = $sb.AppendLine("        @owner_login_name = $(ConvertTo-SqlLiteral $owner),")
    $null = $sb.AppendLine("        @notify_level_email = $emailLevel,")
    $operatorArg = if ([string]::IsNullOrWhiteSpace($emailOperator)) { 'NULL' } else { ConvertTo-SqlLiteral $emailOperator }
    $null = $sb.AppendLine("        @notify_email_operator_name = $operatorArg;")
    $null = $sb.AppendLine()

    # Steps.
    $stepCount = $stepFiles.Count
    for ($i = 0; $i -lt $stepCount; $i++) {
        $file = $stepFiles[$i]
        $stepId = $i + 1
        $isLast = ($stepId -eq $stepCount)

        $parsed = Read-StepFile -File $file
        $settings = $parsed.Settings

        # Step name comes from the StepName directive. Fall back to the file base name
        # (with the leading "nn_" stripped) when the directive is absent.
        if ($settings.StepName) {
            $stepName = $settings.StepName
        }
        else {
            $stepName = [regex]::Replace($file.BaseName, '^\d+[_\-\s]*', '').Trim()
            if ([string]::IsNullOrWhiteSpace($stepName)) { $stepName = $file.BaseName }
        }

        $subsystem = if ($file.Extension -ieq '.ps1') { 'PowerShell' } else { 'TSQL' }

        $onSuccess = Get-StepActionCode -Action $settings.SuccessAction -IsLastStep $isLast -LastStepCollapse 'success'
        $onFail    = Get-StepActionCode -Action $settings.FailAction    -IsLastStep $isLast -LastStepCollapse 'failure'
        $flags     = Get-StepFlags -Settings $settings

        # @database_name applies to TSQL only; @proxy_name only when a run-as is set.
        # NULL omits each in the upsert proc.
        $dbArg    = if ($subsystem -eq 'TSQL') { ConvertTo-SqlLiteral $settings.Database } else { 'NULL' }
        $proxyArg = if ($settings.Runas) { ConvertTo-SqlLiteral $settings.Runas } else { 'NULL' }

        $null = $sb.AppendLine("    -- Step $stepId : $stepName  ($subsystem)")
        $null = $sb.AppendLine("    EXEC ${helper}Agent_Upsert_JobStep")
        $null = $sb.AppendLine("        @job_name = $(ConvertTo-SqlLiteral $jobName),")
        $null = $sb.AppendLine("        @step_id = $stepId,")
        $null = $sb.AppendLine("        @step_name = $(ConvertTo-SqlLiteral $stepName),")
        $null = $sb.AppendLine("        @subsystem = $(ConvertTo-SqlLiteral $subsystem),")
        $null = $sb.AppendLine("        @command = $(ConvertTo-SqlLiteral $parsed.Command),")
        $null = $sb.AppendLine("        @database_name = $dbArg,")
        $null = $sb.AppendLine("        @proxy_name = $proxyArg,")
        $null = $sb.AppendLine("        @on_success_action = $onSuccess,")
        $null = $sb.AppendLine("        @on_fail_action = $onFail,")
        $null = $sb.AppendLine("        @retry_attempts = $($settings.RetryAttempts),")
        $null = $sb.AppendLine("        @retry_interval = $($settings.RetryInterval),")
        $null = $sb.AppendLine("        @flags = $flags;")
        $null = $sb.AppendLine()
    }

    # Prune steps removed from source. Source defines steps 1..$stepCount, so any step
    # on the live job with a higher id was deleted from job-source and should go too.
    # We build one sp_delete_jobstep call per orphan and run them via sp_executesql.
    # Each call deletes step ($stepCount + 1): sp_delete_jobstep renumbers the remaining
    # higher steps down, so the next orphan slides into that slot. Emitting one identical
    # call per orphan therefore needs no particular ordering. For a brand-new job this
    # finds nothing (no-op).
    $pruneFromId = $stepCount + 1
    $null = $sb.AppendLine("    -- Prune any steps beyond the $stepCount defined in source.")
    $null = $sb.AppendLine("    DECLARE @jobName SYSNAME = $(ConvertTo-SqlLiteral $jobName);")
    $null = $sb.AppendLine("    DECLARE @pruneSql NVARCHAR(MAX) = N'';")
    $null = $sb.AppendLine("    SELECT @pruneSql = @pruneSql")
    $null = $sb.AppendLine("            + N'EXEC msdb.dbo.sp_delete_jobstep @job_name = @jn, @step_id = $pruneFromId;'")
    $null = $sb.AppendLine("            + NCHAR(13) + NCHAR(10)")
    $null = $sb.AppendLine("    FROM msdb.dbo.sysjobsteps AS js")
    $null = $sb.AppendLine("    JOIN msdb.dbo.sysjobs AS j ON j.job_id = js.job_id")
    $null = $sb.AppendLine("    WHERE j.[name] = @jobName")
    $null = $sb.AppendLine("      AND js.step_id > $stepCount;")
    $null = $sb.AppendLine("    IF (@pruneSql <> N'')")
    $null = $sb.AppendLine("        EXEC sys.sp_executesql @pruneSql, N'@jn SYSNAME', @jn = @jobName;")
    $null = $sb.AppendLine()

    # Schedules (0..N).
    if ($meta.PSObject.Properties.Name -contains 'schedules' -and $meta.schedules) {
        foreach ($sched in $meta.schedules) {
            $schedName = if ($sched.PSObject.Properties.Name -contains 'name' -and $sched.name) { [string] $sched.name } else { "$jobName schedule" }
            $schedArgs = ConvertTo-ScheduleArgs -Schedule $sched
            $null = $sb.AppendLine("    EXEC ${helper}Agent_Upsert_JobSchedule")
            $null = $sb.AppendLine("        @job_name = $(ConvertTo-SqlLiteral $jobName),")
            $null = $sb.AppendLine("        @name = $(ConvertTo-SqlLiteral $schedName),")
            $null = $sb.AppendLine("        @enabled = 1,")
            $null = $sb.AppendLine("        @freq_type = $($schedArgs.FreqType),")
            $null = $sb.AppendLine("        @freq_interval = $($schedArgs.FreqInterval),")
            $null = $sb.AppendLine("        @freq_recurrence_factor = $($schedArgs.FreqRecurrence),")
            $null = $sb.AppendLine("        @active_start_time = $($schedArgs.ActiveStartTime);")
            $null = $sb.AppendLine()
        }
    }

    # Target the local server, then commit.
    $null = $sb.AppendLine("    EXEC ${helper}Agent_Upsert_JobServer @job_name = $(ConvertTo-SqlLiteral $jobName), @server_name = N'(LOCAL)';")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("    COMMIT TRANSACTION;")
    $null = $sb.AppendLine("    PRINT 'Invoke-AgentHandler: job ' + $(ConvertTo-SqlLiteral $jobName) + ' reconciled.';")
    $null = $sb.AppendLine("END TRY")
    $null = $sb.AppendLine("BEGIN CATCH")
    $null = $sb.AppendLine("    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION;")
    $null = $sb.AppendLine("    DECLARE @msg NVARCHAR(2048) = N'Invoke-AgentHandler: failed to reconcile job ' + $(ConvertTo-SqlLiteral $jobName) + N'. Rolled back. ' + ERROR_MESSAGE();")
    $null = $sb.AppendLine("    THROW 50000, @msg, 1;")
    $null = $sb.AppendLine("END CATCH")
    $null = $sb.AppendLine("GO")
    $null = $sb.AppendLine("-- MACHINE-GENERATED by SQL Agent's Handler -- DO NOT EDIT. Edit job-source instead.")

    return $sb.ToString()
}

#endregion Per-job build -------------------------------------------------------

#region Main -------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "SourcePath '$SourcePath' does not exist."
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$jobFolders = Get-ChildItem -LiteralPath $SourcePath -Directory | Where-Object { $_.Name -like $JobName }
if (-not $jobFolders) {
    Write-Warning "No job folders found under '$SourcePath' matching '$JobName'."
    return
}

$built = 0
foreach ($folder in $jobFolders) {
    Write-Host "Building job from '$($folder.Name)'..."
    try {
        $script = Build-JobScript -JobFolder $folder -HelperDatabase $HelperDatabase
    }
    catch {
        Write-Error "  Failed to build '$($folder.Name)': $($_.Exception.Message)"
        continue
    }

    # Read job.json once more just for the output filename (job name may contain spaces).
    $meta = Get-Content -LiteralPath (Join-Path $folder.FullName 'job.json') -Raw | ConvertFrom-Json
    $safeName = ([string] $meta.name) -replace '[\\/:*?"<>|]', '_'
    $outFile = Join-Path $OutputPath "$safeName.sql"

    # Write UTF-8 without BOM for clean diffs and sqlcmd compatibility.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($outFile, $script, $utf8NoBom)

    Write-Host "  -> $outFile"
    $built++
}

Write-Host "Done. Generated $built job script(s) in '$OutputPath'."

#endregion Main ----------------------------------------------------------------
