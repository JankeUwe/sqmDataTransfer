<#
.SYNOPSIS
    Checks whether a destination table has any columnstore index (clustered or nonclustered).

.DESCRIPTION
    Used by Copy-sqmTableData to decide whether the columnstore-safe batch-size cap applies
    (see Set-sqmTransferConfig -ColumnstoreBatchSizeCeiling). A single metadata query against
    sys.indexes - no table scan, cheap regardless of table size.

    A destination that doesn't exist yet, or any failure reading its metadata, is treated the
    same as "not columnstore" - this check only gates a performance optimization, not
    correctness, so it must never abort a copy that would otherwise have succeeded.

.PARAMETER SqlInstance
    Destination SQL Server instance.

.PARAMETER Database
    Destination database name.

.PARAMETER Table
    Destination table ('Table' or 'schema.Table').

.PARAMETER SqlCredential
    Optional PSCredential for the destination instance.

.NOTES
    Private helper for Copy-sqmTableData - not exported.
#>
function Test-sqmDestinationIsColumnstore
{
	[CmdletBinding()]
	[OutputType([bool])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $true)]
		[string]$Database,
		[Parameter(Mandatory = $true)]
		[string]$Table,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$schemaName = 'dbo'
	$tableName = $Table
	if ($Table -match '^\[?(?<schema>[^.\]]+)\]?\.\[?(?<name>[^\]]+)\]?$')
	{
		$schemaName = $Matches['schema']
		$tableName = $Matches['name']
	}
	$bracketed = "[$schemaName].[$tableName]"

	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database; ErrorAction = 'Stop' }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	try
	{
		$query = "SELECT COUNT(*) AS Cnt FROM sys.indexes WHERE object_id = OBJECT_ID(N'$bracketed') AND type_desc LIKE '%COLUMNSTORE%'"
		$result = Invoke-DbaQuery @connParams -Query $query -As PSObject -EnableException
		return ([int64]$result.Cnt -gt 0)
	}
	catch
	{
		Write-Verbose "Test-sqmDestinationIsColumnstore: Pruefung fuer $bracketed auf '$SqlInstance'.'$Database' fehlgeschlagen, wird als Nicht-Columnstore behandelt: $($_.Exception.Message)"
		return $false
	}
}
