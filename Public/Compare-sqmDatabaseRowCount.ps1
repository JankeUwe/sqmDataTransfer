<#
.SYNOPSIS
    Compares row counts for every table between two databases at once - no table list required.

.DESCRIPTION
    Compare-sqmTableRowCount needs you to already know which tables to check. After an interrupted
    run over a large table set that's exactly the hard part: you don't know what's missing, what's
    short, or what's fine. Compare-sqmDatabaseRowCount answers that in one call by auto-discovering
    every table on both sides and comparing them:

        1. Reads row counts for ALL tables on both sides from SQL Server's own partition metadata
           (sys.partitions, summed per table for the heap/clustered index) - one cheap, set-based
           query per side. This does NOT scan table data, unlike a per-table SELECT COUNT_BIG(*):
           safe to run against a database with a billion rows without touching the buffer pool.
        2. Reports each table as Match, Mismatch, MissingOnSource, or MissingOnDestination.
        3. With -VerifyMismatches: re-checks only the tables flagged Mismatch with an exact
           SELECT COUNT_BIG(*) (via Compare-sqmTableRowCount), since partition metadata can be
           briefly out of step with reality during heavy concurrent writes. This is the one step
           that does touch data, and only for the tables that actually looked wrong.

.PARAMETER Source
    Source SQL Server instance.

.PARAMETER SourceDatabase
    Source database name.

.PARAMETER Destination
    Target SQL Server instance.

.PARAMETER DestinationDatabase
    Target database name.

.PARAMETER Table
    Optional filter - one or more table names ('Table' or 'schema.Table') to restrict the
    comparison to. Default: every table found on either side.

.PARAMETER SourceCredential
    Optional PSCredential for the source instance.

.PARAMETER DestinationCredential
    Optional PSCredential for the target instance.

.PARAMETER VerifyMismatches
    Re-checks tables flagged Mismatch with an exact SELECT COUNT_BIG(*) on both sides instead of
    trusting the partition-metadata estimate. Only touches the tables that actually mismatched.

.EXAMPLE
    Compare-sqmDatabaseRowCount -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales

    Lists every table on either side with source/target row counts and a status.

.EXAMPLE
    Compare-sqmDatabaseRowCount -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -VerifyMismatches |
        Where-Object Status -ne 'Match'

    Full-database check, exact-verifies anything that looked mismatched, and shows only the
    tables that still need attention.

.NOTES
    Prerequisites: dbatools (Invoke-DbaQuery), Write-sqmTransferLog, Compare-sqmTableRowCount
    (used internally by -VerifyMismatches).
#>
function Compare-sqmDatabaseRowCount
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
		[Parameter(Mandatory = $false)]
		[string[]]$Table,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SourceCredential,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DestinationCredential,
		[Parameter(Mandatory = $false)]
		[switch]$VerifyMismatches
	)

	$functionName = $MyInvocation.MyCommand.Name

	$srcConnParams = @{ SqlInstance = $Source; Database = $SourceDatabase; ErrorAction = 'Stop' }
	$dstConnParams = @{ SqlInstance = $Destination; Database = $DestinationDatabase; ErrorAction = 'Stop' }
	if ($SourceCredential) { $srcConnParams['SqlCredential'] = $SourceCredential }
	if ($DestinationCredential) { $dstConnParams['SqlCredential'] = $DestinationCredential }

	# Zeilenzahl aus sys.partitions (Heap/geclusterter Index) - Metadaten, kein Datenscan.
	$metaQuery = @"
SELECT s.name + N'.' + t.name AS TableName, SUM(p.rows) AS [RowCount]
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id
WHERE p.index_id IN (0, 1)
GROUP BY s.name, t.name
"@

	Write-sqmTransferLog -Message (Get-sqmTransferString -Key 'CompareDb.Start' -FormatArgs @($Source, $SourceDatabase, $Destination, $DestinationDatabase)) `
						  -FunctionName $functionName -Level 'INFO'

	$srcRows = @(Invoke-DbaQuery @srcConnParams -Query $metaQuery -As PSObject -EnableException)
	$dstRows = @(Invoke-DbaQuery @dstConnParams -Query $metaQuery -As PSObject -EnableException)

	$srcCounts = @{}
	foreach ($r in $srcRows) { $srcCounts[$r.TableName] = [int64]$r.RowCount }
	$dstCounts = @{}
	foreach ($r in $dstRows) { $dstCounts[$r.TableName] = [int64]$r.RowCount }

	if ($Table -and $Table.Count -gt 0)
	{
		$allTableNames = [System.Collections.Generic.List[string]]::new()
		foreach ($t in $Table)
		{
			$schemaName = 'dbo'; $tableName = $t
			if ($t -match '^(?<schema>[^.]+)\.(?<name>.+)$') { $schemaName = $Matches['schema']; $tableName = $Matches['name'] }
			$allTableNames.Add("$schemaName.$tableName")
		}
		$allTableNames = @($allTableNames | Sort-Object -Unique)
	}
	else
	{
		$allTableNames = @(($srcCounts.Keys + $dstCounts.Keys) | Sort-Object -Unique)
	}

	$results = [System.Collections.Generic.List[PSCustomObject]]::new()
	foreach ($tn in $allTableNames)
	{
		$hasSrc = $srcCounts.ContainsKey($tn)
		$hasDst = $dstCounts.ContainsKey($tn)
		$sc = if ($hasSrc) { $srcCounts[$tn] } else { $null }
		$dc = if ($hasDst) { $dstCounts[$tn] } else { $null }

		$status = if (-not $hasSrc) { 'MissingOnSource' }
		elseif (-not $hasDst) { 'MissingOnDestination' }
		elseif ($sc -eq $dc) { 'Match' }
		else { 'Mismatch' }

		$results.Add([PSCustomObject]@{
				Table		    = $tn
				SourceRows	    = $sc
				DestinationRows = $dc
				Difference	    = if ($hasSrc -and $hasDst) { $dc - $sc } else { $null }
				Status		    = $status
				Verified	    = $false
			})
	}

	$matchCount = @($results | Where-Object Status -eq 'Match').Count
	$mismatchCount = @($results | Where-Object Status -eq 'Mismatch').Count
	$missingSrcCount = @($results | Where-Object Status -eq 'MissingOnSource').Count
	$missingDstCount = @($results | Where-Object Status -eq 'MissingOnDestination').Count

	Write-sqmTransferLog -Message (Get-sqmTransferString -Key 'CompareDb.Summary' -FormatArgs @($results.Count, $matchCount, $mismatchCount, $missingSrcCount, $missingDstCount)) `
						  -FunctionName $functionName -Level $(if ($mismatchCount -gt 0 -or $missingSrcCount -gt 0 -or $missingDstCount -gt 0) { 'WARNING' } else { 'INFO' })

	if ($VerifyMismatches)
	{
		$toVerify = @($results | Where-Object Status -eq 'Mismatch' | ForEach-Object Table)
		if ($toVerify.Count -gt 0)
		{
			Write-sqmTransferLog -Message (Get-sqmTransferString -Key 'CompareDb.Verifying' -FormatArgs @($toVerify.Count)) -FunctionName $functionName -Level 'INFO'
			$exact = Compare-sqmTableRowCount -Source $Source -SourceDatabase $SourceDatabase `
											   -Destination $Destination -DestinationDatabase $DestinationDatabase `
											   -Table $toVerify -SourceCredential $SourceCredential -DestinationCredential $DestinationCredential

			foreach ($ex in $exact)
			{
				$target = $results | Where-Object Table -eq $ex.Table | Select-Object -First 1
				if (-not $target) { continue }
				$target.SourceRows = $ex.SourceRows
				$target.DestinationRows = $ex.DestinationRows
				$target.Difference = $ex.Difference
				$target.Status = if ($ex.Message) { 'Mismatch' } elseif ($ex.Match) { 'Match' } else { 'Mismatch' }
				$target.Verified = $true
			}
		}
	}

	return $results
}
