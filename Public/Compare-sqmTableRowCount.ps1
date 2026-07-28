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

.PARAMETER Fast
    Read row counts from sys.dm_db_partition_stats (SUM(rows) WHERE index_id IN (0,1)) instead of
    SELECT COUNT_BIG(*). A metadata lookup instead of a table/index scan - on a table with hundreds
    of millions of rows this is the difference between instant and a scan that can take minutes.
    The counter is exact (SQL Server maintains it transactionally on every INSERT/DELETE, unlike
    query-optimizer statistics), but it is not a locked/consistent snapshot: reading it while a
    load is actively in progress on that table can reflect not-yet-committed rows. Only use this
    for a comparison taken once a load has fully finished - not while it is still running (see
    Invoke-sqmChunkedTableTransfer's per-chunk skip-check, which needs a WHERE-filtered exact count
    this DMV cannot provide anyway, and keeps using COUNT_BIG(*) for that reason regardless of
    this switch). Requires VIEW DATABASE STATE (or VIEW SERVER STATE on older versions) permission.

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
		[System.Management.Automation.PSCredential]$DestinationCredential,
		[Parameter(Mandatory = $false)]
		[switch]$Fast
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

		# --- Metadaten-Zaehler statt Scan: sys.dm_db_partition_stats.row_count wird von SQL Server
		# transaktional bei jedem INSERT/DELETE mitgefuehrt (exakt, keine Schaetzung) - ein Lookup
		# statt eines vollen Table-/Index-Scans. index_id IN (0,1) = Heap bzw. Clustered Index,
		# genau einer davon existiert immer; ohne diesen Filter wuerden zusaetzlich vorhandene
		# Non-Clustered-Indizes mitgezaehlt und die Summe vervielfachen. OBJECT_ID() = NULL (Tabelle
		# existiert nicht) liefert null Zeilen -> SUM(row_count) kommt als NULL zurueck, wird unten
		# wie eine fehlgeschlagene Abfrage behandelt statt faelschlich als "0 Zeilen" interpretiert.
		$srcQuery = if ($Fast) { "SELECT SUM(row_count) AS [RowCount] FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID(N'[$schemaName].[$tableName]') AND index_id IN (0, 1)" } else { "SELECT COUNT_BIG(*) AS [RowCount] FROM [$schemaName].[$tableName]" }
		$dstQuery = if ($Fast) { "SELECT SUM(row_count) AS [RowCount] FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID(N'[$dstSchemaName].[$dstTableName]') AND index_id IN (0, 1)" } else { "SELECT COUNT_BIG(*) AS [RowCount] FROM [$dstSchemaName].[$dstTableName]" }

		try
		{
			$srcRaw = (Invoke-DbaQuery @srcConnParams -Query $srcQuery -As PSObject -EnableException).RowCount
			if ($null -eq $srcRaw) { throw "Tabelle [$schemaName].[$tableName] auf '$Source'.'$SourceDatabase' nicht gefunden." }
			$srcCount = [int64]$srcRaw
		}
		catch
		{
			$errMsg = Get-sqmTransferString -Key 'Compare.SourceError' -FormatArgs @($_.Exception.Message)
		}

		try
		{
			$dstRaw = (Invoke-DbaQuery @dstConnParams -Query $dstQuery -As PSObject -EnableException).RowCount
			if ($null -eq $dstRaw) { throw "Tabelle [$dstSchemaName].[$dstTableName] auf '$Destination'.'$DestinationDatabase' nicht gefunden." }
			$dstCount = [int64]$dstRaw
		}
		catch
		{
			$dstErrMsg = Get-sqmTransferString -Key 'Compare.DestError' -FormatArgs @($_.Exception.Message)
			$errMsg = if ($errMsg) { "$errMsg | $dstErrMsg" } else { $dstErrMsg }
		}

		$match = ($null -ne $srcCount) -and ($null -ne $dstCount) -and ($srcCount -eq $dstCount)
		$diff = if (($null -ne $srcCount) -and ($null -ne $dstCount)) { $dstCount - $srcCount } else { $null }

		$logLevel = if ($errMsg) { 'ERROR' } elseif (-not $match) { 'WARNING' } else { 'INFO' }
		$errSuffix = if ($errMsg) { Get-sqmTransferString -Key 'Compare.ErrorSuffix' -FormatArgs @($errMsg) } else { '' }
		$logMsg = Get-sqmTransferString -Key 'Compare.LogMessage' -FormatArgs @("$schemaName.$tableName", "$dstSchemaName.$dstTableName", $srcCount, $dstCount, $match, $errSuffix)
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
