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

        1. Discovers every distinct -ChunkColumn value on the source (ORDER BY), capped at
           -MaxChunkValues - this function is for a column with a modest number of distinct values
           (dozens to a few hundred, e.g. monthly snapshots), not a near-continuous timestamp.
        2. Optional -Truncate empties the destination table ONCE, up front - not per chunk, since
           TRUNCATE TABLE is table-wide regardless of any WHERE filter.
        3. For each distinct value, compares row counts for just that slice (COUNT_BIG(*) WHERE
           [ChunkColumn] = value) between source and destination. A slice whose counts already
           match is skipped - this is what makes a re-run after a partial failure resume from
           where it left off, without needing a row-level key.
        4. Any slice that doesn't match gets a normal Invoke-sqmTableTransfer call scoped to just
           that value via -SourceQuery (SELECT * ... WHERE [ChunkColumn] = value), with per-chunk
           reports suppressed (-NoReport) so a large chunk count doesn't produce a report pile-up -
           see Export-sqmTransferReport for the single consolidated report written at the end.

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

.PARAMETER MaxChunkValues
    Safety cap on the number of distinct -ChunkColumn values this function will process. Default:
    500. Throws before starting if the source has more - a near-continuous column (e.g. an exact
    timestamp) is the wrong choice for -ChunkColumn and would produce thousands of tiny calls.

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
    Include foreign keys in the disable/enable handling around each chunk's copy. Default: $true.

.PARAMETER IncludeIndexes
    Include indexes in the disable/enable handling around each chunk's copy. Default: $true.

.PARAMETER IncludeTriggers
    Include triggers in the disable/enable handling around each chunk's copy. Default: $true.

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

.PARAMETER NoOpen
    Do not automatically open the consolidated HTML report after the run.

.PARAMETER Confirm
.PARAMETER WhatIf

.EXAMPLE
    Invoke-sqmChunkedTableTransfer -Source SUEB001IBP -SourceDatabase FXUeberleitung `
        -Destination SQL02 -DestinationDatabase FXUeberleitung -Table dbo.ACC_ATOM_GUV_PLUS `
        -ChunkColumn dtmStichtag -Truncate

    Transfers ACC_ATOM_GUV_PLUS one Stichtag at a time. If interrupted, re-running the identical
    command (without -Truncate) skips every Stichtag that already matches and only copies the rest.

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
		[Parameter(Mandatory = $true)]
		[string]$ChunkColumn,
		[Parameter(Mandatory = $false)]
		[int]$MaxChunkValues = 500,
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

	$srcConnParams = @{ SqlInstance = $Source; Database = $SourceDatabase; ErrorAction = 'Stop' }
	$dstConnParams = @{ SqlInstance = $Destination; Database = $DestinationDatabase; ErrorAction = 'Stop' }
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

	Write-sqmTransferLog -Message "Invoke-sqmChunkedTableTransfer: '$Source'.'$SourceDatabase'.$qualified -> '$Destination'.'$DestinationDatabase' per '$ChunkColumn'" `
						  -FunctionName $functionName -Level 'INFO'

	$chunkQuery = "SELECT DISTINCT [$ChunkColumn] AS ChunkValue FROM $bracketed ORDER BY [$ChunkColumn]"
	$chunkValues = @(Invoke-DbaQuery @srcConnParams -Query $chunkQuery -As PSObject -EnableException | Select-Object -ExpandProperty ChunkValue)

	if ($chunkValues.Count -eq 0)
	{
		Write-Warning "Keine Werte in '$ChunkColumn' auf '$Source'.'$SourceDatabase'.$qualified gefunden - nichts zu tun."
		return @()
	}
	if ($chunkValues.Count -gt $MaxChunkValues)
	{
		throw "'$ChunkColumn' hat $($chunkValues.Count) unterschiedliche Werte auf $qualified - mehr als -MaxChunkValues ($MaxChunkValues). " + `
			"Vermutlich die falsche Spalte fuer chunk-weisen Transfer (zu feingranular) - eine groebere Spalte waehlen oder -MaxChunkValues explizit erhoehen."
	}

	if ($Truncate)
	{
		# Nur leeren, wenn die Zieltabelle schon existiert - bei einem allerersten Lauf legt erst
		# der erste Chunk (ueber -ScriptMetadata) die Tabelle an; TRUNCATE auf eine nicht
		# existierende Tabelle wuerde sonst fehlschlagen.
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

	$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
	$chunkIndex = 0
	$chunkTotal = $chunkValues.Count

	foreach ($chunkValue in $chunkValues)
	{
		$chunkIndex++
		$literal = Format-SqlLiteral $chunkValue
		$chunkLabel = "$ChunkColumn = $literal"

		Write-Progress -Id 3 -Activity "Chunked Transfer: $qualified" -Status "Chunk $chunkIndex von $chunkTotal ($chunkLabel)" `
						-PercentComplete ([math]::Floor((($chunkIndex - 1) / $chunkTotal) * 100))

		# --- Skip-Check: dieser Chunk allein, per COUNT_BIG(*) WHERE [ChunkColumn] = Wert -
		# macht einen erneuten Lauf nach einem Abbruch resumable, ganz ohne Primary-/Unique-Key.
		try
		{
			$srcCount = [int64](Invoke-DbaQuery @srcConnParams -Query "SELECT COUNT_BIG(*) AS [RowCount] FROM $bracketed WHERE [$ChunkColumn] = $literal" -As PSObject -EnableException).RowCount
			$dstCount = [int64](Invoke-DbaQuery @dstConnParams -Query "SELECT COUNT_BIG(*) AS [RowCount] FROM $bracketed WHERE [$ChunkColumn] = $literal" -As PSObject -EnableException).RowCount
		}
		catch
		{
			$srcCount = $null; $dstCount = $null
		}

		if ($null -ne $srcCount -and $srcCount -eq $dstCount)
		{
			Write-sqmTransferLog -Message "Chunk $chunkLabel bereits vollstaendig ($srcCount Zeile(n)) - uebersprungen." -FunctionName $functionName -Level 'INFO'
			$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = "$chunkValue"; Step = 'SkipCompletedChunk'; Status = 'Skipped'; Message = "$srcCount Zeile(n) bereits identisch."; Timestamp = (Get-Date) })
			continue
		}

		$chunkSql = "SELECT * FROM $bracketed WHERE [$ChunkColumn] = $literal"
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
			# ScriptMetadata wird bei jedem Chunk mitgegeben statt nur beim ersten - Invoke-sqmTableTransfer
			# prueft selbst per Get-DbaDbTable, ob die Zieltabelle schon existiert, und legt sie nur an,
			# wenn nicht (idempotent) - so entsteht kein Sonderfall fuer "welcher Chunk war der erste
			# tatsaechlich ausgefuehrte" bei einem Wiederanlauf.
			ScriptMetadata		   = $ScriptMetadata.IsPresent
			IncludeForeignKeys	   = $IncludeForeignKeys
			IncludeIndexes		   = $IncludeIndexes
			IncludeTriggers		   = $IncludeTriggers
			SkipConstraintHandling = $SkipConstraintHandling
			RevalidateForeignKeys  = $RevalidateForeignKeys
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

		try
		{
			$srcCountAfter = [int64](Invoke-DbaQuery @srcConnParams -Query "SELECT COUNT_BIG(*) AS [RowCount] FROM $bracketed WHERE [$ChunkColumn] = $literal" -As PSObject -EnableException).RowCount
			$dstCountAfter = [int64](Invoke-DbaQuery @dstConnParams -Query "SELECT COUNT_BIG(*) AS [RowCount] FROM $bracketed WHERE [$ChunkColumn] = $literal" -As PSObject -EnableException).RowCount
			$chunkMatch = $srcCountAfter -eq $dstCountAfter
			$allResults.Add([PSCustomObject]@{
					Table = $qualified; Chunk = "$chunkValue"; Step = 'CompareRowCount'
					Status = $(if ($chunkMatch) { 'Success' } else { 'Mismatch' })
					Message = "Quelle=$srcCountAfter Ziel=$dstCountAfter Differenz=$($dstCountAfter - $srcCountAfter)"
					Timestamp = (Get-Date)
				})
		}
		catch
		{
			$allResults.Add([PSCustomObject]@{ Table = $qualified; Chunk = "$chunkValue"; Step = 'CompareRowCount'; Status = 'Failed'; Message = $_.Exception.Message; Timestamp = (Get-Date) })
		}
	}

	Write-Progress -Id 3 -Activity "Chunked Transfer: $qualified" -Completed

	$skippedChunks = @($allResults | Where-Object Step -eq 'SkipCompletedChunk').Count
	$failCount = @($allResults | Where-Object Status -in @('Failed', 'Mismatch', 'NotFound')).Count
	$summaryMsg = "Invoke-sqmChunkedTableTransfer abgeschlossen fuer $qualified - $chunkTotal Chunk(s), $skippedChunks bereits vollstaendig uebersprungen, $failCount mit Fehler/Mismatch/NotFound."
	Write-sqmTransferLog -Message $summaryMsg -FunctionName $functionName -Level 'INFO'
	Write-Host $summaryMsg -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' } else { 'Green' })

	try
	{
		$finalCompare = Compare-sqmTableRowCount -Source $Source -SourceDatabase $SourceDatabase `
												   -Destination $Destination -DestinationDatabase $DestinationDatabase `
												   -Table $Table -SourceCredential $srcCred -DestinationCredential $dstCred

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

	return $allResults
}
