<#
.SYNOPSIS
    Bulk-copies table data from a source instance/database to a target instance/database.

.DESCRIPTION
    Thin wrapper around dbatools' Copy-DbaDbTableData, looping per table so a failure on one
    table does not abort the others (unless -EnableException is set). Adds structured logging
    and a normalized per-table result object.

.PARAMETER Source
    Source SQL Server instance.

.PARAMETER SourceDatabase
    Source database name.

.PARAMETER Destination
    Target SQL Server instance.

.PARAMETER DestinationDatabase
    Target database name.

.PARAMETER Table
    One or more table names ('Table' or 'schema.Table'). Same name is used on source and target
    unless -DestinationTable is given (only valid for a single table).

.PARAMETER DestinationTable
    Overrides the target table name. Only valid when -Table specifies exactly one table.

.PARAMETER SourceCredential
    Optional PSCredential for the source instance.

.PARAMETER DestinationCredential
    Optional PSCredential for the target instance.

.PARAMETER Truncate
    Truncate the destination table before copying.

.PARAMETER KeepIdentity
    Preserve source IDENTITY column values on the target. Default: $true.

.PARAMETER KeepNulls
    Preserve NULL values instead of applying target column defaults. Default: $true.

.PARAMETER BatchSize
    Rows per batch. Default: the module's DefaultBatchSize (Get-sqmTransferConfig).

.PARAMETER BulkCopyTimeOut
    Bulk copy timeout in seconds. Default: 300.

.PARAMETER ContinueOnError
    Continue with the next table on error.

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
.PARAMETER WhatIf

.EXAMPLE
    Copy-sqmTableData -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -Table Orders,Customers -Truncate

.NOTES
    Prerequisites: dbatools (Copy-DbaDbTableData), Write-sqmTransferLog.
#>
function Copy-sqmTableData
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$Source,
		[Parameter(Mandatory = $true)]
		[string]$SourceDatabase,
		[Parameter(Mandatory = $true)]
		[string]$Destination,
		[Parameter(Mandatory = $true)]
		[string]$DestinationDatabase,
		[Parameter(Mandatory = $true)]
		[string[]]$Table,
		[Parameter(Mandatory = $false)]
		[string]$DestinationTable,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SourceCredential,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DestinationCredential,
		[Parameter(Mandatory = $false)]
		[switch]$Truncate,
		[Parameter(Mandatory = $false)]
		[bool]$KeepIdentity = $true,
		[Parameter(Mandatory = $false)]
		[bool]$KeepNulls = $true,
		[Parameter(Mandatory = $false)]
		[int]$BatchSize,
		[Parameter(Mandatory = $false)]
		[int]$BulkCopyTimeOut = 300,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name

	if ($DestinationTable -and @($Table).Count -gt 1)
	{
		throw "-DestinationTable kann nur zusammen mit genau einer Tabelle in -Table verwendet werden."
	}

	if (-not $PSBoundParameters.ContainsKey('BatchSize'))
	{
		$BatchSize = Get-sqmTransferConfig -Key 'DefaultBatchSize'
		if (-not $BatchSize) { $BatchSize = 50000 }
	}

	$results = [System.Collections.Generic.List[PSCustomObject]]::new()

	foreach ($t in $Table)
	{
		$targetTableName = if ($DestinationTable) { $DestinationTable } else { $t }
		$action = "Daten von '$Source'.'$SourceDatabase'.[$t] nach '$Destination'.'$DestinationDatabase'.[$targetTableName] kopieren"

		if (-not $PSCmdlet.ShouldProcess($Destination, $action))
		{
			$results.Add([PSCustomObject]@{ Table = $t; DestinationTable = $targetTableName; RowsCopied = 0; Status = 'WhatIf'; Message = "WhatIf: $action"; ElapsedSeconds = 0 })
			continue
		}

		Write-sqmTransferLog -Message $action -FunctionName $functionName -Level 'INFO'
		$sw = [System.Diagnostics.Stopwatch]::StartNew()

		try
		{
			$copyParams = @{
				SqlInstance		    = $Source
				Database		    = $SourceDatabase
				Destination		    = $Destination
				DestinationDatabase = $DestinationDatabase
				Table			    = $t
				DestinationTable    = $targetTableName
				BatchSize		    = $BatchSize
				BulkCopyTimeOut	    = $BulkCopyTimeOut
				KeepIdentity	    = $KeepIdentity
				KeepNulls		    = $KeepNulls
				Truncate		    = $Truncate.IsPresent
				EnableException	    = $true
				Confirm			    = $false
			}
			if ($SourceCredential) { $copyParams['SqlCredential'] = $SourceCredential }
			if ($DestinationCredential) { $copyParams['DestinationSqlCredential'] = $DestinationCredential }

			$copyResult = Copy-DbaDbTableData @copyParams
			$rows = if ($copyResult -and $copyResult.RowsCopied) { [int64]$copyResult.RowsCopied } else { 0 }

			$sw.Stop()
			$results.Add([PSCustomObject]@{
					Table		    = $t
					DestinationTable = $targetTableName
					RowsCopied	    = $rows
					Status		    = 'Success'
					Message		    = $null
					ElapsedSeconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
				})
			Write-sqmTransferLog -Message "$rows Zeile(n) kopiert: [$t] -> [$targetTableName] ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)." `
								  -FunctionName $functionName -Level 'INFO'
		}
		catch
		{
			$sw.Stop()
			$msg = $_.Exception.Message
			$results.Add([PSCustomObject]@{
					Table		    = $t
					DestinationTable = $targetTableName
					RowsCopied	    = 0
					Status		    = 'Failed'
					Message		    = $msg
					ElapsedSeconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
				})
			Write-sqmTransferLog -Message "Datenkopie fehlgeschlagen fuer [$t]: $msg" -FunctionName $functionName -Level 'ERROR'
			if ($EnableException -and -not $ContinueOnError) { throw }
		}
	}

	return $results
}
