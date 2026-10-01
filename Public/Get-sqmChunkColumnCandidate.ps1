<#
.SYNOPSIS
    Finds and ranks usable -ChunkColumn candidates for a table, including how many chunks each
    one would produce - from metadata and statistics only, without scanning the table.

.DESCRIPTION
    Invoke-sqmChunkedTableTransfer needs a column whose distinct values become the chunk
    boundaries. Picking one by hand means knowing the table, and picking a bad one (a
    near-continuous timestamp) is only noticed once the transfer has already scanned the table
    and refuses to start. This function answers both questions up front and cheaply:

        1. Which columns are plausible chunk columns at all?
        2. How many chunks would each of them produce?

    Candidates are the table's date-typed columns (date, datetime, datetime2, smalldatetime,
    datetimeoffset), integer columns whose name follows a period convention (Jahr, Year,
    Monat, Month, Periode, Quartal, ...), and int/bigint/char/varchar columns holding yyyyMMdd
    dates (e.g. BOOKDATE = 20240115) whatever their name - recognised because every key of the
    column's statistics histogram is a valid yyyyMMdd date. A chunked transfer splits on
    reporting periods, not on arbitrary data.

    Day-resolution columns (yyyyMMdd surrogates, and date columns with clearly more distinct values
    than months) get SuggestedGranularity 'Month': one chunk per calendar month instead of one per
    day. EstimatedChunks is then the month span between the smallest and largest histogram key.

    The distinct-value count per candidate is ESTIMATED from the column's statistics histogram
    (SUM(distinct_range_rows) + one row per histogram step, via sys.dm_db_stats_histogram) - a
    metadata read, no table access, so it costs the same on a 344-million-row table as on an
    empty one. That estimate is what makes this safe to call from a GUI. It is an estimate: it is
    only as current as the statistics behind it, and sampled statistics on skewed data can be off.
    Ordering a good chunk column apart from a bad one does not need precision - the two differ by
    orders of magnitude, not percent - but do not treat the number as a row-level guarantee.
    Use -Exact when an exact answer is worth a full scan of the column.

    A candidate counts as Suitable when its estimate is at least 2 (one single value is not a
    chunking) and at most -MaxChunkValues. Results are returned best-first: suitable candidates
    before unsuitable ones, then by naming convention (Stichtag, ReportingDate, Dat_/dtm prefixes
    ahead of a generic date column), so [0] is the column to use.

.PARAMETER SqlInstance
    SQL Server instance holding the table.

.PARAMETER Database
    Database name.

.PARAMETER Table
    Table name ('Table' or 'schema.Table').

.PARAMETER SqlCredential
    Optional PSCredential.

.PARAMETER MaxChunkValues
    Upper bound on the number of chunks a candidate may produce and still count as Suitable.
    Default: the module's MaxChunkValueCeiling.

.PARAMETER Exact
    Replace the statistics estimate with an exact COUNT(DISTINCT [column]) per candidate.
    This is a full scan of each candidate column and can take minutes on a large table - the
    whole point of the default path is to avoid exactly that. Only worth it when the estimate
    lands near the -MaxChunkValues boundary and the decision actually depends on the difference.

.PARAMETER IncludeUnsuitable
    Also return candidates that failed the Suitable check, instead of dropping them. Useful for
    diagnosing why a table has no usable chunk column.

.OUTPUTS
    PSCustomObject per candidate: Table, ColumnName, DataType, EstimatedDistinctValues,
    SuggestedGranularity ('Value' or 'Month'), EstimatedChunks, IsDateSurrogate,
    EstimateSource ('Statistics', 'Exact' or 'Unknown'), TableRows, AvgRowsPerChunk, Suitable,
    Reason.

.EXAMPLE
    Get-sqmChunkColumnCandidate -SqlInstance SQL01 -Database DWH -Table dbo.Ergebnis_agg

    Lists the usable chunk columns with the number of chunks each would produce, best first.

.EXAMPLE
    $col = (Get-sqmChunkColumnCandidate -SqlInstance SQL01 -Database DWH -Table dbo.Umsatz)[0].ColumnName

    Takes the best candidate for use as -ChunkColumn.

.NOTES
    Prerequisites: dbatools. Reading sys.dm_db_stats_histogram requires SQL Server 2016 SP1 or
    newer; on an older version, or for a column without statistics, EstimatedDistinctValues is
    $null and EstimateSource is 'Unknown' - such a candidate is reported but not Suitable, since
    nothing is known about how many chunks it would produce.
#>
function Get-sqmChunkColumnCandidate
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $true)]
		[string]$Database,
		[Parameter(Mandatory = $true)]
		[string]$Table,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[int]$MaxChunkValues,
		[Parameter(Mandatory = $false)]
		[switch]$Exact,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeUnsuitable
	)

	$functionName = $MyInvocation.MyCommand.Name

	if (-not $PSBoundParameters.ContainsKey('MaxChunkValues') -or $MaxChunkValues -le 0)
	{
		$MaxChunkValues = Get-sqmTransferConfig -Key 'MaxChunkValueCeiling'
		if (-not $MaxChunkValues) { $MaxChunkValues = 2000 }
	}

	$schemaName = 'dbo'
	$tableName = $Table
	if ($Table -match '^(?<schema>[^.]+)\.(?<name>.+)$') { $schemaName = $Matches['schema']; $tableName = $Matches['name'] }
	$qualified = "[$schemaName].[$tableName]"

	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	# Kandidatenspalten samt Statistik-Schaetzung in EINER Metadatenabfrage. Der LEFT JOIN auf
	# sys.stats ist bewusst lose: eine Spalte ohne Statistik faellt nicht raus, sie bekommt nur
	# keine Schaetzung (EstimateSource = 'Unknown').
	#
	# Schaetzformel: jeder Histogrammschritt steuert seinen range_high_key als einen distinkten
	# Wert bei (COUNT_BIG(*)), dazu die distinkten Werte im Intervall davor (distinct_range_rows).
	# Das ist die uebliche Ableitung der Kardinalitaet aus dem Histogramm und kostet keinen
	# Tabellenzugriff.
	# Zusaetzlich zur Schaetzung: kleinster/groesster Histogrammschluessel (typisiert, als
	# sql_variant) und wie viele Schluessel wie ein yyyyMMdd-Datum aussehen. Damit wird eine
	# int-/char-Spalte mit Werten wie 20240115 als Datums-Surrogat erkannt, egal wie sie heisst
	# (z.B. BOOKDATE). Nur Konvertierung nach varchar - eine Konvertierung des sql_variant nach
	# datetime2 wuerde fuer int-Schluessel einen Ueberlauf werfen, auch in einem CASE-Zweig.
	$query = @"
SELECT  c.name                          AS ColumnName,
        TYPE_NAME(c.user_type_id)       AS DataType,
        est.EstDistinct                 AS EstimatedDistinctValues,
        est.KeyCnt, est.DayKeyCnt, est.MinKey, est.MaxKey,
        (SELECT SUM(ps.row_count)
         FROM sys.dm_db_partition_stats ps
         WHERE ps.object_id = c.object_id AND ps.index_id IN (0, 1)) AS TableRows
FROM sys.columns c
OUTER APPLY (
    SELECT TOP (1) h.EstDistinct, h.KeyCnt, h.DayKeyCnt, h.MinKey, h.MaxKey
    FROM sys.stats s
    JOIN sys.stats_columns sc
      ON  sc.object_id = s.object_id
      AND sc.stats_id  = s.stats_id
      AND sc.stats_column_id = 1
      AND sc.column_id = c.column_id
    CROSS APPLY (
        SELECT SUM(hh.distinct_range_rows) + COUNT_BIG(*) AS EstDistinct,
               COUNT(hh.range_high_key) AS KeyCnt,
               SUM(CASE WHEN LEN(CONVERT(varchar(30), hh.range_high_key)) = 8
                         AND CONVERT(varchar(30), hh.range_high_key) BETWEEN '19000101' AND '29991231'
                         AND TRY_CONVERT(date, CONVERT(varchar(30), hh.range_high_key), 112) IS NOT NULL THEN 1 ELSE 0 END) AS DayKeyCnt,
               MIN(hh.range_high_key) AS MinKey,
               MAX(hh.range_high_key) AS MaxKey
        FROM sys.dm_db_stats_histogram(s.object_id, s.stats_id) hh
    ) h
    WHERE s.object_id = c.object_id
    ORDER BY h.EstDistinct DESC
) est
WHERE c.object_id = OBJECT_ID(N'$qualified')
  AND c.is_computed = 0
  AND TYPE_NAME(c.user_type_id) IN ('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset',
                                    'int', 'smallint', 'tinyint', 'bigint', 'char', 'varchar', 'nchar', 'nvarchar')
ORDER BY c.column_id
"@

	try
	{
		$rows = @(Invoke-DbaQuery @connParams -Query $query -As PSObject -EnableException -ErrorAction Stop)
	}
	catch
	{
		# Ein Fehler hier ist eine echte Stoerung (Rechte, Verbindung, falsche Datenbank) und darf
		# nicht als "keine Kandidaten" durchgehen - siehe 0.1.16.0, wo genau so ein stiller
		# Fallback beinahe eine Tabelle verdoppelt haette.
		throw "Chunk-Spalten-Kandidaten fuer $qualified auf '$SqlInstance'.'$Database' konnten nicht ermittelt werden: $($_.Exception.Message)"
	}

	if ($rows.Count -eq 0)
	{
		Write-sqmTransferLog -Message "Keine Chunk-Spalten-Kandidaten fuer $qualified auf '$SqlInstance'.'$Database' gefunden (weder Datumsspalte noch Perioden-Spalte)." `
							 -FunctionName $functionName -Level 'INFO'
		return @()
	}

	# Namenskonventionen, hoechste Prioritaet zuerst - dieselbe Reihenfolge, die
	# Get-sqmSuggestedChunkColumn schon verwendet hat.
	$patterns = @('stichtag', 'reportingdate', '^dat_', '^dtm', 'datum', 'date', 'periode', 'period', 'jahr', 'year', 'monat', 'month', 'quartal', 'quarter', 'dat')
	$dateTypes = @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
	$periodNamePattern = 'jahr|year|monat|month|periode|period|quartal|quarter'

	$results = [System.Collections.Generic.List[PSCustomObject]]::new()

	foreach ($row in $rows)
	{
		$columnName = [string]$row.ColumnName
		$dataType = [string]$row.DataType
		$tableRows = if ($null -ne $row.TableRows -and $row.TableRows -isnot [System.DBNull]) { [int64]$row.TableRows } else { $null }

		# Welche Art Kandidat? Datumstyp / yyyyMMdd-Surrogat (alle Histogrammschluessel sind gueltige
		# Tagesdaten) / Ganzzahl mit Perioden-Namen (bisheriges Verhalten). Alles andere ist kein Kandidat.
		$keyCnt = if ($row.KeyCnt -is [System.DBNull] -or $null -eq $row.KeyCnt) { 0 } else { [int]$row.KeyCnt }
		$dayKeyCnt = if ($row.DayKeyCnt -is [System.DBNull] -or $null -eq $row.DayKeyCnt) { 0 } else { [int]$row.DayKeyCnt }
		$isDateType = $dataType -in $dateTypes
		$isDaySurrogate = (-not $isDateType) -and $dataType -in @('int', 'bigint', 'char', 'varchar', 'nchar', 'nvarchar') -and $keyCnt -ge 2 -and $dayKeyCnt -eq $keyCnt
		$isPeriodInt = $dataType -in @('int', 'smallint', 'tinyint', 'bigint') -and $columnName -match $periodNamePattern
		if (-not ($isDateType -or $isDaySurrogate -or $isPeriodInt)) { continue }

		# Monatsspanne aus kleinstem/groesstem Histogrammschluessel - Grundlage fuer Monats-Chunks
		$monthSpan = $null
		$minKey = $row.MinKey; $maxKey = $row.MaxKey
		if ($null -ne $minKey -and $minKey -isnot [System.DBNull] -and $null -ne $maxKey -and $maxKey -isnot [System.DBNull])
		{
			try
			{
				$toDate = {
					param($k)
					if ($k -is [datetimeoffset]) { return $k.DateTime }
					if ($k -is [datetime]) { return $k }
					[datetime]::ParseExact("$k".Trim(), 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
				}
				if ($isDateType -or $isDaySurrogate)
				{
					$minD = & $toDate $minKey; $maxD = & $toDate $maxKey
					$monthSpan = ($maxD.Year * 12 + $maxD.Month) - ($minD.Year * 12 + $minD.Month) + 1
				}
			}
			catch { $monthSpan = $null }
		}

		$estimate = $null
		$estimateSource = 'Unknown'
		if ($null -ne $row.EstimatedDistinctValues -and $row.EstimatedDistinctValues -isnot [System.DBNull])
		{
			$estimate = [int64]$row.EstimatedDistinctValues
			$estimateSource = 'Statistics'
		}

		if ($Exact)
		{
			# Bewusster Vollscan der Spalte, nur auf ausdruecklichen Wunsch (siehe -Exact).
			try
			{
				$exactCount = (Invoke-DbaQuery @connParams -Query "SELECT COUNT_BIG(DISTINCT [$columnName]) AS Cnt FROM $qualified" `
											   -As PSObject -EnableException -ErrorAction Stop -QueryTimeout 3600).Cnt
				$estimate = [int64]$exactCount
				$estimateSource = 'Exact'
			}
			catch
			{
				Write-Warning "Exakte Ermittlung der distinkten Werte fuer [$columnName] fehlgeschlagen, Statistik-Schaetzung bleibt bestehen: $($_.Exception.Message)"
			}
		}

		$nameRank = $patterns.Count
		for ($i = 0; $i -lt $patterns.Count; $i++)
		{
			if ($columnName -match $patterns[$i]) { $nameRank = $i; break }
		}

		# Tagesgenaue Spalte (yyyyMMdd-Surrogat, oder Datumstyp mit deutlich mehr Werten als Monaten)
		# -> monatsweise chunken: ein Chunk pro Tag waere bei Jahren an Daten zu kleinteilig.
		$granularity = 'Value'
		if ($null -ne $monthSpan -and $monthSpan -ge 2 -and $null -ne $estimate -and ($isDaySurrogate -or $estimate -gt $monthSpan * 1.5))
		{
			$granularity = 'Month'
		}
		$chunks = if ($granularity -eq 'Month') { [int64]$monthSpan } else { $estimate }
		$formatText = if ($isDaySurrogate) { ' (yyyyMMdd-Werte)' } else { '' }

		$suitable = $false
		$reason = ''
		if ($null -eq $chunks)
		{
			$reason = 'Keine Statistik auf der Spalte - Chunk-Anzahl unbekannt. Mit -Exact exakt ermitteln oder Statistik anlegen.'
		}
		elseif ($chunks -lt 2)
		{
			$reason = "Nur $chunks unterschiedliche(r) Wert(e) - ergibt keine Aufteilung."
		}
		elseif ($chunks -gt $MaxChunkValues)
		{
			$reason = "$chunks Chunks - mehr als MaxChunkValues ($MaxChunkValues), zu feingranular fuer einen Chunk-Transfer."
		}
		else
		{
			$suitable = $true
			$reason = if ($granularity -eq 'Month') { "$chunks Monats-Chunk(s)$formatText, statt $estimate Einzelwerten." } else { "$chunks Chunk(s)$formatText." }
		}

		$avgRowsPerChunk = $null
		if ($null -ne $chunks -and $chunks -gt 0 -and $null -ne $tableRows) { $avgRowsPerChunk = [int64][math]::Round($tableRows / $chunks) }

		$results.Add([PSCustomObject]@{
				Table				    = "$schemaName.$tableName"
				ColumnName			    = $columnName
				DataType			    = $dataType
				EstimatedDistinctValues = $estimate
				SuggestedGranularity    = $granularity
				EstimatedChunks		    = $chunks
				IsDateSurrogate		    = $isDaySurrogate
				EstimateSource		    = $estimateSource
				TableRows			    = $tableRows
				AvgRowsPerChunk		    = $avgRowsPerChunk
				Suitable			    = $suitable
				Reason				    = $reason
				NameRank			    = $nameRank
			})
	}

	$ordered = @($results | Sort-Object @{ Expression = { -not $_.Suitable } }, NameRank, ColumnName)
	if (-not $IncludeUnsuitable) { $ordered = @($ordered | Where-Object { $_.Suitable }) }

	return $ordered
}
