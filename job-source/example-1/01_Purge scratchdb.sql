--> StepName: Purge old objects from scratchdb
--> Database: scratchdb
--> RetryAttempts: 2
--> RetryInterval: 5
EXEC scratchdb.dbo.Purge_OldObjects @Debug = 0;