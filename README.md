# Invoke-AgentHandler

Human-readable source control for SQL Server Agent jobs.

You write each job as a small folder of plain files — a JSON metadata file and one
file per job step. Invoke-AgentHandler bundles those into a single, ready-to-deploy T-SQL
script that reconciles the job on an instance. Drop the generated `.sql` into your
deploy artifacts as a post-deploy script.

The point is reviewable diffs. A job step is just a `.sql` file you can read, lint,
and review in a pull request — not a blob of `sp_add_jobstep` calls or a job that
only exists in `msdb` on some server.

## How it works

```
job-source/<your job>/   ──►   Invoke-AgentHandler.ps1   ──►   job-tsql/<Job Name>.sql
   (you edit these)              (the generator)               (generated, deployable)
```

1. You author job folders under `job-source/`.
2. The generator reads every folder and writes one `.sql` per job into `job-tsql/`.
3. You commit both. A commit hook (below) keeps `job-tsql/` in sync automatically.
4. Your deploy pipeline runs the generated `.sql` against the target instance.

The generated script is **idempotent**: it calls a set of `Agent_Upsert_*` helper
procedures (installed once per instance — see [Helper procedures](#helper-procedures))
that create each object if it's missing and update it in place otherwise. Re-running a
generated script reconciles the live job back to its source files, so it's safe to run
on every deploy. The whole batch runs inside a transaction and rolls back if any step
fails.

> Because the script reconciles rather than recreates, editing a job's source and
> re-deploying updates the live job in place — no need to drop it first. The job name
> is the key, so renaming a job in `job.json` creates a new job rather than renaming
> the existing one.

## Repo layout

```
Invoke-AgentHandler.ps1      The generator. This is the whole tool.
sql/                         The Agent_Upsert_* helper procedures. Install once per instance.
  dbo.Agent_Upsert_Job.sql
  dbo.Agent_Upsert_JobStep.sql
  ...
job-source/                 Your hand-authored job definitions (one folder per job).
  scratch-db-purge/         Example job — copy this as a starting point.
    job.json                Job metadata + schedule(s).
    01_Purge scratchdb.sql  A job step.
job-tsql/                   Generated output. Committed, but never edited by hand.
brainstorm.md               Original design notes (historical).
```

## Authoring a job

Create a folder under `job-source/`. The folder name is just a label for humans —
the real job name comes from `job.json`.

### `job.json` (required)

```json
{
    "name": "DBA - scratchdb purge old objects",
    "category": "DBA Maintenance",
    "description": "This job runs weekly to purge expired temp objects from scratchdb",
    "enabled": true,
    "owner": "sa",
    "schedules": [
        {
            "name": "Weekly Sunday 4am",
            "frequency": "weekly",
            "daysOfWeek": [ "sunday" ],
            "time": "04:00"
        }
    ]
}
```

| Field         | Required | Default  | Notes                                                        |
|---------------|----------|----------|--------------------------------------------------------------|
| `name`        | yes      | —        | The SQL Agent job name. Must be unique on the instance.      |
| `category`    | yes      | —        | Job category. Created automatically if it doesn't exist.     |
| `description` | no       | `""`     | Free text.                                                   |
| `enabled`     | no       | `true`   | Whether the job is enabled when created.                     |
| `owner`       | no       | `sa`     | Job owner login.                                             |
| `schedules`   | no       | none     | Array of schedule objects (see below). Supports 1:N.         |

### Schedules

Each entry in `schedules` describes one recurring schedule. A job can have zero,
one, or many.

```json
{
    "name": "Weekly Sunday 4am",
    "frequency": "weekly",
    "daysOfWeek": [ "sunday" ],
    "everyN": 1,
    "time": "04:00"
}
```

| Field        | Applies to        | Notes                                                              |
|--------------|-------------------|--------------------------------------------------------------------|
| `name`       | all               | Schedule name. Defaults to `<job name> schedule`.                  |
| `frequency`  | all               | `daily`, `weekly`, or `monthly`.                                   |
| `time`       | all               | `HH:MM` or `HH:MM:SS`, 24-hour. Defaults to midnight.              |
| `everyN`     | daily, weekly, monthly | The "every N" multiplier. **Optional, defaults to `1`.** `weekly` + `everyN: 2` = every 2 weeks. |
| `daysOfWeek` | weekly (required) | Array: `sunday`…`saturday`. Multiple days allowed.                 |
| `dayOfMonth` | monthly (required)| Day of the month, `1`–`31`.                                        |

Weekly is the common case, and `everyN` defaults to `1`, so a plain weekly job needs
only `frequency`, `daysOfWeek`, and `time`.

### Job steps: `nn_<label>.sql` / `.ps1`

Each step is its own file. The numeric prefix sets the **step order**. The step name
comes from the `StepName` directive (below); if that's absent, it falls back to the
filename with the prefix stripped:

```
01_Purge scratchdb.sql      ──►  Step 1, TSQL subsystem
02_Notify owner.ps1         ──►  Step 2, PowerShell subsystem
```

`.sql` → TSQL subsystem, `.ps1` → PowerShell subsystem. Anything else is ignored.

The body of the file is the step command, verbatim — write normal T-SQL (or
PowerShell). The example:

```sql
--> StepName: Purge old objects from scratchdb
--> Database: scratchdb
--> RetryAttempts: 2
--> RetryInterval: 5
EXEC scratchdb.dbo.Purge_OldObjects @Debug = 0;
```

### Step directives

Directive lines **configure the job step** and are stripped out of the command before
it's embedded in the script. They must be on their own line; put them at the top of the
file by convention.

The directive marker depends on the step language, so a directive always reads as a
comment in that language:

- **`.sql` steps** use `-->` &nbsp;(e.g. `--> RetryAttempts: 2`)
- **`.ps1` steps** use `##>` &nbsp;(e.g. `##> RetryAttempts: 2`)

A `.ps1` line that starts with a plain `#` (an ordinary PowerShell comment) is **not** a
directive — only the `##>` marker is. The two markers are otherwise identical in
behavior; the tables below use the `-->` form.

Value directives:

| Directive            | Default      | Meaning                                                    |
|----------------------|--------------|------------------------------------------------------------|
| `--> StepName: <name>` | filename (sans `nn_`) | The job step name.                              |
| `--> Database: <db>` | `master`     | Database the step runs in (TSQL steps only).               |
| `--> Runas: <proxy>` | (none)       | Run the step as this Agent proxy account.                  |
| `--> SuccessAction: next\|success\|failure` | `next` | What to do when the step succeeds.    |
| `--> FailAction: next\|success\|failure`    | `failure` | What to do when the step fails.       |
| `--> RetryAttempts: <N>` | `0`      | Retry count on failure.                                    |
| `--> RetryInterval: <N>` | `0`      | Minutes between retries.                                    |

Flag directives — presence turns the option on:

| Directive                                | Effect                                          |
|------------------------------------------|-------------------------------------------------|
| `--> LogToTable`                         | Log step output to `sysjobstepslogs`.           |
| `--> AppendOutputToExistingEntryInTable` | Append to the table log instead of overwriting. |
| `--> IncludeStepOutputInHistory`         | Include step output in job history.             |

> On the **last** step, `SuccessAction: next` collapses to "quit reporting success"
> (there's no next step to go to), and `FailAction: next` collapses to "quit
> reporting failure."

A PowerShell step uses the `##>` marker for the same directives:

```powershell
##> StepName: Cleanup temporary temp files
##> RetryAttempts: 2
##> RetryInterval: 1

## An ordinary PowerShell comment -- left untouched in the command body.
Get-ChildItem -Path 'C:\temp\temp' -File -Recurse |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-365) } |
    Remove-Item -Force
```

### `notifications.json` (optional)

Drop this in the job folder to set email notifications:

```json
{
    "email": {
        "on": "failure",
        "operator": "DBA Team"
    }
}
```

`on` is `never`, `success`, `failure`, or `always`. `operator` must be an existing
SQL Agent operator name.

## Helper procedures

The idempotency lives in a small set of stored procedures under [`sql/`](sql/):

| Procedure                    | Wraps                                      | Behavior              |
|------------------------------|--------------------------------------------|-----------------------|
| `Agent_Upsert_JobCategory`   | `sp_add_category`                          | create-if-missing     |
| `Agent_Upsert_Job`           | `sp_add_job` / `sp_update_job`             | upsert by job name    |
| `Agent_Upsert_JobStep`       | `sp_add_jobstep` / `sp_update_jobstep`     | upsert by step id     |
| `Agent_Upsert_JobSchedule`   | `sp_add_jobschedule` / `sp_update_jobschedule` | upsert by name    |
| `Agent_Upsert_JobServer`     | `sp_add_jobserver`                         | create-if-missing     |

Each does an existence check, then dispatches to the correct native create or update
procedure. They are defined `CREATE OR ALTER`, so installing them is itself re-runnable.

**Install them once per instance** into a utility database — `dba` by convention. The
files don't carry a `USE` statement, so select the database when you run them:

```powershell
# Install all helper procs into the [dba] database
Get-ChildItem .\sql\dbo.Agent_Upsert_*.sql |
    ForEach-Object { sqlcmd -S <instance> -d dba -i $_.FullName }
```

The generated scripts call these as `[dba].dbo.Agent_Upsert_*`. If you install them
into a different database, pass its name to the generator with `-HelperDatabase` (see
below) so the generated calls point at the right place.

## Generating the scripts

Run the generator from the repo root:

```powershell
# Build every job in job-source/ into job-tsql/
.\Invoke-AgentHandler.ps1

# Build a single job folder
.\Invoke-AgentHandler.ps1 -JobName scratch-db-purge

# Custom source/output locations
.\Invoke-AgentHandler.ps1 -SourcePath .\job-source -OutputPath .\out

# Helper procs live somewhere other than [dba]
.\Invoke-AgentHandler.ps1 -HelperDatabase dbo_utils
```

`-HelperDatabase` defaults to `dba` and rarely needs to be set — it just controls the
database name the generated `Agent_Upsert_*` calls are qualified with.

Requires Windows PowerShell 5.1+ or PowerShell 7+. No modules or SQL connection
needed — it only reads files and writes files.

## Permissions on the target instance

The generator needs no database access. The account that *runs* the generated
`.sql` against the target instance does, though. The minimum it needs is the ability
to manage Agent jobs (via `SQLAgentOperatorRole` in `msdb`), `SELECT` on `dbo.sysjobs`
so the helper procs' existence checks can run, and `EXECUTE` on the helper procs in the
utility database:

```sql
USE [msdb];
CREATE USER [YourUser] FOR LOGIN [YourUser] WITH DEFAULT_SCHEMA=[dbo];
ALTER ROLE [SQLAgentOperatorRole] ADD MEMBER [YourUser];
GRANT SELECT ON dbo.sysjobs TO [YourUser];

-- ...and in the database that holds the Agent_Upsert_* procedures ([dba] by convention):
USE [dba];
CREATE USER [YourUser] FOR LOGIN [YourUser] WITH DEFAULT_SCHEMA=[dbo];
GRANT EXECUTE ON SCHEMA::dbo TO [YourUser];
```

> The helper procs call the native `msdb.dbo.sp_*` Agent procedures internally, so the
> `SQLAgentOperatorRole` membership is still what authorizes the actual job changes.

## Using it inside your own database project

Invoke-AgentHandler is designed to be dropped into an existing database repo. The simplest
layout is to vendor the generator, the `sql/` helper procs, and the `job-source/`
convention into your repo (e.g. under a `sql-agent/` subfolder) and point the generator
at it:

```powershell
.\sql-agent\Invoke-AgentHandler.ps1 `
    -SourcePath .\sql-agent\job-source `
    -OutputPath .\deploy\post-deploy\agent-jobs
```

Make sure the helper procs are installed on the target (deploy `sql/dbo.Agent_Upsert_*.sql`
ahead of the job scripts — they're `CREATE OR ALTER`, so it's safe every time). Then
include everything in `deploy\post-deploy\agent-jobs\*.sql` in your post-deploy step.
The generated scripts are idempotent, so re-running them on each deploy reconciles the
jobs back to source.

## Setting up the commit hook

The goal: nobody has to remember to regenerate `job-tsql/`. When someone edits a job
under `job-source/`, the pre-commit hook regenerates the output and stages it so the
`.sql` is always committed alongside its source.

### Option A: native Git hook

Create `.git/hooks/pre-commit` (no extension, must be executable):

```sh
#!/bin/sh
# Regenerate SQL Agent job scripts when job-source changes, and stage the output.

if git diff --cached --name-only | grep -q '^job-source/'; then
    echo "job-source changed — regenerating job-tsql/ ..."
    pwsh -NoProfile -File ./Invoke-AgentHandler.ps1 \
        || powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./Invoke-AgentHandler.ps1 \
        || { echo "Invoke-AgentHandler failed; aborting commit."; exit 1; }
    git add job-tsql/
fi
```

Make it executable:

```sh
chmod +x .git/hooks/pre-commit
```

> `.git/hooks/` isn't version-controlled, so each clone needs this set up once. The
> `pwsh ... || powershell.exe ...` fallback runs on both PowerShell 7 (cross-platform)
> and Windows PowerShell.

### Option B: pre-commit framework (shareable, recommended for teams)

If your repo already uses [pre-commit](https://pre-commit.com/), add a local hook so
the configuration travels with the repo. In `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: local
    hooks:
      - id: invoke-agent-handler
        name: Generate SQL Agent job scripts
        entry: pwsh -NoProfile -File ./Invoke-AgentHandler.ps1
        language: system
        files: ^job-source/
        pass_filenames: false
```

Then each engineer runs `pre-commit install` once. When files under `job-source/`
are staged, the hook regenerates `job-tsql/`. (You may still want a `git add
job-tsql/` afterward, or run the generator and review the diff before committing —
pre-commit will fail the commit if the hook modifies tracked files, prompting you to
stage them.)

### Verifying in CI

Belt-and-suspenders: have CI regenerate and fail if the committed output is stale, so
a missing local hook can't sneak by.

```sh
pwsh -NoProfile -File ./Invoke-AgentHandler.ps1
git diff --exit-code job-tsql/ \
    || { echo "job-tsql/ is out of date — run Invoke-AgentHandler.ps1 and commit the result."; exit 1; }
```

## Limitations

- No support for replication-agent job types.
- No MSX/multiserver (master/target) job support — jobs target `(LOCAL)`.
- Reconciliation is keyed on the job name: renaming a job in `job.json` creates a new
  job rather than renaming the existing one. Likewise, a step or schedule removed from
  source is not dropped from the live job — the upsert only adds and updates.
- Requires the `Agent_Upsert_*` helper procedures to be installed on the target instance.
