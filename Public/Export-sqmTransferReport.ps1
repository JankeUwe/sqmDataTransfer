<#
.SYNOPSIS
    Builds a self-contained HTML report for a table transfer run: which tables were processed
    (and any that are missing/failed), plus a source-vs-destination row-count comparison.

.DESCRIPTION
    Consumes the structured output of Invoke-sqmTableTransfer (-Results, the per-table/per-step
    log) and, if available, the row-count comparison objects (-RowCounts, as returned by
    Compare-sqmTableRowCount). Produces one HTML file with:

        - A summary header (source/destination, generated timestamp, table counts).
        - "Fehlende / fehlgeschlagene Tabellen": every table that has at least one step with a
          Failed/NotFound/Mismatch status, with the offending step and message. Empty if
          everything succeeded.
        - "Zeilenvergleich": one row per table with source rows, destination rows, difference and
          a match/mismatch/"not compared" badge. Tables for which no row-count comparison was run
          (e.g. because the data copy itself failed) are listed as "nicht verglichen" rather than
          silently omitted - so a table that is actually missing data is never just absent from
          the report.

    Called automatically by Invoke-sqmTableTransfer when -HtmlReportPath is specified, but can
    also be used standalone against any previously captured result set.

.PARAMETER Source
    Source SQL Server instance (for the report header only).

.PARAMETER SourceDatabase
    Source database name (for the report header only).

.PARAMETER Destination
    Target SQL Server instance (for the report header only).

.PARAMETER DestinationDatabase
    Target database name (for the report header only).

.PARAMETER Results
    Step-result objects as returned by Invoke-sqmTableTransfer (Table/Step/Status/Message/Timestamp).

.PARAMETER RowCounts
    Row-count comparison objects as returned by Compare-sqmTableRowCount
    (Table/DestinationTable/SourceRows/DestinationRows/Difference/Match/Message). Optional -
    tables without a corresponding entry are reported as "nicht verglichen".

.PARAMETER FilePath
    Path to write the HTML report to.

.PARAMETER Title
    Report heading. Default: 'sqmDataTransfer - Transferbericht'.

.PARAMETER PassThru
    Also return the generated HTML as a string.

.EXAMPLE
    $r = Invoke-sqmTableTransfer -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -Table Orders,Customers -ScriptMetadata
    Export-sqmTransferReport -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -Results $r -FilePath C:\Temp\TransferReport.html

.NOTES
    Prerequisites: none beyond the module itself - pure string/HTML generation.
#>
function Export-sqmTransferReport
{
	[CmdletBinding()]
	[OutputType([void], [string])]
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
		[AllowEmptyCollection()]
		[PSCustomObject[]]$Results,
		[Parameter(Mandatory = $false)]
		[AllowEmptyCollection()]
		[PSCustomObject[]]$RowCounts = @(),
		[Parameter(Mandatory = $true)]
		[string]$FilePath,
		[Parameter(Mandatory = $false)]
		[string]$Title = 'sqmDataTransfer - Transferbericht',
		[Parameter(Mandatory = $false)]
		[switch]$PassThru
	)

	function Escape-Html([string]$s)
	{
		if ($null -eq $s) { return '' }
		[System.Net.WebUtility]::HtmlEncode($s)
	}

	$allTables = @(
		@($Results | Select-Object -ExpandProperty Table -ErrorAction SilentlyContinue) +
		@($RowCounts | Select-Object -ExpandProperty Table -ErrorAction SilentlyContinue) |
		Where-Object { $_ } | Select-Object -Unique | Sort-Object
	)

	$problemStatuses = @('Failed', 'NotFound', 'Mismatch')
	$tableProblems = @{ }
	foreach ($t in $allTables)
	{
		$steps = @($Results | Where-Object { $_.Table -eq $t -and ($_.Status -like 'Failed*' -or $_.Status -in $problemStatuses) })
		if ($steps.Count -gt 0) { $tableProblems[$t] = $steps }
	}

	$rowCountByTable = @{ }
	foreach ($rc in $RowCounts)
	{
		if ($rc.Table -and -not $rowCountByTable.ContainsKey($rc.Table)) { $rowCountByTable[$rc.Table] = $rc }
	}

	$totalTables = $allTables.Count
	$problemTableCount = $tableProblems.Keys.Count
	$matchCount = @($allTables | Where-Object { $rowCountByTable.ContainsKey($_) -and $rowCountByTable[$_].Match -and -not $rowCountByTable[$_].Message }).Count
	$mismatchCount = @($allTables | Where-Object { $rowCountByTable.ContainsKey($_) -and -not $rowCountByTable[$_].Match }).Count
	$notComparedCount = @($allTables | Where-Object { -not $rowCountByTable.ContainsKey($_) }).Count

	# --- "Fehlende / fehlgeschlagene Tabellen" ------------------------------------
	$problemRowsHtml = New-Object System.Text.StringBuilder
	if ($problemTableCount -eq 0)
	{
		[void]$problemRowsHtml.Append('<tr><td colspan="4" class="empty">Keine fehlenden oder fehlgeschlagenen Tabellen.</td></tr>')
	}
	else
	{
		foreach ($t in $allTables)
		{
			if (-not $tableProblems.ContainsKey($t)) { continue }
			foreach ($step in $tableProblems[$t])
			{
				[void]$problemRowsHtml.Append("<tr><td>$(Escape-Html $t)</td><td>$(Escape-Html $step.Step)</td>" + `
						"<td><span class=`"badge err`">$(Escape-Html $step.Status)</span></td>" + `
						"<td>$(Escape-Html $step.Message)</td></tr>")
			}
		}
	}

	# --- "Zeilenvergleich" ---------------------------------------------------------
	$rowCountRowsHtml = New-Object System.Text.StringBuilder
	if ($totalTables -eq 0)
	{
		[void]$rowCountRowsHtml.Append('<tr><td colspan="5" class="empty">Keine Tabellen verarbeitet.</td></tr>')
	}
	else
	{
		foreach ($t in $allTables)
		{
			if ($rowCountByTable.ContainsKey($t))
			{
				$rc = $rowCountByTable[$t]
				if ($rc.Message)
				{
					$badge = '<span class="badge err">Fehler</span>'
					$diffText = '-'
				}
				elseif ($rc.Match)
				{
					$badge = '<span class="badge ok">OK</span>'
					$diffText = '0'
				}
				else
				{
					$badge = '<span class="badge warn">Abweichung</span>'
					$diffText = "$($rc.Difference)"
				}
				$srcRows = if ($null -ne $rc.SourceRows) { "$($rc.SourceRows)" } else { '-' }
				$dstRows = if ($null -ne $rc.DestinationRows) { "$($rc.DestinationRows)" } else { '-' }
				[void]$rowCountRowsHtml.Append("<tr><td>$(Escape-Html $t)</td><td class=`"num`">$srcRows</td>" + `
						"<td class=`"num`">$dstRows</td><td class=`"num`">$diffText</td><td>$badge</td></tr>")
			}
			else
			{
				[void]$rowCountRowsHtml.Append("<tr><td>$(Escape-Html $t)</td><td class=`"num`">-</td><td class=`"num`">-</td>" + `
						"<td class=`"num`">-</td><td><span class=`"badge warn`">Nicht verglichen</span></td></tr>")
			}
		}
	}

	$generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

	$html = @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<title>$(Escape-Html $Title)</title>
<style>
:root{--bg:#faf9f5;--card:#fff;--ink:#1f1e1b;--mut:#6b6a64;--bd:#e3e1d8;--blue:#378ADD;--green:#1D9E75;--amber:#BA7517;--red:#E24B4A}
@media(prefers-color-scheme:dark){:root{--bg:#1b1b19;--card:#252523;--ink:#ECEAE2;--mut:#9c9b93;--bd:#3a3a36}}
body{margin:0;background:var(--bg);color:var(--ink);font-family:Segoe UI,system-ui,sans-serif;font-size:15px;line-height:1.5}
.wrap{max-width:980px;margin:0 auto;padding:24px}
h1{font-size:20px;font-weight:600;margin:0 0 4px}
h2{font-size:16px;font-weight:600;margin:28px 0 10px}
.sub{color:var(--mut);font-size:13px;margin:0 0 18px}
.chips{display:flex;gap:10px;flex-wrap:wrap;margin:14px 0 4px}
.chip{border:1px solid var(--bd);border-radius:8px;padding:8px 14px;font-size:13px;background:var(--card);color:var(--mut);display:flex;align-items:center;gap:8px}
.chip b{color:var(--ink);font-size:15px}
.chip.ok{border-color:var(--green)} .chip.ok b{color:var(--green)}
.chip.warn{border-color:var(--amber)} .chip.warn b{color:var(--amber)}
.chip.err{border-color:var(--red)} .chip.err b{color:var(--red)}
table{width:100%;border-collapse:collapse;font-size:13.5px;background:var(--card);border:1px solid var(--bd);border-radius:8px;overflow:hidden}
th{background:var(--bd);color:var(--ink);padding:8px 12px;text-align:left;font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.03em}
td{padding:7px 12px;border-top:1px solid var(--bd);vertical-align:top}
td.num{text-align:right;font-variant-numeric:tabular-nums}
tr:hover td{background:rgba(128,128,128,.06)}
.empty{color:var(--mut);font-style:italic}
.badge{display:inline-block;padding:2px 9px;border-radius:20px;font-size:11.5px;font-weight:600}
.badge.ok{background:rgba(29,158,117,.15);color:var(--green)}
.badge.warn{background:rgba(186,117,23,.15);color:var(--amber)}
.badge.err{background:rgba(226,75,74,.15);color:var(--red)}
footer{margin-top:28px;color:var(--mut);font-size:12px}
</style>
</head>
<body><div class="wrap">
<h1>$(Escape-Html $Title)</h1>
<p class="sub">$(Escape-Html $Source).$(Escape-Html $SourceDatabase) &rarr; $(Escape-Html $Destination).$(Escape-Html $DestinationDatabase) &nbsp;|&nbsp; erzeugt $generated</p>

<div class="chips">
    <div class="chip"><b>$totalTables</b> Tabelle(n) gesamt</div>
    <div class="chip $(if ($problemTableCount -gt 0) { 'err' } else { 'ok' })"><b>$problemTableCount</b> mit Problemen</div>
    <div class="chip ok"><b>$matchCount</b> Zeilenzahl OK</div>
    <div class="chip $(if ($mismatchCount -gt 0) { 'warn' } else { 'ok' })"><b>$mismatchCount</b> Abweichung(en)</div>
    <div class="chip $(if ($notComparedCount -gt 0) { 'warn' } else { 'ok' })"><b>$notComparedCount</b> nicht verglichen</div>
</div>

<h2>Fehlende / fehlgeschlagene Tabellen</h2>
<table>
<thead><tr><th>Tabelle</th><th>Schritt</th><th>Status</th><th>Meldung</th></tr></thead>
<tbody>
$($problemRowsHtml.ToString())
</tbody>
</table>

<h2>Zeilenvergleich (Quelle vs. Ziel)</h2>
<table>
<thead><tr><th>Tabelle</th><th>Quelle (Zeilen)</th><th>Ziel (Zeilen)</th><th>Differenz</th><th>Status</th></tr></thead>
<tbody>
$($rowCountRowsHtml.ToString())
</tbody>
</table>

<footer>sqmDataTransfer $((Get-sqmTransferConfig -Key 'ModuleVersion'))</footer>
</div></body>
</html>
"@

	try
	{
		$dir = Split-Path $FilePath -Parent
		if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
		[System.IO.File]::WriteAllText($FilePath, $html, (New-Object System.Text.UTF8Encoding($false)))
		Write-sqmTransferLog -Message "HTML-Bericht geschrieben nach '$FilePath'." -FunctionName $MyInvocation.MyCommand.Name -Level 'INFO'
	}
	catch
	{
		Write-Warning "Konnte HTML-Bericht nicht nach '$FilePath' schreiben: $($_.Exception.Message)"
		Write-sqmTransferLog -Message "Fehler beim Schreiben des HTML-Berichts nach '$FilePath': $($_.Exception.Message)" -FunctionName $MyInvocation.MyCommand.Name -Level 'ERROR'
	}

	if ($PassThru) { return $html }
}
