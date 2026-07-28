<#
.SYNOPSIS
    Bulk-copies a custom query's result set into a destination table, mapping columns by NAME.

.DESCRIPTION
    dbatools' Copy-DbaDbTableData only builds real name-based SqlBulkCopy.ColumnMappings for a
    plain -Table copy. With a custom -Query (needed for Invoke-sqmChunkedTableTransfer's WHERE-
    filtered chunks), it leaves ColumnMappings empty unless -ForceExplicitMapping is passed - a
    parameter that doesn't exist in older dbatools versions at all (confirmed: 2.7.1 doesn't have
    it, 2.8.2 does). Depending on a specific dbatools version being installed on every machine this
    runs on - including remote/production hosts that are hard to update - is exactly the kind of
    fragile dependency this function exists to avoid. This is a minimal, self-contained
    replacement for just the -Query code path: connects via dbatools (Connect-DbaInstance, so
    Windows/SQL auth and TrustServerCertificate handling stay consistent with the rest of the
    module), then drives Microsoft.Data.SqlClient.SqlBulkCopy directly with explicit NAME-based
    ColumnMappings built from the destination's actual non-computed columns - immune to column
    order and computed-column position on either side, with no dependency on dbatools' internal
    -Query handling at all.

.PARAMETER SqlInstance
    Source SQL Server instance.

.PARAMETER Database
    Source database name.

.PARAMETER Query
    The SELECT to use as the row source.

.PARAMETER SqlCredential
    Optional PSCredential for the source instance.

.PARAMETER Destination
    Target SQL Server instance.

.PARAMETER DestinationDatabase
    Target database name.

.PARAMETER DestinationTable
    Target table ('Table' or 'schema.Table').

.PARAMETER DestinationSqlCredential
    Optional PSCredential for the target instance.

.PARAMETER Truncate
    Truncate the destination table before copying.

.PARAMETER KeepIdentity
    Preserve source IDENTITY column values on the target.

.PARAMETER KeepNulls
    Preserve NULL values instead of applying target column defaults.

.PARAMETER BatchSize
    Rows per batch.

.PARAMETER BulkCopyTimeOut
    Bulk copy timeout in seconds.

.PARAMETER NotifyAfter
    Rows per SqlRowsCopied notification (0/unset disables notifications).

.PARAMETER ProgressActivity
    When set, shows live Write-Progress (Id 2, matching Copy-sqmTableData's convention) on each
    SqlRowsCopied notification. Requires -NotifyAfter to be greater than 0.

.NOTES
    Private helper for Copy-sqmTableData - not exported. Only used for the -SourceQuery path;
    a plain -Table copy still goes through Copy-DbaDbTableData as before (already correct there,
    no version dependency concern).
#>
function Invoke-sqmDirectBulkCopy
{
	[CmdletBinding(SupportsShouldProcess = $true)]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $true)]
		[string]$Database,
		[Parameter(Mandatory = $true)]
		[string]$Query,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[string]$Destination,
		[Parameter(Mandatory = $true)]
		[string]$DestinationDatabase,
		[Parameter(Mandatory = $true)]
		[string]$DestinationTable,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DestinationSqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$Truncate,
		[Parameter(Mandatory = $false)]
		[bool]$KeepIdentity = $true,
		[Parameter(Mandatory = $false)]
		[bool]$KeepNulls = $true,
		[Parameter(Mandatory = $false)]
		[int]$BatchSize = 500000,
		[Parameter(Mandatory = $false)]
		[int]$BulkCopyTimeOut = 300,
		[Parameter(Mandatory = $false)]
		[int]$NotifyAfter = 0,
		[Parameter(Mandatory = $false)]
		[string]$ProgressActivity
	)

	$schemaName = 'dbo'
	$tableName = $DestinationTable
	if ($DestinationTable -match '^\[?(?<schema>[^.\]]+)\]?\.\[?(?<name>[^\]]+)\]?$')
	{
		$schemaName = $Matches['schema']
		$tableName = $Matches['name']
	}
	$bracketedDest = "[$schemaName].[$tableName]"

	$srcParams = @{ SqlInstance = $SqlInstance; Database = $Database; ErrorAction = 'Stop' }
	if ($SqlCredential) { $srcParams['SqlCredential'] = $SqlCredential }
	$srcServer = Connect-DbaInstance @srcParams

	$dstParams = @{ SqlInstance = $Destination; ErrorAction = 'Stop' }
	if ($DestinationSqlCredential) { $dstParams['SqlCredential'] = $DestinationSqlCredential }
	$dstServer = Connect-DbaInstance @dstParams

	if ($Truncate)
	{
		if ($PSCmdlet.ShouldProcess($Destination, "TRUNCATE TABLE $bracketedDest"))
		{
			Invoke-DbaQuery -SqlInstance $dstServer -Database $DestinationDatabase -Query "TRUNCATE TABLE $bracketedDest" -EnableException | Out-Null
		}
	}

	# Nur nicht-berechnete Zielspalten sind gueltige Mapping-Ziele.
	$destColumns = @(Invoke-DbaQuery -SqlInstance $dstServer -Database $DestinationDatabase `
			-Query "SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(N'$bracketedDest') AND is_computed = 0" `
			-As PSObject -EnableException | Select-Object -ExpandProperty name)
	if ($destColumns.Count -eq 0)
	{
		throw "Zieltabelle $bracketedDest auf '$Destination'.'$DestinationDatabase' nicht gefunden oder ohne Spalten."
	}
	$destSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$destColumns, [System.StringComparer]::OrdinalIgnoreCase)

	if (-not $srcServer.ConnectionContext.IsOpen) { $srcServer.ConnectionContext.SqlConnectionObject.Open() }
	$cmd = $srcServer.ConnectionContext.SqlConnectionObject.CreateCommand()
	$cmd.CommandTimeout = $BulkCopyTimeOut
	$cmd.CommandText = $Query

	$bulkCopyOptions = [Microsoft.Data.SqlClient.SqlBulkCopyOptions]::TableLock
	if ($KeepIdentity) { $bulkCopyOptions = $bulkCopyOptions -bor [Microsoft.Data.SqlClient.SqlBulkCopyOptions]::KeepIdentity }
	if ($KeepNulls) { $bulkCopyOptions = $bulkCopyOptions -bor [Microsoft.Data.SqlClient.SqlBulkCopyOptions]::KeepNulls }

	$connString = $dstServer.ConnectionContext.ConnectionString
	$bulkCopy = New-Object Microsoft.Data.SqlClient.SqlBulkCopy("$connString;Database=$DestinationDatabase", $bulkCopyOptions)
	$bulkCopy.DestinationTableName = $bracketedDest
	$bulkCopy.BatchSize = $BatchSize
	$bulkCopy.BulkCopyTimeout = $BulkCopyTimeOut
	if ($NotifyAfter -gt 0)
	{
		$bulkCopy.NotifyAfter = $NotifyAfter
		if ($ProgressActivity)
		{
			$bulkCopy.add_SqlRowsCopied({
					param($bcSender, $bcArgs)
					Write-Progress -Id 2 -Activity $ProgressActivity -Status "$($bcArgs.RowsCopied) Zeile(n) kopiert..."
				})
		}
	}

	$reader = $null
	try
	{
		if ($PSCmdlet.ShouldProcess($Destination, "Bulk copy into $bracketedDest"))
		{
			$reader = $cmd.ExecuteReader()

			$mappedCount = 0
			for ($i = 0; $i -lt $reader.FieldCount; $i++)
			{
				$sourceColumn = $reader.GetName($i)
				if ($destSet.Contains($sourceColumn))
				{
					$null = $bulkCopy.ColumnMappings.Add($sourceColumn, $sourceColumn)
					$mappedCount++
				}
			}
			if ($mappedCount -eq 0)
			{
				throw "Keine gemeinsamen Spalten zwischen Quellabfrage und $bracketedDest gefunden - nichts zu kopieren."
			}

			$bulkCopy.WriteToServer($reader)
		}
	}
	finally
	{
		if ($reader) { $reader.Close() }
		$bulkCopy.Close()
		$bulkCopy.Dispose()
		if ($srcServer.ConnectionContext.IsOpen) { $srcServer.ConnectionContext.SqlConnectionObject.Close() }
	}

	return [PSCustomObject]@{ RowsCopied = [int64]$bulkCopy.RowsCopied }
}
