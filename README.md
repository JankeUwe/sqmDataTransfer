# sqmDataTransfer

Part of the [powershelldba.de](https://www.powershelldba.de) SQL Server toolset by [Uwe Janke](https://www.powershelldba.de) — project page: [powershelldba.de/sqmtransfer](https://www.powershelldba.de/sqmtransfer/)

PowerShell module (built on [dbatools](https://dbatools.io)) that transfers table data between
SQL Server instances, with optional metadata scripting, safe foreign-key/index handling around
the transfer, row-count reconciliation and full logging.

## What it does

For a chosen set of tables, `Invoke-sqmTableTransfer` runs:

1. **Script metadata** (optional, `-ScriptMetadata`): scripts the table DDL (columns, PK,
   indexes, foreign keys, defaults, checks) from the source and creates it on the target if it
   doesn't already exist there. Existing target tables are never dropped/recreated. This also
   handles what would otherwise silently break the CREATE on the target:
     - The destination **schema** is created automatically if missing.
     - **User-defined types, sequences and FK-referenced tables** the table depends on are scripted
       automatically too (SMO `WithDependencies`, walks the real dependency graph).
     - **Partitioned tables** are still fully scripted and transferred - but the physical
       partitioning itself (partition function/scheme, per-partition filegroups) is stripped from
       the script (SMO `NoTablePartitioningSchemes`/`NoIndexPartitioningSchemes`), since this
       function has no way to know whether an equivalent scheme exists on the target. The table
       and its indexes land as normal, non-partitioned objects on the default filegroup (PRIMARY)
       instead of failing with a missing-partition-scheme error. Reported as a warning.
     - **CLR user-defined types** are scripted but flagged as a warning: the assembly itself has to
       be deployed on the target manually.
     - The destination's **actual SQL Server version** is auto-detected and passed to SMO as
       `TargetServerVersion`, so scripting from a newer source (e.g. 2022) down to an older target
       (e.g. 2019) produces syntax the target can run, instead of source-native syntax.
2. **Disable** foreign keys and non-clustered indexes on the target table.
3. **Copy data** from source to target (`Copy-DbaDbTableData` under the hood).
4. **Compare row counts** between source and target.
5. **Re-enable** foreign keys and indexes on the target - guaranteed via a `finally` block, even
   if an earlier step fails.

Every step is logged to `%LogPath%\sqmDataTransfer_yyyyMMdd_<FunctionName>.log` and returned as a
structured result object (`Table`, `Step`, `Status`, `Message`, `Timestamp`).

A self-contained HTML report is **always** written at the end of the run (same convention as
sqmSQLTool's report-generating functions) - every processed table plus any that are missing/failed,
and a source-vs-destination row-count comparison (tables that couldn't be compared, e.g. because
the copy itself failed, are shown as "nicht verglichen" rather than being silently omitted). It is
written to `-OutputPath` (defaults to `Get-sqmTransferConfig -Key 'OutputPath'`, i.e. the same
`C:\System\WinSrvLog\MSSQL` location sqmSQLTool uses) and opens automatically in the browser unless
`-NoOpen` is passed. That report is only written once the run finishes normally, though - if a large
run is killed mid-way (crashed session, box rebooted overnight, etc.) there is no report for it.

### Resuming an interrupted run

Pass `-SkipCompleted` to re-run the same (or a superset) `-Table` list after an interrupted run.
Before touching anything, it runs `Compare-sqmTableRowCount` against every requested table; any
table where source and target row counts already match is skipped (logged as step
`SkipCompleted`/`Skipped` and included in the HTML report) and only the remaining tables actually
get processed. No separate bookkeeping of "which tables finished" is needed - completeness is
re-derived from the actual data each time:

```powershell
Invoke-sqmTableTransfer -Source SQL01 -SourceDatabase Sales `
    -Destination SQL02 -DestinationDatabase Sales `
    -Table $all220Tables `
    -ScriptMetadata -SkipCompleted -Confirm:$false
```

## Functions

| Function | Purpose |
|---|---|
| `Invoke-sqmTableTransfer` | Main entry point - orchestrates the full sequence above. |
| `Export-sqmTableSchema` | Scripts table DDL from a source instance (SMO Scripter). |
| `New-sqmTableFromScript` | Executes scripted DDL batches against a target instance. |
| `Copy-sqmTableSchema` | Convenience wrapper: export + create in one call. |
| `Disable-sqmTableConstraints` | Disables FKs / non-clustered indexes on a table. |
| `Enable-sqmTableConstraints` | Re-enables (rebuilds) previously disabled FKs / indexes. |
| `Copy-sqmTableData` | Bulk-copies table data (wraps `Copy-DbaDbTableData`). |
| `Compare-sqmTableRowCount` | Compares row counts source vs. target. |
| `Export-sqmTransferReport` | Builds the HTML summary/row-count report. |
| `Show-sqmTableTransferGui` | WinForms GUI for the whole workflow. |
| `Get-sqmTransferConfig` / `Set-sqmTransferConfig` | Module configuration (log path, batch size, etc.). |

## Installation

```
Install.cmd                  -> auto-detect: AllUsers if Admin, CurrentUser otherwise
Install.cmd AllUsers         -> installs system-wide (auto-elevates via UAC if needed)
Install.cmd CurrentUser      -> installs for current user only (no elevation needed)
```

Copies the module into the PowerShell module path (robocopy + Unblock-File), ensures the
`dbatools` dependency in the same scope, and runs an import test. Same convention as
`sqmSQLTool`/`sqmPartitionTool`'s installers. Without installing, the module can also be imported
directly from this folder for development:

```powershell
Import-Module .\sqmDataTransfer.psd1
```

## Quick start

```powershell
Invoke-sqmTableTransfer -Source SQL01 -SourceDatabase Sales `
    -Destination SQL02 -DestinationDatabase Sales `
    -Table 'dbo.Orders', 'dbo.Customers' `
    -ScriptMetadata -Truncate -Confirm:$false
```

Or via GUI:

```powershell
Show-sqmTableTransferGui
```

## Notes

- Clustered indexes are never disabled (doing so blocks table access entirely) - only
  non-clustered indexes are disabled/rebuilt.
- Foreign keys are disabled/enabled individually by name, leaving CHECK/DEFAULT constraints
  untouched.
- `Enable-sqmTableConstraints` re-detects currently disabled objects on the table - no state
  needs to be passed in from a prior `Disable-sqmTableConstraints` call.
- Configuration is persisted separately from `sqmSQLTool` (`%APPDATA%\SQLDataTransfer\config.json`)
  so both modules can be imported side by side without interfering, but `LogPath`/`OutputPath`
  default to the same location sqmSQLTool uses (`C:\System\WinSrvLog\MSSQL`).
