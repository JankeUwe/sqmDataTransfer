<#
.SYNOPSIS
    Compares row counts between a source and a target table (or set of tables).

.DESCRIPTION
    Runs SELECT COUNT_BIG(*) on both sides for each table and reports source count, destination
    count, the difference and whether they match. Intended as the verification step after
    Copy-sqmTableData.

.PARAMETER Source
    Source SQL Server instance.

.PARAMETER SourceDatabase
    Source database name.

.PARAMETER Destination
    Target SQL Server instance.

.PARAMETER DestinationDatabase
    Target database name.

.PARAMETER Table
    One or more table names ('Table' or 'schema.Table'). Same name is assumed on both sides
    unless -DestinationTable is given (only valid for a single table).

.PARAMETER DestinationTable
    Overrides the target table name. Only valid when -Table specifies exactly one table.

.PARAMETER SourceCredential
    Optional PSCredential for the source instance.

.PARAMETER DestinationCredential
    Optional PSCredential for the target instance.

.EXAMPLE
    Compare-sqmTableRowCount -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -Table Orders,Customers

.NOTES
    Prerequisites: dbatools (Invoke-DbaQuery), Write-sqmTransferLog.
#>
function Compare-sqmTableRowCount
{
	[CmdletBinding()]
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
		[System.Management.Automation.PSCredential]$DestinationCredential
	)

	$functionName = $MyInvocation.MyCommand.Name

	if ($DestinationTable -and @($Table).Count -gt 1)
	{
		throw "-DestinationTable kann nur zusammen mit genau einer Tabelle in -Table verwendet werden."
	}

	$srcConnParams = @{ SqlInstance = $Source; Database = $SourceDatabase; ErrorAction = 'Stop' }
	$dstConnParams = @{ SqlInstance = $Destination; Database = $DestinationDatabase; ErrorAction = 'Stop' }
	if ($SourceCredential) { $srcConnParams['SqlCredential'] = $SourceCredential }
	if ($DestinationCredential) { $dstConnParams['SqlCredential'] = $DestinationCredential }

	$results = [System.Collections.Generic.List[PSCustomObject]]::new()

	foreach ($t in $Table)
	{
		$targetTableName = if ($DestinationTable) { $DestinationTable } else { $t }

		$schemaName = 'dbo'
		$tableName = $t
		if ($t -match '^(?<schema>[^.]+)\.(?<name>.+)$') { $schemaName = $Matches['schema']; $tableName = $Matches['name'] }

		$dstSchemaName = 'dbo'
		$dstTableName = $targetTableName
		if ($targetTableName -match '^(?<schema>[^.]+)\.(?<name>.+)$') { $dstSchemaName = $Matches['schema']; $dstTableName = $Matches['name'] }

		$srcCount = $null
		$dstCount = $null
		$errMsg = $null

		try
		{
			$srcCount = [int64](Invoke-DbaQuery @srcConnParams -Query "SELECT COUNT_BIG(*) AS [RowCount] FROM [$schemaName].[$tableName]" -As PSObject -EnableException).RowCount
		}
		catch
		{
			$errMsg = "Quelle: $($_.Exception.Message)"
		}

		try
		{
			$dstCount = [int64](Invoke-DbaQuery @dstConnParams -Query "SELECT COUNT_BIG(*) AS [RowCount] FROM [$dstSchemaName].[$dstTableName]" -As PSObject -EnableException).RowCount
		}
		catch
		{
			$errMsg = if ($errMsg) { "$errMsg | Ziel: $($_.Exception.Message)" } else { "Ziel: $($_.Exception.Message)" }
		}

		$match = ($null -ne $srcCount) -and ($null -ne $dstCount) -and ($srcCount -eq $dstCount)
		$diff = if (($null -ne $srcCount) -and ($null -ne $dstCount)) { $dstCount - $srcCount } else { $null }

		$logLevel = if ($errMsg) { 'ERROR' } elseif (-not $match) { 'WARNING' } else { 'INFO' }
		$logMsg = "Zeilenvergleich [$schemaName.$tableName] -> [$dstSchemaName.$dstTableName]: Quelle=$srcCount Ziel=$dstCount Match=$match$(if ($errMsg) { " Fehler: $errMsg" })"
		Write-sqmTransferLog -Message $logMsg -FunctionName $functionName -Level $logLevel

		$results.Add([PSCustomObject]@{
				Table		    = "$schemaName.$tableName"
				DestinationTable = "$dstSchemaName.$dstTableName"
				SourceRows	    = $srcCount
				DestinationRows = $dstCount
				Difference	    = $diff
				Match		    = $match
				Message		    = $errMsg
			})
	}

	return $results
}
