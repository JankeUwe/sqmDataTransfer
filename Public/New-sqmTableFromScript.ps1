<#
.SYNOPSIS
    Executes previously scripted table-metadata batches against a target instance/database.

.DESCRIPTION
    Takes the ScriptBatches produced by Export-sqmTableSchema and runs each batch sequentially
    against the target via Invoke-DbaQuery. Each batch is already a complete, independent
    statement (SMO Scripter output) - no 'GO' splitting is required.

    Continues past a failed batch by default (so e.g. an index that already exists doesn't abort
    the whole table creation); use -EnableException to stop immediately on the first error.

.PARAMETER SqlInstance
    Target SQL Server instance.

.PARAMETER Database
    Target database name.

.PARAMETER ScriptBatches
    Array of SQL batches to execute, as returned by Export-sqmTableSchema.ScriptBatches.

.PARAMETER SqlCredential
    Optional PSCredential for the target instance.

.PARAMETER ContinueOnError
    Continue with the next batch on error (default behaviour even without this switch;
    kept for parity with the other functions in this module).

.PARAMETER EnableException
    Throw immediately on the first failing batch instead of continuing.

.PARAMETER Confirm
.PARAMETER WhatIf

.EXAMPLE
    $schema = Export-sqmTableSchema -SqlInstance SQL01 -Database Sales -Table Orders
    New-sqmTableFromScript -SqlInstance SQL02 -Database Sales -ScriptBatches $schema.ScriptBatches

.NOTES
    Prerequisites: dbatools (Invoke-DbaQuery), Write-sqmTransferLog.
#>
function New-sqmTableFromScript
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $true)]
		[string]$Database,
		[Parameter(Mandatory = $true)]
		[string[]]$ScriptBatches,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database; ErrorAction = 'Stop' }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$results = [System.Collections.Generic.List[PSCustomObject]]::new()
	$batchNum = 0

	foreach ($batch in $ScriptBatches)
	{
		$batchNum++
		if ([string]::IsNullOrWhiteSpace($batch)) { continue }

		$action = "Batch $batchNum/$($ScriptBatches.Count) auf '$SqlInstance'.'$Database' ausfuehren"
		if ($PSCmdlet.ShouldProcess("$SqlInstance.$Database", $action))
		{
			try
			{
				Invoke-DbaQuery @connParams -Query $batch -EnableException | Out-Null
				$results.Add([PSCustomObject]@{
						BatchNumber = $batchNum
						Status	    = 'Success'
						Message	    = $null
					})
				Write-sqmTransferLog -Message "Batch $batchNum erfolgreich ausgefuehrt auf '$SqlInstance'.'$Database'." `
									  -FunctionName $functionName -Level 'INFO'
			}
			catch
			{
				$msg = $_.Exception.Message
				$results.Add([PSCustomObject]@{
						BatchNumber = $batchNum
						Status	    = 'Failed'
						Message	    = $msg
					})
				Write-sqmTransferLog -Message "Batch $batchNum fehlgeschlagen auf '$SqlInstance'.'$Database': $msg" `
									  -FunctionName $functionName -Level 'ERROR'
				if ($EnableException -and -not $ContinueOnError) { throw }
			}
		}
		else
		{
			$results.Add([PSCustomObject]@{
					BatchNumber = $batchNum
					Status	    = 'WhatIf'
					Message	    = 'WhatIf: Batch wuerde ausgefuehrt.'
				})
		}
	}

	$failCount = @($results | Where-Object Status -eq 'Failed').Count
	$summaryMsg = "New-sqmTableFromScript abgeschlossen auf '$SqlInstance'.'$Database' - $($results.Count) Batch(es), $failCount Fehler."
	Write-sqmTransferLog -Message $summaryMsg -FunctionName $functionName -Level 'INFO'

	return $results
}
