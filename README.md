# Invoke-AgentHandler

Human-readable source control for SQL Server Agent jobs.

You write each job as a small folder of plain files — a JSON metadata file and one
file per job step. Invoke-AgentHandler bundles those into a single, ready-to-deploy T-SQL
script that creates the job on an instance. Drop the generated `.sql` into your
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

The generated script is **guarded**: if a job with the same name already exists on
the instance, the whole batch is skipped — so it's safe to run on every deploy. It
also runs inside a transaction and rolls back if any step fails.

> Because creation is guarded, the generated script does **not** alter a job that
> already exists. To change a live job, delete it on the instance (or drop it via a
> separate migration) and let the next deploy recreate it.

## Repo layout

```
Invoke-AgentHandler.ps1      The generator. This is the whole tool.
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

### Job steps: `nn_<step name>.sql` / `.ps1`

Each step is its own file. The numeric prefix sets the **step order** and the step
name is the filename with the prefix stripped:

```
01_Purge scratchdb.sql      ──►  Step 1, name "Purge scratchdb", TSQL subsystem
02_Notify owner.ps1         ──►  Step 2, name "Notify owner", PowerShell subsystem
```

`.sql` → TSQL subsystem, `.ps1` → PowerShell subsystem. Anything else is ignored.

The body of the file is the step command, verbatim — write normal T-SQL (or
PowerShell). The example:

```sql
--> Database: scratchdb
--> RetryAttempts: 2
--> RetryInterval: 5
EXEC scratchdb.dbo.Purge_OldObjects @Debug = 0;
```

### Step directives (`-->` comments)

Lines starting with `-->` are **directives** — they configure the job step and are
stripped out of the command before it's embedded in the script. They must be on
their own line; put them at the top of the file by convention.

Value directives:

| Directive            | Default      | Meaning                                                    |
|----------------------|--------------|------------------------------------------------------------|
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

## Generating the scripts

Run the generator from the repo root:

```powershell
# Build every job in job-source/ into job-tsql/
.\Invoke-AgentHandler.ps1

# Build a single job folder
.\Invoke-AgentHandler.ps1 -JobName scratch-db-purge

# Custom source/output locations
.\Invoke-AgentHandler.ps1 -SourcePath .\job-source -OutputPath .\out
```

Requires Windows PowerShell 5.1+ or PowerShell 7+. No modules or SQL connection
needed — it only reads files and writes files.

## Permissions on the target instance

The generator needs no database access. The account that *runs* the generated
`.sql` against the target instance does, though. The minimum it needs is the ability
to create Agent jobs (via `SQLAgentOperatorRole` in `msdb`) plus `SELECT` on
`dbo.sysjobs` so the guard check (`IF NOT EXISTS ... sysjobs`) can run:

```sql
USE [msdb];
CREATE USER [YourUser] FOR LOGIN [YourUser] WITH DEFAULT_SCHEMA=[dbo];
ALTER ROLE [SQLAgentOperatorRole] ADD MEMBER [YourUser];
GRANT SELECT ON dbo.sysjobs TO [YourUser];
```

## Using it inside your own database project

Invoke-AgentHandler is designed to be dropped into an existing database repo. The simplest
layout is to vendor the script and the `job-source/` convention into your repo (e.g.
under a `sql-agent/` subfolder) and point the generator at it:

```powershell
.\sql-agent\Invoke-AgentHandler.ps1 `
    -SourcePath .\sql-agent\job-source `
    -OutputPath .\deploy\post-deploy\agent-jobs
```

Then include everything in `deploy\post-deploy\agent-jobs\*.sql` in your post-deploy
step. The generated scripts are guarded, so re-running them on each deploy is a
no-op once the jobs exist.

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

## Current Limitations / Future To-Dos

- No support for replication-agent job types.
- No MSX/multiserver (master/target) job support — jobs target `(LOCAL)`.
- Creation is guarded, not idempotent-update: existing jobs are skipped, not altered.
