##> StepName: Cleanup temporary temp files
##> RetryAttempts: 2
##> RetryInterval: 1




## Delete the temporary files that are only temporary.
Get-ChildItem -Path 'C:\temp\temp' -File -Recurse | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-365) } | Remove-Item -Force
