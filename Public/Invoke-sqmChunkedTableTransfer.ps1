<#
.SYNOPSIS
    Transfers one large table in independently retryable chunks, one call per distinct value of a
    chunking column, instead of a single all-or-nothing copy.

.DESCRIPTION
    A single Invoke-sqmTableTransfer call on a huge table is all-or-nothing: if the copy is
    interrupted (network blip, a hung client, a killed session), there is no reliable way to know
    which rows already made it across without a primary/unique key to anti-join on - and no way to
    resume without re-copying everything. Invoke-sqmChunkedTableTransfer splits the table by a
    discriminating column (typically a reporting/snapshot date such as "Stichtag") and transfers it
    one distinct value at a time:

        1. Discovers every distinct -ChunkColumn value on the source, together with its row count,
           in a single GROUP BY scan (capped at -MaxChunkValues) - this function is for a column
           with a modest number of distinct values (dozens to a few hundred, e.g. monthly
           snapshots), not a near-continuous timestamp. A second single GROUP BY scan snapshots the
           destination's per-chunk row counts up front (skipped entirely after -Truncate or when
           the destination doesn't exist yet - both mean every chunk is empty).
        2. Optional -Truncate empties the destination table ONCE, up front - not per chunk, since
           TRUNCATE TABLE is table-wide regardless of any WHERE filter.
        3. For each distinct value, compares row counts for just that slice against the two
           snapshots from step 1 - an in-memory lookup, not a live query. A slice whose counts
           already match is skipped - this is what makes a re-run after a partial failure resume
           from where it left off, without needing a row-level key. (Earlier versions ran a live
           COUNT_BIG(*) WHERE [ChunkColumn] = value on both sides per chunk, before AND after the
           copy - up to 4 full unindexed scans per chunk, since indexes are disabled for the whole
           run. On a table with hundreds of chunks this made row-counting the dominant cost of the
           entire run, ahead of the actual data copy. The post-copy comparison is likewise now a
           single GROUP BY scan on the destination after the last chunk, not one COUNT_BIG(*) pair
           per chunk.)
        4. Any slice that doesn't match gets a normal Invoke-sqmTableTransfer call scoped to just
           that value via -SourceQuery (SELECT * ... WHERE [ChunkColumn] = value) - safe
           regardless of column order or computed columns on either side, since Copy-sqmTableData
           routes any -SourceQuery copy through Invoke-sqmDirectBulkCopy, which builds a real
           NAME-based column mapping directly against SqlBulkCopy instead of relying on dbatools'
           own -Query handling - with per-chunk reports suppressed (-NoReport) so a large chunk
           count doesn't produce a report pile-up - see Export-sqmTransferReport for the single
           consolidated report written at the end.
        5. Foreign keys/indexes/triggers on the destination are disabled ONCE before the first
           chunk and re-enabled (indexes: REBUILD) ONCE after the last one - not per chunk. A
           rebuild is a whole-table operation regardless of how narrow the WHERE filter was, so
           disabling and rebuilding per chunk multiplied the cost of that rebuild by the chunk
           count for no benefit - on a table with hundreds of chunks this dwarfed the actual data
           copy time. See -SkipConstraintHandling to opt out entirely.

.PARAMETER Source
    Source SQL Server instance.

.PARAMETER SourceDatabase
    Source database name.

.PARAMETER Destination
    Target SQL Server instance.

.PARAMETER DestinationDatabase
    Target database name.

.PARAMETER Table
    The single table to transfer ('Table' or 'schema.Table').

.PARAMETER ChunkColumn
    Column to split the transfer on. Its distinct values (as they exist on the source) become the
    chunk boundaries - one Invoke-sqmTableTransfer call per value.

    OPTIONAL. Omit it and the column is detected automatically via Get-sqmChunkColumnCandidate:
    date-typed and period-named columns are ranked by naming convention (Stichtag, ReportingDate,
    Dat_/dtm prefixes first) and by how many chunks each would produce, estimated from the column's
    statistics histogram - metadata only, no table scan. The chosen column, its estimated chunk
    count and the reason are written to the log, so an automatic choice stays reviewable. If no
    candidate qualifies, the function throws and names what it rejected and why, rather than
    guessing.

.PARAMETER MaxChunkValues
    Safety cap on the number of distinct -ChunkColumn values this function will process. A
    near-continuous column (e.g. an exact timestamp) is the wrong choice for -ChunkColumn and would
    produce thousands of tiny calls.

    OPTIONAL. Omit it and the cap is the module's MaxChunkValueCeiling (default 2000): the actual
    number of distinct values found is accepted up to that ceiling. The previous fixed default of
    500 aborted an otherwise perfectly fine run on a table with, say, 800 monthly values and forced
    a second attempt with the right number - the count is already known from the GROUP BY the
    function runs anyway, so there is nothing to guess. Pass an explicit value to override, or
    Set-sqmTransferConfig -MaxChunkValueCeiling to change it permanently.

.PARAMETER Truncate
    Empty the destination table once, before the first chunk - not per chunk (see DESCRIPTION).

.PARAMETER SqlCredential
    Optional PSCredential for both instances. For different credentials use
    -SourceCredential / -DestinationCredential.

.PARAMETER SourceCredential
    PSCredential specifically for the source instance.

.PARAMETER DestinationCredential
    PSCredential specifically for the target instance.

.PARAMETER ScriptMetadata
    Script the table's metadata from the source and create it on the target if it does not
    already exist there (checked once, before the first chunk).

.PARAMETER IncludeForeignKeys
    Include foreign keys in the disable/enable handling around the whole chunked transfer
    (once, not per chunk). Default: $true.

.PARAMETER IncludeIndexes
    Include indexes in the disable/enable handling around the whole chunked transfer
    (once, not per chunk). Default: $true.

.PARAMETER IncludeTriggers
    Include triggers in the disable/enable handling around the whole chunked transfer
    (once, not per chunk). Default: $true.

.PARAMETER SkipConstraintHandling
    Skip disabling/re-enabling foreign keys, indexes and triggers entirely.

.PARAMETER RevalidateForeignKeys
    Revalidate foreign key data when re-enabling (WITH CHECK). Default: $true.

.PARAMETER KeepIdentity
    Preserve source IDENTITY column values on the target. Default: $true.

.PARAMETER KeepNulls
    Preserve NULL values instead of applying target column defaults. Default: $true.

.PARAMETER BatchSize
    Rows per batch for each chunk's data copy. Default: the module's DefaultBatchSize.

.PARAMETER ContinueOnError
    Continue with the next chunk on error.

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER OutputPath
    Folder the single consolidated HTML report is written to. Same convention as
    Invoke-sqmTableTransfer.

.PARAMETER NoReport
    Skip generating this table's consolidated HTML report entirely. Useful when chunk-transferring
    several large tables in a row (one Invoke-sqmChunkedTableTransfer call per table) - a report
    per table would otherwise pile up the same way a report per Invoke-sqmTableTransfer call did.
    Use Invoke-sqmCompleteTransferReport afterwards for a single report covering every table.

.PARAMETER NoOpen
    Do not automatically open the consolidated HTML report after the run. Ignored when -NoReport
    is set.

.PARAMETER Confirm
.PARAMETER WhatIf

.EXAMPLE
    Invoke-sqmChunkedTableTransfer -Source SUEB001IBP -SourceDatabase FXUeberleitung `
        -Destination SQL02 -DestinationDatabase FXUeberleitung -Table dbo.ACC_ATOM_GUV_PLUS `
        -ChunkColumn dtmStichtag -Truncate

    Transfers ACC_ATOM_GUV_PLUS one Stichtag at a time. If interrupted, re-running the identical
    command (without -Truncate) skips every Stichtag that already matches and only copies the rest.

.EXAMPLE
    Invoke-sqmChunkedTableTransfer -Source SQL01 -SourceDatabase DWH `
        -Destination SQL02 -DestinationDatabase DWH -Table dbo.Umsatz

    Same run without -ChunkColumn and without -MaxChunkValues: the chunk column is detected from
    the table's metadata and statistics, and the chunk count is taken from what is actually there.
    Check the log line "Chunk-Spalte automatisch gewaehlt" to see which column was picked and why.

.NOTES
    Prerequisites: dbatools, Invoke-sqmTableTransfer, Export-sqmTransferReport.
    No primary/unique key is required on the table - resumability is per chunk value, not per row.
#>
function Invoke-sqmChunkedTableTransfer
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
		[string]$Table,
		[Parameter(Mandatory = $false)]
		[string]$ChunkColumn,
		[Parameter(Mandatory = $false)]
		[int]$MaxChunkValues,
		[Parameter(Mandatory = $false)]
		[switch]$Truncate,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SourceCredential,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DestinationCredential,
		[Parameter(Mandatory = $false)]
		[switch]$ScriptMetadata,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeForeignKeys = $true,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeIndexes = $true,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeTriggers = $true,
		[Parameter(Mandatory = $false)]
		[switch]$SkipConstraintHandling,
		[Parameter(Mandatory = $false)]
		[bool]$RevalidateForeignKeys = $true,
		[Parameter(Mandatory = $false)]
		[bool]$KeepIdentity = $true,
		[Parameter(Mandatory = $false)]
		[bool]$KeepNulls = $true,
		[Parameter(Mandatory = $false)]
		[int]$BatchSize,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$NoReport,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)

	$functionName = $MyInvocation.MyCommand.Name

	$srcCred = if ($SourceCredential) { $SourceCredential } elseif ($SqlCredential) { $SqlCredential } else { $null }
	$dstCred = if ($DestinationCredential) { $DestinationCredential } elseif ($SqlCredential) { $SqlCredential } else { $null }

	if (-not $PSBoundParameters.ContainsKey('OutputPath') -or [string]::IsNullOrWhiteSpace($OutputPath))
	{
		$OutputPath = Get-sqmTransferConfig -Key 'OutputPath'
		if (-not $OutputPath) { $OutputPath = "C:\System\WinSrvLog\MSSQL" }
	}

	$schemaName = 'dbo'
	$tableName = $Table
	if ($Table -match '^(?<schema>[^.]+)\.(?<name>.+)$') { $schemaName = $Matches['schema']; $tableName = $Matches['name'] }
	$qualified = "$schemaName.$tableName"
	$bracketed = "[$schemaName].[$tableName]"

	# Kein ErrorAction hier: jeder Invoke-DbaQuery-Aufruf unten setzt ohnehin -EnableException, was
	# -ErrorAction in dbatools komplett ueberschreibt - waere also redundant. Fuer die drei
	# Get-DbaDbTable-Existenzchecks unten (die bewusst -ErrorAction SilentlyContinue brauchen) waere
	# ein ErrorAction = 'Stop' hier dagegen ein echter Fehler ("Parameter mehr als einmal angegeben"),
	# weil -Table/-Schema/-ErrorAction dann doppelt gebunden wuerden.
	$srcConnParams = @{ SqlInstance = $Source; Database = $SourceDatabase }
	$dstConnParams = @{ SqlInstance = $Destination; Database = $DestinationDatabase }
	if ($srcCred) { $srcConnParams['SqlCredential'] = $srcCred }
	if ($dstCred) { $dstConnParams['SqlCredential'] = $dstCred }

	# --- Formats a chunk value as a safe SQL literal for the WHERE clause below. Types come back
	# from Invoke-DbaQuery -As PSObject as real .NET types (DateTime, string, numeric, ...), not
	# strings, so this switches on the runtime type rather than guessing from formatting.
	function Format-SqlLiteral($value)
	{
		if ($null -eq $value) { return 'NULL' }
		if ($value -is [datetime]) { return "'$($value.ToString('yyyy-MM-ddTHH:mm:ss.fff'))'" }
		if ($value -is [string]) { return "N'$($value -replace "'", "''")'" }
		if ($value -is [bool]) { return $(if ($value) { '1' } else { '0' }) }
		return "$value"
	}

	# --- Chunk-Spalte automatisch bestimmen, wenn keine angegeben wurde -------------------------
	# Get-sqmChunkColumnCandidate arbeitet rein auf Metadaten und Statistiken (kein Tabellenscan),
	# kostet also auf einer 344-Mio-Zeilen-Tabelle dasselbe wie auf einer leeren. Die Auswahl wird
	# protokolliert - eine automatisch gewaehlte Spalte, die niemand nachvollziehen kann, waere
	# schlimmer als gar keine Automatik.
	$chunkColumnAutoDetected = $false
	if ([string]::IsNullOrWhiteSpace($ChunkColumn))
	{
		$candidates = @(Get-sqmChunkColumnCandidate -SqlInstance $Source -Database $SourceDatabase -Table $Table `
													-SqlCredential $srcCred -MaxChunkValues $MaxChunkValues -IncludeUnsuitable)
		$usable = @($candidates | Where-Object { $_.Suitable })

		if ($usable.Count -eq 0)
		{
			$detail = if ($candidates.Count -gt 0)
			{
				' Geprueft: ' + (($candidates | ForEach-Object { "[$($_.ColumnName)] $($_.Reason)" }) -join ' ')
			}
			else { ' Es gibt weder eine Datums- noch eine Perioden-Spalte auf dieser Tabelle.' }

			throw "Fuer $qualified auf '$Source'.'$SourceDatabase' konnte keine geeignete Chunk-Spalte ermittelt werden - bitte -ChunkColumn explizit angeben.$detail"
		}

		$ChunkColumn = $usable[0].ColumnName
		$chunkColumnAutoDetected = $true
		$autoMessage = "Chunk-Spalte automatisch gewaehlt: [$ChunkColumn] ($($usable[0].DataType), geschaetzt $($usable[0].EstimatedDistinctValues) Chunk(s), " + `
		"ca. $($usable[0].AvgRowsPerChunk) Zeile(n) pro Chunk, Quelle der Schaetzung: $($usable[0].EstimateSource))."
		Write-Verbose $autoMessage
		Write-sqmTransferLog -Message $autoMessage -FunctionName $functionName -Level 'INFO'
	}

	# --- MaxChunkValues automatisch bestimmen, wenn nicht explizit gesetzt ----------------------
	# Die GROUP BY-Abfrage weiter unten liefert die tatsaechliche Anzahl unterschiedlicher Werte
	# ohnehin. Ein fester Default (frueher 500) hat einen Lauf an einer Tabelle mit z.B. 800
	# Monatswerten abgebrochen und einen zweiten Anlauf mit passender Zahl erzwungen, obwohl die
	# Spalte voellig in Ordnung war. Ohne expliziten Wert gilt daher die Obergrenze aus der
	# Modulkonfiguration: alles darunter wird akzeptiert, alles darueber ist wirklich zu
	# feingranular und bricht mit Begruendung ab.
	$maxChunkValuesAutomatic = -not $PSBoundParameters.ContainsKey('MaxChunkValues') -or $MaxChunkValues -le 0
	if ($maxChunkValuesAutomatic)
	{
		$MaxChunkValues = Get-sqmTransferConfig -Key 'MaxChunkValueCeiling'
		if (-not $MaxChunkValues) { $MaxChunkValues = 2000 }
	}

	Write-sqmTransferLog -Message "Invoke-sqmChunkedTableTransfer: '$Source'.'$SourceDatabase'.$qualified -> '$Destination'.'$DestinationDatabase' per '$ChunkColumn'" `
						  -FunctionName $functionName -Level 'INFO'

	# A plain "SELECT * FROM source" is fine here regardless of column order, computed columns, or
	# a genuine schema mismatch between source and destination - Copy-sqmTableData routes any
	# -SourceQuery copy through Invoke-sqmDirectBulkCopy, which builds a real NAME-based
	# SqlBulkCopy.ColumnMappings directly (matching what dbatools itself already does for a plain
	# -Table copy) instead of relying on SqlBulkCopy's own implicit ORDINAL mapping against the
	# destination's full physical column list. That implicit fallback is what caused real breakage
	# here: a computed column ANYWHERE before the end of the table (not just excluded from the
	# SELECT list, simply existing earlier in physical column order) silently shifts every later
	# column's mapping by one position - reproduced against a real 108-column production table
	# (FXUeberleitung.Ergebnis_agg, computed column at physical position 3) where two unrelated
	# columns 12 positions later ended up mapped to each other. Column-count/order reconstruction
	# on our side was the wrong fix for that; explicit name-based mapping is the correct one - and
	# doing it ourselves means no dependency on which dbatools version is installed.
	#
	# Only remaining concern with plain SELECT * is columns that exist on just one side - dbatools
	# handles this safely either way (a destination-only column is left at its default/NULL, a
	# source-only column is silently not copied), but silent is exactly the risk worth flagging.
	$srcColQuery = "SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(N'$bracketed') AND is_computed = 0 ORDER BY column_id"
	$srcColumnNames = @(Invoke-DbaQuery @srcConnParams -Query $srcColQuery -As PSObject -EnableException | Select-Object -ExpandProperty name)
	if ($srcColumnNames.Count -eq 0)
	{
		throw "Konnte keine Spalten fuer $qualified auf '$Source'.'$SourceDatabase' ermitteln - Tabelle existiert nicht oder ist nicht lesbar."
	}

	# OBJECT_ID() on a table that genuinely doesn't exist yet returns NULL and this query simply
	# comes back empty - no exception needed for that case. An exception here means the query
	# itself failed (permissions, connectivity, wrong database context, ...) and must be visible,
	# not silently treated the same as "table doesn't exist".
	$dstColQuery = "SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(N'$bracketed') AND is_computed = 0 ORDER BY column_id"
	$dstColumnNames = @(Invoke-DbaQuery @dstConnParams -Query $dstColQuery -As PSObject -EnableException | Select-Object -ExpandProperty name)

	if ($dstColumnNames.Count -gt 0)
	{
		$srcSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$srcColumnNames, [System.StringComparer]::OrdinalIgnoreCase)
		$dstSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$dstColumnNames, [System.StringComparer]::OrdinalIgnoreCase)
		$missingOnSource = @($dstColumnNames | Where-Object { -not $srcSet.Contains($_) })
		$missingOnDestination = @($srcColumnNames | Where-Object { -not $dstSet.Contains($_) })
		if ($missingOnSource.Count -gt 0)
		{
			$msg = "Spalte(n) nur auf Ziel vorhanden, bleiben bei $qualified auf Default/NULL (keine Quelldaten): $($missingOnSource -join ', ')"
			Write-Warning $msg
			Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'WARNING'
		}
		if ($missingOnDestination.Count -gt 0)
		{
			$msg = "Spalte(n) nur auf Quelle vorhanden, werden bei $qualified NICHT uebertragen (fehlen auf dem Ziel): $($missingOnDestination -join ', ')"
			Write-Warning $msg
			Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'WARNING'
		}
	}

	$columnList = '*'

	# --- Eine GROUP BY-Abfrage statt DISTINCT liefert die Zeilenzahl pro Chunk-Wert gleich mit -
	# kostet keinen zusaetzlichen Scan (derselbe Scan haette DISTINCT sowieso gebraucht), macht aber
	# den Skip-/Nachvergleich pro Chunk unten zu einem reinen Hashtable-Lookup statt einer eigenen
	# COUNT_BIG(*)-Abfrage. Das war vorher die Hauptkostenquelle bei vielen Chunks: pro Chunk bis zu
	# vier volle Scans (Skip-Check vor dem Kopieren: Quelle+Ziel, Vergleich danach: Quelle+Ziel), alle
	# ohne Indexunterstuetzung, weil Indizes fuer den gesamten Lauf deaktiviert sind - bei einer
	# grossen Tabelle mit hunderten Chunks hat das den RowCount-Anteil zur dominanten Kostenquelle
	# gemacht, weit vor der eigentlichen Datenkopie.
	$chunkQuery = "SELECT [$ChunkColumn] AS ChunkValue, COUNT_BIG(*) AS Cnt FROM $bracketed GROUP BY [$ChunkColumn] ORDER BY [$ChunkColumn]"
	$chunkRows = @(Invoke-DbaQuery @srcConnParams -Query $chunkQuery -As PSObject -EnableException -QueryTimeout 3600)
	$chunkValues = @($chunkRows | Select-Object -ExpandProperty ChunkValue)

	if ($chunkValues.Count -eq 0)
	{
		Write-Warning "Keine Werte in '$ChunkColumn' auf '$Source'.'$SourceDatabase'.$qualified gefunden - nichts zu tun."
		return @()
	}
	if ($chunkValues.Count -gt $MaxChunkValues)
	{
		$limitText = if ($maxChunkValuesAutomatic)
		{
			"mehr als die automatische Obergrenze MaxChunkValueCeiling ($MaxChunkValues). Mit -MaxChunkValues $($chunkValues.Count) " + `
			"laesst sich das ueberstimmen, dauerhaft ueber Set-sqmTransferConfig -MaxChunkValueCeiling."
		}
		else
		{
			"mehr als das angegebene -MaxChunkValues ($MaxChunkValues)."
		}
		$columnText = if ($chunkColumnAutoDetected) { "die automatisch gewaehlte Spalte '$ChunkColumn'" } else { "'$ChunkColumn'" }
		throw "$columnText hat $($chunkValues.Count) unterschiedliche Werte auf $qualified - $limitText " + `
			"Bei so vielen Werten ist die Spalte fuer einen chunk-weisen Transfer vermutlich zu feingranular - eine groebere Spalte waehlen."
	}

	if ($chunkColumnAutoDetected)
	{
		# Die Schaetzung aus der Statistik gegen die jetzt bekannte Wirklichkeit halten. Weicht sie
		# deutlich ab, ist die Statistik veraltet - das ist keine Stoerung (der Lauf arbeitet mit den
		# echten Werten weiter), aber es erklaert, warum die GUI vorher eine andere Zahl angezeigt hat.
		$estimated = $usable[0].EstimatedDistinctValues
		if ($null -ne $estimated -and $estimated -gt 0)
		{
			$deviation = [math]::Abs($chunkValues.Count - $estimated) / [double]$estimated
			if ($deviation -gt 0.2)
			{
				$msg = "Chunk-Anzahl fuer [$ChunkColumn]: tatsaechlich $($chunkValues.Count), aus der Statistik geschaetzt waren $estimated - die Statistik ist vermutlich veraltet. Der Lauf verwendet die tatsaechlichen Werte."
				Write-Warning $msg
				Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'WARNING'
			}
		}
	}

	# Schluessel ist der per Format-SqlLiteral formatierte Wert (siehe Funktion oben) - derselbe Text
	# wird unten fuer jeden Chunk als Lookup-Key verwendet, unabhaengig vom .NET-Laufzeittyp.
	$srcCountByChunk = @{}
	foreach ($cr in $chunkRows) { $srcCountByChunk[(Format-SqlLiteral $cr.ChunkValue)] = [int64]$cr.Cnt }

	$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

	# --- Zieltabelle einmalig anlegen, falls sie noch nicht existiert - VOR Truncate/Disable,
	# die beide eine bereits existierende Zieltabelle voraussetzen. Vorher lag das (idempotent,
	# ueber Get-DbaDbTable) in jedem einzelnen Chunk-Aufruf - hier reicht einmal.
	if ($ScriptMetadata)
	{
		$dstExistsForCreate = @(Get-DbaDbTable @dstConnParams -Table $tableName -Schema $schemaName -ErrorAction SilentlyContinue).Count -gt 0
		if (-not $dstExistsForCreate)
		{
			$createAction = "Zieltabelle $qualified auf '$Destination'.'$DestinationDatabase' aus Quelle anlegen"
			if ($PSCmdlet.ShouldProcess($Destination, $createAction))
			{
				$schemaResults = Copy-sqmTableSchema -Source $Source -SourceDatabase $SourceDatabase `
													  -Destination $Destination -DestinationDatabase $DestinationDatabase `
													  -Table $Table -SourceCredential $srcCred -DestinationCredential $dstCred `
													  -IncludeForeignKeys $IncludeForeignKeys -IncludeIndexes $IncludeIndexes `
													  -EnableException:$EnableException -Confirm:$false
				$schemaFailCount = @($schemaResults | Where-Object Status -eq 'Failed').Count
				$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = '(alle)'; Step = 'ScriptMetadata'; Status = $(if ($schemaFailCount -gt 0) { 'Failed' } else { 'Success' }); Message = "$($schemaResults.Count) Objekt(e), $schemaFailCount fehlgeschlagen."; Timestamp = (Get-Date) })
				if ($schemaFailCount -gt 0 -and $EnableException)
				{
					throw "Anlegen von $qualified auf '$Destination'.'$DestinationDatabase' fehlgeschlagen."
				}
			}
		}
	}

	if ($Truncate)
	{
		# Nur leeren, wenn die Zieltabelle existiert (siehe ScriptMetadata-Block oben) - TRUNCATE
		# auf eine nicht existierende Tabelle wuerde sonst fehlschlagen.
		$dstExists = @(Get-DbaDbTable @dstConnParams -Table $tableName -Schema $schemaName -ErrorAction SilentlyContinue).Count -gt 0
		if ($dstExists)
		{
			$truncateAction = "Zieltabelle $qualified auf '$Destination'.'$DestinationDatabase' leeren (TRUNCATE)"
			if ($PSCmdlet.ShouldProcess($Destination, $truncateAction))
			{
				Invoke-DbaQuery @dstConnParams -Query "TRUNCATE TABLE $bracketed" -EnableException | Out-Null
				Write-sqmTransferLog -Message $truncateAction -FunctionName $functionName -Level 'INFO'
			}
		}
	}

	# --- FKs/Indizes/Trigger EINMAL fuer den gesamten Chunk-Lauf deaktivieren statt pro Chunk -
	# ein Index-REBUILD (Enable-sqmTableConstraints) ist unabhaengig vom WHERE-Filter immer eine
	# Ganztabellen-Operation; ihn pro Chunk zu wiederholen hat seine Kosten mit der Chunk-Anzahl
	# multipliziert, ohne jeden Nutzen - bei einer grossen Tabelle mit vielen Chunks dominierte
	# das den gesamten Lauf gegenueber der eigentlichen Datenkopie.
	$constraintsWereDisabled = $false
	if (-not $SkipConstraintHandling)
	{
		$disableAction = "FKs/Indizes/Trigger auf '$Destination'.'$DestinationDatabase'.$qualified deaktivieren (einmalig fuer den gesamten Chunk-Lauf)"
		if ($PSCmdlet.ShouldProcess($Destination, $disableAction))
		{
			$disableResults = Disable-sqmTableConstraints -SqlInstance $Destination -Database $DestinationDatabase `
														   -Table $Table -SqlCredential $dstCred `
														   -IncludeForeignKeys $IncludeForeignKeys -IncludeIndexes $IncludeIndexes `
														   -IncludeTriggers $IncludeTriggers -Confirm:$false
			$constraintsWereDisabled = $true
			$disableFailCount = @($disableResults | Where-Object Status -like 'Failed*').Count
			$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = '(alle)'; Step = 'DisableConstraints'; Status = $(if ($disableFailCount -gt 0) { 'Warning' } else { 'Success' }); Message = "$($disableResults.Count) Objekt(e), $disableFailCount fehlgeschlagen."; Timestamp = (Get-Date) })
		}
	}
	else
	{
		$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = '(alle)'; Step = 'DisableConstraints'; Status = 'Skipped'; Message = '-SkipConstraintHandling gesetzt.'; Timestamp = (Get-Date) })
	}

	# --- Ziel-Zeilenzahl pro Chunk EINMAL vorab per GROUP BY snapshotten statt pro Chunk live
	# abzufragen - Grundlage sowohl fuer den Skip-Check als auch fuer die Entscheidung, ob ein Chunk
	# Reste eines vorherigen Laufs hat (siehe unten). Nach -Truncate ist das Ziel per Definition leer,
	# eine frisch angelegte Zieltabelle (ScriptMetadata) ebenso - in beiden Faellen lohnt sich der
	# Scan nicht, jeder Chunk gilt dann als 0.
	$dstCountByChunk = @{}
	if (-not $Truncate)
	{
		$dstExistsForCount = @(Get-DbaDbTable @dstConnParams -Table $tableName -Schema $schemaName -ErrorAction SilentlyContinue).Count -gt 0
		if ($dstExistsForCount)
		{
			try
			{
				# -QueryTimeout: ohne diesen greift ADO.NETs Standard von 30s - auf einer sehr grossen
				# Tabelle mit bereits deaktivierten Non-Clustered-Indizes (siehe Disable-Block oben) ist
				# dieser GROUP BY-Scan je nach Clustered-Index-Abdeckung potenziell ein voller Scan, der
				# laenger als 30s dauern kann. Ein Timeout hier darf NICHT einfach als "Ziel ist leer"
				# behandelt werden (siehe catch unten) - genau das waere der gefaehrliche Default.
				$dstChunkQuery = "SELECT [$ChunkColumn] AS ChunkValue, COUNT_BIG(*) AS Cnt FROM $bracketed GROUP BY [$ChunkColumn]"
				$dstChunkRows = @(Invoke-DbaQuery @dstConnParams -Query $dstChunkQuery -As PSObject -EnableException -QueryTimeout 3600)
				foreach ($dr in $dstChunkRows) { $dstCountByChunk[(Format-SqlLiteral $dr.ChunkValue)] = [int64]$dr.Cnt }
			}
			catch
			{
				# NICHT still auf eine leere Hashtable zurueckfallen: das wuerde jeden Chunk unten wie
				# einen frischen, noch nie kopierten Chunk behandeln - auf einer Zieltabelle, die aus
				# einem vorherigen Lauf bereits echte Daten enthaelt, fuehrt das zum kompletten
				# Doppelt-Einfuegen JEDES Chunks statt nur der tatsaechlich fehlenden. Ohne verlaessliche
				# Kenntnis des Ziel-Zustands ist Abbruch die einzig sichere Reaktion.
				throw "Snapshot der Ziel-Zeilenzahl pro Chunk fuer $qualified auf '$Destination'.'$DestinationDatabase' fehlgeschlagen: $($_.Exception.Message) - Abbruch, um Doppelt-Kopieren bereits vorhandener Chunks zu verhindern. Ursache pruefen (Berechtigungen, Timeout, Spalte '$ChunkColumn' auf dem Ziel) und erneut versuchen."
			}
		}
	}

	$processedChunks = [System.Collections.Generic.List[PSCustomObject]]::new()

	$chunkIndex = 0
	$chunkTotal = $chunkValues.Count

	# --- Re-Enable/Rebuild ist per finally garantiert, auch wenn ein Chunk oder die Skip-Check-
	# Abfrage darunter eine Exception wirft - genau das gleiche Muster wie in Invoke-sqmTableTransfer.
	try
	{
		foreach ($chunkValue in $chunkValues)
		{
			$chunkIndex++
			$literal = Format-SqlLiteral $chunkValue
			$chunkLabel = "$ChunkColumn = $literal"

			Write-Progress -Id 3 -Activity "Chunked Transfer: $qualified" -Status "Chunk $chunkIndex von $chunkTotal ($chunkLabel)" `
							-PercentComplete ([math]::Floor((($chunkIndex - 1) / $chunkTotal) * 100))

			# --- Skip-Check aus dem Snapshot oben (kein Live-Query mehr) - macht einen erneuten Lauf
			# nach einem Abbruch resumable, ganz ohne Primary-/Unique-Key.
			$srcCount = $srcCountByChunk[$literal]
			$dstCount = $dstCountByChunk[$literal]
			if (-not $dstCount) { $dstCount = 0 }

			if ($null -ne $srcCount -and $srcCount -eq $dstCount)
			{
				Write-sqmTransferLog -Message "Chunk $chunkLabel bereits vollstaendig ($srcCount Zeile(n)) - uebersprungen." -FunctionName $functionName -Level 'INFO'
				$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = "$chunkValue"; Step = 'SkipCompletedChunk'; Status = 'Skipped'; Message = "$srcCount Zeile(n) bereits identisch."; Timestamp = (Get-Date) })
				continue
			}

			# --- Ein Chunk, der schon (falsche Anzahl) Zeilen auf dem Ziel hat, ist vermutlich der
			# Rest eines mitten im Bulk-Copy unterbrochenen vorherigen Laufs (SqlBulkCopy-Batches sind
			# atomar, aber der Chunk als Ganzes nicht). Ohne Primary/Unique Key auf der Zieltabelle
			# wuerde ein einfaches Neukopieren diese Zeilen verdoppeln statt sie zu ersetzen - darum
			# vor dem erneuten Kopieren geziehlt nur diesen einen Chunk leeren. Ein wirklich frischer,
			# noch nie kopierter Chunk hat $dstCount = 0 und braucht das nicht (bei deaktivierten
			# Indizes waere ein DELETE pro Chunk sonst ein teurer Full Scan on top jedes einzelnen
			# Chunks - hier greift es nur fuer den (typischerweise hoechstens einen) tatsaechlich
			# betroffenen Chunk).
			if ($null -ne $dstCount -and $dstCount -gt 0)
			{
				$cleanupAction = "Vorhandene $dstCount Zeile(n) fuer Chunk $chunkLabel auf '$Destination'.'$DestinationDatabase'.$qualified loeschen (Rest eines vorherigen Laufs) vor erneutem Kopieren"
				if ($PSCmdlet.ShouldProcess($Destination, $cleanupAction))
				{
					try
					{
						Invoke-DbaQuery @dstConnParams -Query "DELETE FROM $bracketed WHERE [$ChunkColumn] = $literal" -EnableException | Out-Null
						Write-sqmTransferLog -Message $cleanupAction -FunctionName $functionName -Level 'WARNING'
						$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = "$chunkValue"; Step = 'CleanPartialChunk'; Status = 'Success'; Message = "$dstCount Zeile(n) geloescht vor Neukopie."; Timestamp = (Get-Date) })
					}
					catch
					{
						$msg = "Konnte vorhandene Zeilen fuer Chunk $chunkLabel nicht loeschen: $($_.Exception.Message)"
						$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = "$chunkValue"; Step = 'CleanPartialChunk'; Status = 'Failed'; Message = $msg; Timestamp = (Get-Date) })
						Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
						if ($EnableException -and -not $ContinueOnError) { throw }
						continue
					}
				}
			}

			$chunkSql = "SELECT $columnList FROM $bracketed WHERE [$ChunkColumn] = $literal"
			$transferParams = @{
				Source				   = $Source
				SourceDatabase		   = $SourceDatabase
				Destination			   = $Destination
				DestinationDatabase    = $DestinationDatabase
				Table				   = $Table
				SourceQuery			   = $chunkSql
				SqlCredential		   = $SqlCredential
				SourceCredential	   = $srcCred
				DestinationCredential  = $dstCred
				# Tabelle anlegen und FKs/Indizes/Trigger deaktivieren passiert oben bereits einmal
				# fuer den gesamten Lauf, nicht mehr pro Chunk. Der eigene CompareRowCount-Schritt
				# von Invoke-sqmTableTransfer vergleicht immer die GANZE Tabelle, nicht nur diesen
				# Chunk - sein Ergebnis wird unten sowieso verworfen (Step -eq 'CompareRowCount'),
				# also lieber den vollen COUNT_BIG(*)-Scan (beidseitig) gar nicht erst ausfuehren.
				ScriptMetadata		   = $false
				SkipConstraintHandling = $true
				SkipRowCountCompare    = $true
				KeepIdentity		   = $KeepIdentity
				KeepNulls			   = $KeepNulls
				ContinueOnError		   = $true
				EnableException		   = $EnableException
				NoReport			   = $true
				Confirm				   = $false
				WhatIf				   = $WhatIfPreference
			}
			if ($BatchSize) { $transferParams['BatchSize'] = $BatchSize }

			$chunkResults = Invoke-sqmTableTransfer @transferParams
			foreach ($r in $chunkResults)
			{
				# Invoke-sqmTableTransfer's eigener CompareRowCount-Schritt vergleicht die GESAMTE Tabelle,
				# nicht den WHERE-gefilterten Chunk - fuer jeden Chunk ausser dem letzten sieht das
				# zwangslaeufig wie ein Mismatch aus, obwohl der Chunk selbst korrekt war. Wird unten durch
				# einen chunk-scoped Vergleich ersetzt.
				if ($r.Step -eq 'CompareRowCount') { continue }
				$allResults.Add([PSCustomObject]@{ Table = $r.Table; Chunk = "$chunkValue"; Step = $r.Step; Status = $r.Status; Message = $r.Message; Timestamp = $r.Timestamp })
			}

			# Der Nachvergleich fuer diesen Chunk wird NICHT hier live abgefragt (war vorher ein
			# zweiter COUNT_BIG(*)-Scan beidseitig pro Chunk) - stattdessen unten, nach dem letzten
			# Chunk, in einem einzigen GROUP BY-Scan fuer ALLE verarbeiteten Chunks auf einmal.
			$processedChunks.Add([PSCustomObject]@{ ChunkValue = $chunkValue; Literal = $literal })
		}

		# --- Ein einziger GROUP BY-Scan auf dem Ziel statt eines COUNT_BIG(*)-Scans PRO verarbeitetem
		# Chunk fuer den Nachvergleich - derselbe Kostengrund wie beim Skip-Check-Snapshot oben. Die
		# Quellzahlen liegen bereits im initialen Snapshot vor (die Quelle aendert sich waehrend des
		# Laufs nicht), nur das Ziel muss neu gelesen werden.
		if ($processedChunks.Count -gt 0)
		{
			$finalDstCountByChunk = @{}
			try
			{
				$finalDstChunkQuery = "SELECT [$ChunkColumn] AS ChunkValue, COUNT_BIG(*) AS Cnt FROM $bracketed GROUP BY [$ChunkColumn]"
				$finalDstChunkRows = @(Invoke-DbaQuery @dstConnParams -Query $finalDstChunkQuery -As PSObject -EnableException -QueryTimeout 3600)
				foreach ($dr in $finalDstChunkRows) { $finalDstCountByChunk[(Format-SqlLiteral $dr.ChunkValue)] = [int64]$dr.Cnt }

				foreach ($pc in $processedChunks)
				{
					$srcCountAfter = $srcCountByChunk[$pc.Literal]
					$dstCountAfter = $finalDstCountByChunk[$pc.Literal]
					if (-not $dstCountAfter) { $dstCountAfter = 0 }
					$chunkMatch = $srcCountAfter -eq $dstCountAfter
					$allResults.Add([PSCustomObject]@{
							Table = $qualified; Chunk = "$($pc.ChunkValue)"; Step = 'CompareRowCount'
							Status = $(if ($chunkMatch) { 'Success' } else { 'Mismatch' })
							Message = "Quelle=$srcCountAfter Ziel=$dstCountAfter Differenz=$($dstCountAfter - $srcCountAfter)"
							Timestamp = (Get-Date)
						})
				}
			}
			catch
			{
				foreach ($pc in $processedChunks)
				{
					$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = "$($pc.ChunkValue)"; Step = 'CompareRowCount'; Status = 'Failed'; Message = $_.Exception.Message; Timestamp = (Get-Date) })
				}
			}
		}
	}
	finally
	{
		Write-Progress -Id 3 -Activity "Chunked Transfer: $qualified" -Completed

		if ($constraintsWereDisabled)
		{
			try
			{
				$enableResults = Enable-sqmTableConstraints -SqlInstance $Destination -Database $DestinationDatabase `
															 -Table $Table -SqlCredential $dstCred -Revalidate $RevalidateForeignKeys `
															 -Confirm:$false
				$enableFailCount = @($enableResults | Where-Object Status -like 'Failed*').Count
				$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = '(alle)'; Step = 'EnableConstraints'; Status = $(if ($enableFailCount -gt 0) { 'Warning' } else { 'Success' }); Message = "$($enableResults.Count) Objekt(e), $enableFailCount fehlgeschlagen."; Timestamp = (Get-Date) })
			}
			catch
			{
				# Nicht weiterwerfen - eine urspruengliche Ausnahme aus dem Chunk-Lauf darf nicht verdeckt werden.
				$msg = "Re-Enable von FKs/Indizes/Triggern auf $qualified fehlgeschlagen: $($_.Exception.Message) - manuell pruefen!"
				Write-Warning $msg
				Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
				$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = '(alle)'; Step = 'EnableConstraints'; Status = 'Failed'; Message = $msg; Timestamp = (Get-Date) })
			}
		}
	}

	$skippedChunks = @($allResults | Where-Object Step -eq 'SkipCompletedChunk').Count
	$failCount = @($allResults | Where-Object Status -in @('Failed', 'Mismatch', 'NotFound')).Count
	$summaryMsg = "Invoke-sqmChunkedTableTransfer abgeschlossen fuer $qualified - $chunkTotal Chunk(s), $skippedChunks bereits vollstaendig uebersprungen, $failCount mit Fehler/Mismatch/NotFound."
	Write-sqmTransferLog -Message $summaryMsg -FunctionName $functionName -Level 'INFO'
	Write-Host $summaryMsg -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' } else { 'Green' })

	if (-not $NoReport)
	{
		try
		{
			# -Fast: der Lauf ist an dieser Stelle fertig (alle Chunks abgearbeitet), also kein Risiko
			# eines "dirty reads" auf eine noch laufende Bulk-Copy - sys.dm_db_partition_stats statt
			# COUNT_BIG(*) spart bei einer 300+ Mio. Zeilen Tabelle einen kompletten Scan.
			$finalCompare = Compare-sqmTableRowCount -Source $Source -SourceDatabase $SourceDatabase `
													   -Destination $Destination -DestinationDatabase $DestinationDatabase `
													   -Table $Table -SourceCredential $srcCred -DestinationCredential $dstCred -Fast

			if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
			$safeSource = "$Source.$SourceDatabase" -replace '[\\:.]', '_'
			$safeDest = "$Destination.$DestinationDatabase" -replace '[\\:.]', '_'
			$datestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
			$htmlFile = Join-Path $OutputPath "sqmDataTransfer_ChunkedTransferReport_${safeSource}_to_${safeDest}_${datestamp}.html"

			Export-sqmTransferReport -Source $Source -SourceDatabase $SourceDatabase `
									  -Destination $Destination -DestinationDatabase $DestinationDatabase `
									  -Results $allResults -RowCounts $finalCompare -FilePath $htmlFile `
									  -Title "sqmDataTransfer - Chunked Transferbericht ($qualified)" -NoOpen:$NoOpen
		}
		catch
		{
			Write-Warning (Get-sqmTransferString -Key 'InvokeTransfer.ReportFailed' -FormatArgs @($_.Exception.Message))
			Write-sqmTransferLog -Message (Get-sqmTransferString -Key 'InvokeTransfer.ReportFailed' -FormatArgs @($_.Exception.Message)) -FunctionName $functionName -Level 'ERROR'
		}
	}

	return $allResults
}
