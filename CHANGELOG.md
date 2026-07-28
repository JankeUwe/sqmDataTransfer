# sqmDataTransfer — Changelog

## [0.1.18.0] — 2026-07-28

### Chunk-Spalte und Chunk-Anzahl werden automatisch ermittelt

`Invoke-sqmChunkedTableTransfer` verlangte bisher zwingend `-ChunkColumn` und brach an einem festen
`-MaxChunkValues` von 500 ab. Beides musste man vorher wissen: welche Spalte sich zum Aufteilen
eignet, und wie viele unterschiedliche Werte sie hat. Eine an sich passende Spalte mit z.B. 800
Monatswerten liess den Lauf scheitern und erzwang einen zweiten Anlauf mit der richtigen Zahl,
obwohl die Anzahl aus dem `GROUP BY`, das die Funktion ohnehin ausfuehrt, langst bekannt war.

Beide Parameter sind jetzt optional:

- **`-ChunkColumn`** wird ueber die neue Funktion **`Get-sqmChunkColumnCandidate`** bestimmt. Sie
  bewertet Datums- und Perioden-Spalten nach Namenskonvention (Stichtag, ReportingDate, `Dat_`/`dtm`
  zuerst) und schaetzt fuer jede die Anzahl der Chunks aus dem Statistik-Histogramm der Spalte
  (`sys.dm_db_stats_histogram`). Das ist eine reine Metadatenlektuere: auf einer Tabelle mit 344
  Millionen Zeilen kostet sie dasselbe wie auf einer leeren, weshalb sie auch aus der GUI heraus
  unbedenklich ist. Die gewaehlte Spalte, die geschaetzte Chunk-Anzahl und die Begruendung stehen im
  Log; findet sich keine geeignete Spalte, bricht der Lauf ab und nennt, was er verworfen hat und
  warum, statt zu raten. Weicht die Schaetzung spaeter um mehr als 20% von der tatsaechlichen Zahl
  ab, weist eine Warnung auf die veraltete Statistik hin, der Lauf rechnet mit den echten Werten.
- **`-MaxChunkValues`** nutzt ohne expliziten Wert die neue Konfigurationsgrenze
  `MaxChunkValueCeiling` (Default 2000, ueber `Set-sqmTransferConfig` aenderbar). Die tatsaechlich
  gefundene Anzahl wird bis zu dieser Grenze akzeptiert; darueber ist die Spalte wirklich zu
  feingranular und der Abbruch nennt den Wert, mit dem sich das ueberstimmen liesse.

`Get-sqmChunkColumnCandidate` kennt zusaetzlich `-Exact` fuer ein echtes
`COUNT_BIG(DISTINCT ...)` je Kandidat. Das ist ein Vollscan der Spalte und nur dann sinnvoll, wenn
die Schaetzung nahe an der Grenze liegt und die Entscheidung tatsaechlich davon abhaengt.

### GUI bietet normalen Transfer und Chunk-Transfer zur Auswahl an

Bisher konnte die GUI ausschliesslich den normalen All-or-nothing-Copy und hat bei einer sehr
grossen Tabelle lediglich den passenden `Invoke-sqmChunkedTableTransfer`-Befehl zum Kopieren
angeboten - ausfuehren musste man ihn in PowerShell. Die neue Gruppe "Transfermodus" bietet:

- **Automatisch** (Vorgabe): entscheidet je Tabelle nach genau der Regel, nach der vorher nur die
  Empfehlung ausgesprochen wurde (ueber `LargeTableRowThreshold` **und** Ziel bereits zu mindestens
  `ChunkAdviceMinExistingPercent` befuellt), und zusaetzlich nur dann, wenn es fuer die Tabelle
  ueberhaupt eine brauchbare Chunk-Spalte gibt. Alle uebrigen Tabellen laufen normal.
- **Normal**: unveraendertes bisheriges Verhalten inklusive Hinweisdialog mit fertigem Befehl.
- **Chunk-Transfer**: alle ausgewaehlten Tabellen laufen chunk-weise, eine Runde je Tabelle.

Dazu ein Feld fuer die Chunk-Spalte mit Schaltflaeche "Erkennen". Leer bedeutet automatische
Erkennung je Tabelle; eine feste Spalte wird nur uebernommen, wenn genau eine Tabelle ausgewaehlt
ist, da ein Spaltenname sonst nicht zwangslaeufig auf jede ausgewaehlte Tabelle passt.

### Fix: der GUI-Titel zeigte dauerhaft "v0.1.0.0"

Die Modulversion wurde beim Laden per `Import-PowerShellDataFile` aus dem Manifest gelesen. Unter
Windows PowerShell 5.1 ist das kein Cmdlet, sondern eine Funktion aus
`Microsoft.PowerShell.Utility`, und die ist im Modulscope waehrend des Modulladens nicht
zuverlaessig aufloesbar - je nach Startkontext des Prozesses (reproduzierbar ueber `Start-Process`,
nicht bei direktem Aufruf) scheiterte der Aufruf mit `CommandNotFoundException`. Ein leeres `catch`
verschluckte das vollstaendig, und die Version blieb still auf dem Platzhalter `0.1.0.0` stehen -
sichtbar nur im Fenstertitel. Der Fehler wird jetzt nicht mehr verschluckt, und wenn der Befehl
fehlt, liest ein zweiter Weg das Manifest ueber
`[System.Management.Automation.Language.Parser]`, einen .NET-Typ, der keine Befehlsaufloesung
braucht und deshalb in jedem Ladezustand funktioniert.

### Fix: gemischte Ergebnisse konnten das Ergebnis-Grid zum Absturz bringen

`ConvertTo-DataTable` in der GUI leitete die Spalten ausschliesslich aus dem ersten Ergebnisobjekt
ab. Sobald ein Lauf Chunk- und Normal-Ergebnisse mischt - was mit dem Automatik-Modus zum Normalfall
wird - hat die erste Zeile mit einer bis dahin unbekannten Eigenschaft beim Schreiben eine
Ausnahme geworfen. Spalten werden jetzt fortlaufend ergaenzt.

## [0.1.17.2] — 2026-07-28

### Fix: fehlendes UTF-8-BOM verstuemmelte den Umlaut im HTML-Report

Keine der 21 Quelldateien hatte ein UTF-8-BOM. Windows PowerShell 5.1 — die Zielplattform laut
Manifest — interpretiert eine BOM-lose Datei als cp1252, nicht als UTF-8. In
`Export-sqmTransferReport` und `Export-sqmDatabaseComparisonReport` steht je ein Umlaut in der
Kopfzeile des erzeugten Berichts, der dadurch als `Zeilen gesamt Ã¼bertragen` im fertigen HTML
landete. Unter PowerShell 7 war nichts zu sehen, weil dessen Default ohnehin UTF-8 ist. Alle
Dateien tragen jetzt ein BOM, und der Pre-Push-Hook prueft das ab sofort.

### Neu: Pre-Push-Hook und Tools/Test-DuplicateParameterBinding.ps1

Das Modul hatte bisher als einziges der drei PowerShell-Module weder Hook noch CI, obwohl es die
bisher heikelsten Fehler hatte. Der neue Hook prueft vor jedem Push unter Windows PowerShell 5.1
**und** PowerShell 7: Parse aller Dateien in `Public` und `Private` (nicht nur einer
Stichprobe), Modul-Import, Export der Kommandos, UTF-8-BOM sowie doppelte Parameterbindungen.
Letzteres ist der Fehler aus 0.1.17.1, den kein Import-Test finden kann, weil er erst zur
Aufrufzeit auftritt.

## [0.1.17.1] — 2026-07-28

### Fix: "parameter 'ErrorAction' is specified more than once" crash under Windows PowerShell 5.1

`Invoke-sqmChunkedTableTransfer`'s destination existence/pre-count checks (`Get-DbaDbTable @dstConnParams
-Table ... -ErrorAction SilentlyContinue`) splatted `$dstConnParams`, which already carried
`ErrorAction = 'Stop'`, alongside an explicit `-ErrorAction SilentlyContinue` - a duplicate common
parameter. This went undetected through all of 0.1.14.0-0.1.17.0's testing because that testing ran
under PowerShell 7, which tolerates the duplicate; the module targets and is actually deployed on
Windows PowerShell 5.1 (`PowerShellVersion = '5.1'` in the manifest), whose parameter binder rejects
it outright - reproduced directly under real `powershell.exe` 5.1: `ParameterBindingException:
ParameterAlreadyBound`. Hit on every normal (non-`-Truncate`) resume of an existing destination,
i.e. the common case. Fixed by dropping the redundant `ErrorAction = 'Stop'` from the connection
params hashtable entirely - every `Invoke-DbaQuery` call in the function already passes
`-EnableException`, which fully overrides `-ErrorAction` in dbatools, so nothing relied on it.
Re-verified the full chunked-transfer test suite (fresh copy, resume/skip, partial-chunk recovery)
under actual Windows PowerShell 5.1 this time, not just PowerShell 7.

## [0.1.17.0] — 2026-07-27

### Chunking advice now only fires when it would actually help

A plain transfer of a large table is always faster than chunking it (no per-chunk overhead) -
chunking's whole benefit is resumability (skipping already-complete chunks), which only matters
when the destination already holds a meaningful chunk of the data. The large-table warning (both
`Invoke-sqmTableTransfer` and the GUI's pre-run check) now only suggests
`Invoke-sqmChunkedTableTransfer` once the destination already contains at least
`ChunkAdviceMinExistingPercent` (default 30%) of the source's rows - metadata lookup, no scan, same
cost as before. A fresh/empty destination gets no chunking nag and just runs the fast plain copy.
Configurable via `Set-sqmTransferConfig -ChunkAdviceMinExistingPercent`.

### GUI: window title now shows version and powershelldba.de, plus an About box

Matches the existing `sqmSQLTool`/`SQL-Migration` convention (`{Tool} v{Version} | powershelldba.de
- Janke (c) {yearSpan}`). Added an "Ueber"/"About" button next to Run/Close that opens a small
dialog with the module name, version, description, copyright and a clickable link to
www.powershelldba.de.

## [0.1.16.0] — 2026-07-27

### Fix: silent destination row-count snapshot failure could have caused full-table duplicate copy

Found while investigating a real 500M-row chunked transfer where no `COUNT_BIG`/`GROUP BY` query
was visible against the destination via `sp_WhoIsActive`. Root cause: the 0.1.14.0 destination
per-chunk snapshot (`GROUP BY [ChunkColumn]`) had no `-QueryTimeout`, so it inherited ADO.NET's
30-second default - on a large table with non-clustered indexes already disabled for the run, this
scan can easily exceed 30 seconds and time out. On failure, the code silently fell back to an
*empty* hashtable, which makes every chunk look like "never copied" (`dstCount = 0`) - on a
destination table that already holds real data from a prior run, that would have caused every
already-complete chunk to be copied again on top of the existing rows, doubling the table, with no
error or warning anywhere.

Fixed two ways: (1) the snapshot queries (source, destination pre-loop, destination post-loop) now
carry an explicit `-QueryTimeout 3600` instead of relying on the ADO.NET default; (2) a failed
destination snapshot now throws immediately, aborting the run before any chunk is touched, instead
of silently defaulting to "target is empty." Verified: in the reported case the destination was
170k rows *short* of the source (not over), which itself confirms no duplication had occurred -
but the silent-failure path was real and has been closed for future runs. Also verified against a
forced destination schema mismatch: the run now aborts cleanly with zero rows touched instead of
proceeding on a bad assumption.

## [0.1.15.0] — 2026-07-27

### Progress feedback went silent for chunk-sized copies after the 0.1.14.0 BatchSize bump

`Copy-sqmTableData`'s `-NotifyAfter` (how often the live `Write-Progress` row-count ticks during a
copy) defaulted to whatever `-BatchSize` was. Raising the default `BatchSize` to 500,000 in
0.1.14.0 meant a single chunk from `Invoke-sqmChunkedTableTransfer` - normally far smaller than
500k rows - never crossed that threshold, so the `SqlRowsCopied` notification never fired at all
during the chunk's copy. The data itself was never affected (verified: a 90,000-row test copy
landed all 90,000 rows correctly either way) - only the live feedback went quiet, making a chunk
that was actually copying correctly look like nothing was happening until it finished. `NotifyAfter`
now defaults to the smaller of `-BatchSize` and 25,000, decoupling progress granularity from the
batch commit size.

## [0.1.14.0] — 2026-07-27

### Chunked transfer: row-count checks were the dominant cost, not the data copy

Real-world testing on a large table surfaced that `Invoke-sqmChunkedTableTransfer` spent most of
its time on row counting, not copying data. Each chunk ran up to four live `COUNT_BIG(*) WHERE
[ChunkColumn] = value` scans (skip-check before the copy: source+destination, verification after:
source+destination) - all without index support, since indexes are disabled for the whole run. On
a table with hundreds of chunks this made the row-count part dominate the entire run.

Replaced all of that with three snapshots taken once, not per chunk: the source's per-chunk counts
come free from the same `GROUP BY` query that already replaced the old `DISTINCT` chunk-value
lookup; the destination's per-chunk counts are snapshotted once before the loop (skipped entirely
after `-Truncate` or when the destination doesn't exist yet); and the post-copy verification is one
more destination `GROUP BY` scan after the last chunk, compared in-memory against the source
snapshot. Skip-checks and cleanup-needed decisions during the loop are now pure hashtable lookups -
no per-chunk query at all.

### Default BatchSize raised from 200,000 to 500,000 rows

Further real-world testing found 500k rows/batch faster than 200k on large chunked transfers -
fewer round-trips per row without the memory/log pressure of going even larger. Applied
consistently everywhere the default is read (module config, every function's fallback, the GUI's
initial batch-size field).

### Enable-sqmTableConstraints now logs before each REBUILD/CHECK, not just after

A disabled non-clustered index REBUILD (or an FK re-enable with `-Revalidate`, i.e. `WITH CHECK`)
on a very large table can legitimately take a long time. Previously the log only gained an entry
once each statement finished, so a run that was still working looked identical to a genuine hang -
there was no way to tell from the log which object was in progress or since when. Added a "Start:"
log line immediately before each `ALTER INDEX ... REBUILD` / `... CHECK CONSTRAINT` statement.

## [0.1.13.0] — 2026-07-26

### Copyable large-table dialog instead of a MessageBox

The large-table warning dialog (0.1.12.0) used a plain `MessageBox.Show()`. `Ctrl+C` copies the
whole dialog text - intro sentence, every flagged table, the yes/no question - not just the
command to paste into PowerShell, which got unwieldy with multiple large tables flagged at once.
Replaced it with a small dialog that has a read-only textbox for context plus an explicit "Copy to
clipboard" button that copies only the clean command lines.

## [0.1.12.0] — 2026-07-26

### Large-table warning with a ready-to-use chunked-transfer command

A plain `Invoke-sqmTableTransfer` call on a huge table used to silently do an all-or-nothing
copy, with no hint that `Invoke-sqmChunkedTableTransfer` exists or would help. It now checks the
source row count (metadata lookup, no scan) against a configurable threshold (`Set-sqmTransferConfig
-LargeTableRowThreshold`, default 10,000,000) and, if exceeded, warns with a ready-to-paste
`Invoke-sqmChunkedTableTransfer` command — including a suggested `-ChunkColumn`, picked from the
table's date-typed columns by naming convention (`Stichtag`, `ReportingDate`, `Dat_`/`dtm`
prefixes). The GUI runs the same check *before* starting a transfer, not after, so an oversized
table can be caught and cancelled in time.

## [0.1.11.0] — 2026-07-26

### Default BatchSize raised from 50,000 to 200,000 rows

Fewer round-trips on large tables. Applied consistently everywhere the default is read: the
module's central config, every function's fallback, and the GUI's initial batch-size field.

## [0.1.10.0] — 2026-07-26

### Table grid's row-count click no longer scans

Ticking a table's checkbox in the GUI grid to fetch its row count ran a full `COUNT_BIG(*)` on
the UI thread — checking a huge table alone could freeze the window for as long as the scan took.
Switched to the same `sys.dm_db_partition_stats` metadata lookup used elsewhere.

## [0.1.9.0] — 2026-07-26

### GUI's "Overall report" exact verification made opt-in

The button always ran `Compare-sqmDatabaseRowCount -VerifyMismatches` unconditionally — a real
`COUNT_BIG(*)` scan for any mismatched table, synchronously freezing the whole window for however
long that took. Added a checkbox (unchecked by default) so the fast metadata-only comparison is
the default, with exact verification available on demand for a final customer-facing report.

## [0.1.8.0] — 2026-07-26

### Removed a redundant full-table scan on every chunk

`Invoke-sqmTableTransfer`'s own post-copy row-count compare ran unconditionally after every
chunk, even though `Invoke-sqmChunkedTableTransfer` always discarded that specific (whole-table,
not chunk-scoped) result and replaced it with its own. Added `-SkipRowCountCompare` and wired it
into every per-chunk call — one less pair of full-table `COUNT_BIG(*)` scans per chunk.

## [0.1.7.0] — 2026-07-26

### Fast final row-count comparison for chunked transfers

The consolidated end-of-run comparison in `Invoke-sqmChunkedTableTransfer` used
`SELECT COUNT_BIG(*)` on both sides — a full scan, minutes on a very large table. Added a `-Fast`
switch to `Compare-sqmTableRowCount` that reads `SUM(row_count)` from
`sys.dm_db_partition_stats` instead (exact, transactionally maintained, no scan), used only for
this end-of-run check where nothing is still actively writing to the table.

## [0.1.6.0] — 2026-07-25

### Fixed duplicate rows on a chunk interrupted mid-copy

Chunked tables have no primary/unique key, so resumability works by comparing per-chunk row
counts. That covers a clean stop *between* chunks, but a chunk killed mid-`SqlBulkCopy` (network
blip, killed session) left partially-committed rows behind — retrying just re-ran the whole
chunk's `SELECT`, doubling those leftover rows. Added a targeted `DELETE` for a chunk's existing
rows before any retry where the destination already has a nonzero, mismatched count.

## [0.1.5.0] — 2026-07-25

### Indexes disabled and rebuilt once per chunked transfer, not once per chunk

`Invoke-sqmChunkedTableTransfer` called `Invoke-sqmTableTransfer` once per chunk, and that
function disables/rebuilds indexes around every call — so a table split into hundreds of chunks
rebuilt every index hundreds of times. Moved table creation and constraint disable/rebuild to run
once around the whole chunk loop instead, guaranteed via a `finally` block.

## [0.1.4.0] — 2026-07-25

### Column mapping made independent of the installed dbatools version

The previous fix relied on dbatools' `-ForceExplicitMapping` parameter, which doesn't exist in
every dbatools version still in production use (present since 2.8.x, absent in 2.7.1). Added
`Invoke-sqmDirectBulkCopy`, which drives `Microsoft.Data.SqlClient.SqlBulkCopy` directly with
explicit name-based column mappings — no dependency on dbatools' internal `-Query` handling at
all.

## [0.1.3.0] — 2026-07-25

### Fixed the actual root cause of the column-mapping corruption

Traced a chunked-transfer data-corruption bug (columns landing in the wrong destination columns)
to dbatools' `Copy-DbaDbTableData -Query` mode: without `-ForceExplicitMapping`, it leaves
`SqlBulkCopy.ColumnMappings` empty and falls back to implicit ordinal mapping against the
destination's full physical column list — which counts computed columns even though nothing can
be written to them. A computed column anywhere before the end of the table silently shifted every
later column's mapping by one position. Reproduced against a real 108-column production table
with a computed column at position 3.

## [0.1.2.0] — 2026-07-25

### Fixed remaining-column ordinal shift

A prior fix removed destination-only columns from the `SELECT` list to match column order, but
removing (rather than replacing) a column still shifted every later column's ordinal position.
Replaced removed columns with typed `CAST(NULL AS ...)` placeholders instead.

## [0.1.1.0] — 2026-07-25

### Chunked transfer for large tables without a primary key

Added `Invoke-sqmChunkedTableTransfer`: splits a table by a discriminating column (e.g. a
reporting/snapshot date) and transfers it one distinct value at a time, with a per-chunk
row-count skip-check that makes a re-run after a partial failure resume from where it left off —
without needing a primary/unique key. Also in this release: trigger disable/enable added to the
constraint-handling pipeline (alongside foreign keys and indexes), a consolidated
database-wide comparison report (`Compare-sqmDatabaseRowCount` / `Export-sqmDatabaseComparisonReport`),
and a fix for a `GetNewClosure()` scoping bug that broke the GUI's Connect button under a real
mouse click.

## [0.1.0.0] — 2026-07-17 to 2026-07-21

### Initial release

Table data transfer between SQL Server instances built on dbatools: metadata scripting with
dependency resolution (types, sequences, FK-referenced tables), partitioned-table handling
(partitioning stripped with a warning rather than failing), safe foreign-key/index disable and
guaranteed re-enable around the copy, row-count reconciliation, full HTML reporting, and a
WinForms GUI. `-SkipCompleted` added to resume an interrupted multi-table run by re-deriving
completeness from actual row counts. `Sync-sqmTableData` added for incremental
insert/update/delete sync via a staging table. Bilingual (DE/EN) GUI text and log messages.
