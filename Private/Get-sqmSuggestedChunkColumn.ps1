<#
.SYNOPSIS
    Suggests a -ChunkColumn candidate for a table, from metadata only - no data scan.

.DESCRIPTION
    Reads sys.columns/sys.types for date-typed columns (date, datetime, datetime2,
    smalldatetime, datetimeoffset) and ranks them by naming convention instead of actually
    counting distinct values - a COUNT(DISTINCT ...) to verify a candidate would be exactly the
    kind of expensive scan this is meant to help avoid on a large table. This is a plausible
    starting point for -ChunkColumn, not a verified one: Invoke-sqmChunkedTableTransfer's own
    -MaxChunkValues check is what actually catches a bad choice (too many distinct values) once
    the user tries it.

.PARAMETER SqlInstance
    SQL Server instance.

.PARAMETER Database
    Database name.

.PARAMETER Table
    Table name ('Table' or 'schema.Table').

.PARAMETER SqlCredential
    Optional PSCredential.

.NOTES
    Private helper. Returns a single column name (string) or $null if no date-typed column
    exists on the table.
#>
function Get-sqmSuggestedChunkColumn
{
	[CmdletBinding()]
	[OutputType([string])]
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
	if ($Table -match '^(?<schema>[^.]+)\.(?<name>.+)$') { $schemaName = $Matches['schema']; $tableName = $Matches['name'] }

	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database; ErrorAction = 'Stop' }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$query = @"
SELECT c.name AS ColumnName
FROM sys.columns c
WHERE c.object_id = OBJECT_ID(N'[$schemaName].[$tableName]')
  AND TYPE_NAME(c.user_type_id) IN ('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
ORDER BY c.column_id
"@

	try
	{
		$candidates = @(Invoke-DbaQuery @connParams -Query $query -As PSObject -EnableException | Select-Object -ExpandProperty ColumnName)
	}
	catch
	{
		return $null
	}

	if ($candidates.Count -eq 0) { return $null }

	# Namenskonventionen, hoechste Prioritaet zuerst - passend zu den Mustern, die im Modul selbst
	# schon vorkommen (Dat_ReportingDate, dtmStichtag).
	$patterns = @('stichtag', 'reportingdate', '^dat_', '^dtm', 'datum', 'date')
	foreach ($pattern in $patterns)
	{
		$hit = $candidates | Where-Object { $_ -match $pattern } | Select-Object -First 1
		if ($hit) { return $hit }
	}

	return $candidates[0]
}
