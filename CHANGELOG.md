# sqmDataTransfer — Changelog

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
