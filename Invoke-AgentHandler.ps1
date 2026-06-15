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
    body before it is embedded in the generated script:

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

    The generated script uses guarded creation: if a job with the same name already
    exists on the target instance, the whole batch is skipped (re-runnable no-op).

.PARAMETER SourcePath
    Path to the job-source directory. Defaults to .\job-source relative to this script.

.PARAMETER OutputPath
    Path to the directory where generated .sql files are written. Defaults to
    .\job-tsql relative to this script. Created if it does not exist.

.PARAMETER JobName
    Optional. Build only the job folder(s) whose directory name matches this value
    (supports wildcards). Default builds every folder under SourcePath.

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
    [string] $JobName = '*'
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

# Parse the leading "--> Key: Value" directives out of a step file.
# Returns the settings plus the command body with directive lines removed.
function Read-StepFile {
    param([Parameter(Mandatory)][System.IO.FileInfo] $File)

    $settings = [ordered]@{
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

    $valueKeys = 'Database', 'Runas', 'SuccessAction', 'FailAction', 'RetryAttempts', 'RetryInterval'
    $flagKeys  = 'LogToTable', 'AppendOutputToExistingEntryInTable', 'IncludeStepOutputInHistory'

    $bodyLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $File.FullName)) {
        $m = [regex]::Match($line, '^\s*-->\s*(?<key>\w+)\s*:?\s*(?<val>.*?)\s*$')
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
        Write-Warning "  Unknown directive '--> $key' in $($File.Name); leaving the line in the command body."
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
    param([Parameter(Mandatory)][System.IO.DirectoryInfo] $JobFolder)

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
    $null = $sb.AppendLine("    DO NOT EDIT BY HAND -- regenerate from job-source instead.")
    $null = $sb.AppendLine("*/")
    $null = $sb.AppendLine("SET NOCOUNT ON;")
    $null = $sb.AppendLine("USE [msdb];")
    $null = $sb.AppendLine("GO")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = $(ConvertTo-SqlLiteral $jobName))")
    $null = $sb.AppendLine("BEGIN")
    $null = $sb.AppendLine("    BEGIN TRANSACTION;")
    $null = $sb.AppendLine("    DECLARE @ReturnCode INT = 0;")
    $null = $sb.AppendLine()

    # Ensure the job category exists (guarded), then create the job.
    $null = $sb.AppendLine("    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE [name] = $(ConvertTo-SqlLiteral $category) AND category_class = 1)")
    $null = $sb.AppendLine("        EXEC @ReturnCode = msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = $(ConvertTo-SqlLiteral $category);")
    $null = $sb.AppendLine("    IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("    EXEC @ReturnCode = msdb.dbo.sp_add_job")
    $null = $sb.AppendLine("        @job_name = $(ConvertTo-SqlLiteral $jobName),")
    $null = $sb.AppendLine("        @enabled = $([int][bool]$enabled),")
    $null = $sb.AppendLine("        @description = $(ConvertTo-SqlLiteral $description),")
    $null = $sb.AppendLine("        @category_name = $(ConvertTo-SqlLiteral $category),")
    $null = $sb.AppendLine("        @owner_login_name = $(ConvertTo-SqlLiteral $owner);")
    $null = $sb.AppendLine("    IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;")
    $null = $sb.AppendLine()

    # Steps.
    $stepCount = $stepFiles.Count
    for ($i = 0; $i -lt $stepCount; $i++) {
        $file = $stepFiles[$i]
        $stepId = $i + 1
        $isLast = ($stepId -eq $stepCount)

        $parsed = Read-StepFile -File $file
        $settings = $parsed.Settings

        # Step name: file base name with the leading "nn_" stripped.
        $stepName = [regex]::Replace($file.BaseName, '^\d+[_\-\s]*', '').Trim()
        if ([string]::IsNullOrWhiteSpace($stepName)) { $stepName = $file.BaseName }

        $subsystem = if ($file.Extension -ieq '.ps1') { 'PowerShell' } else { 'TSQL' }

        $onSuccess = Get-StepActionCode -Action $settings.SuccessAction -IsLastStep $isLast -LastStepCollapse 'success'
        $onFail    = Get-StepActionCode -Action $settings.FailAction    -IsLastStep $isLast -LastStepCollapse 'failure'
        $flags     = Get-StepFlags -Settings $settings

        $null = $sb.AppendLine("    -- Step $stepId : $stepName  ($subsystem)")
        $null = $sb.AppendLine("    EXEC @ReturnCode = msdb.dbo.sp_add_jobstep")
        $null = $sb.AppendLine("        @job_name = $(ConvertTo-SqlLiteral $jobName),")
        $null = $sb.AppendLine("        @step_name = $(ConvertTo-SqlLiteral $stepName),")
        $null = $sb.AppendLine("        @step_id = $stepId,")
        $null = $sb.AppendLine("        @subsystem = $(ConvertTo-SqlLiteral $subsystem),")
        $null = $sb.AppendLine("        @command = $(ConvertTo-SqlLiteral $parsed.Command),")
        if ($subsystem -eq 'TSQL') {
            $null = $sb.AppendLine("        @database_name = $(ConvertTo-SqlLiteral $settings.Database),")
        }
        if ($settings.Runas) {
            $null = $sb.AppendLine("        @proxy_name = $(ConvertTo-SqlLiteral $settings.Runas),")
        }
        $null = $sb.AppendLine("        @on_success_action = $onSuccess,")
        $null = $sb.AppendLine("        @on_fail_action = $onFail,")
        $null = $sb.AppendLine("        @retry_attempts = $($settings.RetryAttempts),")
        $null = $sb.AppendLine("        @retry_interval = $($settings.RetryInterval),")
        $null = $sb.AppendLine("        @flags = $flags;")
        $null = $sb.AppendLine("    IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;")
        $null = $sb.AppendLine()
    }

    # Point the job at its first step.
    $null = $sb.AppendLine("    EXEC @ReturnCode = msdb.dbo.sp_update_job @job_name = $(ConvertTo-SqlLiteral $jobName), @start_step_id = 1;")
    $null = $sb.AppendLine("    IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;")
    $null = $sb.AppendLine()

    # Schedules (0..N).
    if ($meta.PSObject.Properties.Name -contains 'schedules' -and $meta.schedules) {
        foreach ($sched in $meta.schedules) {
            $schedName = if ($sched.PSObject.Properties.Name -contains 'name' -and $sched.name) { [string] $sched.name } else { "$jobName schedule" }
            $schedArgs = ConvertTo-ScheduleArgs -Schedule $sched
            $null = $sb.AppendLine("    EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule")
            $null = $sb.AppendLine("        @job_name = $(ConvertTo-SqlLiteral $jobName),")
            $null = $sb.AppendLine("        @name = $(ConvertTo-SqlLiteral $schedName),")
            $null = $sb.AppendLine("        @enabled = 1,")
            $null = $sb.AppendLine("        @freq_type = $($schedArgs.FreqType),")
            $null = $sb.AppendLine("        @freq_interval = $($schedArgs.FreqInterval),")
            $null = $sb.AppendLine("        @freq_recurrence_factor = $($schedArgs.FreqRecurrence),")
            $null = $sb.AppendLine("        @active_start_time = $($schedArgs.ActiveStartTime);")
            $null = $sb.AppendLine("    IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;")
            $null = $sb.AppendLine()
        }
    }

    # Optional notifications.
    $notifyPath = Join-Path $JobFolder.FullName 'notifications.json'
    if (Test-Path -LiteralPath $notifyPath) {
        $notify = Get-Content -LiteralPath $notifyPath -Raw | ConvertFrom-Json
        $levelMap = @{ never = 0; success = 1; failure = 2; always = 3 }
        $emailLevel = 0
        $emailOperator = $null
        if ($notify.PSObject.Properties.Name -contains 'email' -and $notify.email) {
            $on = ([string]$notify.email.on).ToLowerInvariant()
            if (-not $levelMap.ContainsKey($on)) { throw "notifications.json email.on '$on' must be never/success/failure/always." }
            $emailLevel = $levelMap[$on]
            $emailOperator = [string] $notify.email.operator
        }
        if ($emailLevel -ne 0 -and $emailOperator) {
            $null = $sb.AppendLine("    EXEC @ReturnCode = msdb.dbo.sp_update_job")
            $null = $sb.AppendLine("        @job_name = $(ConvertTo-SqlLiteral $jobName),")
            $null = $sb.AppendLine("        @notify_level_email = $emailLevel,")
            $null = $sb.AppendLine("        @notify_email_operator_name = $(ConvertTo-SqlLiteral $emailOperator);")
            $null = $sb.AppendLine("    IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;")
            $null = $sb.AppendLine()
        }
    }

    # Target the local server, commit, and the rollback label.
    $null = $sb.AppendLine("    EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_name = $(ConvertTo-SqlLiteral $jobName), @server_name = N'(LOCAL)';")
    $null = $sb.AppendLine("    IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("    COMMIT TRANSACTION;")
    $null = $sb.AppendLine("    GOTO EndSave;")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("    QuitWithRollback:")
    $null = $sb.AppendLine("        IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION;")
    $null = $sb.AppendLine("        DECLARE @msg NVARCHAR(2048) = N'Invoke-AgentHandler: failed to create job ' + $(ConvertTo-SqlLiteral $jobName) + N'. Rolled back.';")
    $null = $sb.AppendLine("        RAISERROR(@msg, 16, 1);")
    $null = $sb.AppendLine("    EndSave:")
    $null = $sb.AppendLine("END")
    $null = $sb.AppendLine("ELSE")
    $null = $sb.AppendLine("    PRINT 'Invoke-AgentHandler: job ' + $(ConvertTo-SqlLiteral $jobName) + ' already exists -- skipped.';")
    $null = $sb.AppendLine("GO")

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
        $script = Build-JobScript -JobFolder $folder
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
