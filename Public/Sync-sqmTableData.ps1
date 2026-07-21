<#
.SYNOPSIS
    Synchronizes table data between two SQL Server instances by transferring only rows that are
    new, changed, or (optionally) deleted since the last transfer.

.DESCRIPTION
    Intended for the "customer is testing against the target while the source keeps moving"
    situation: re-running a full Copy-sqmTableData/Invoke-sqmTableTransfer means truncating and
    re-copying everything, which is wasteful once a table has already been fully transferred once.
    Sync-sqmTableData instead:

        1. Reads the primary key and column metadata of the table from the DESTINATION (the table
           must already exist there with the same structure as the source - run this only on
           tables that went through a full transfer already).
        2. Computes a SHA2-256 hash over all non-PK, non-computed, non-rowversion columns, for
           every row, on both source and destination (SELECT [pk-cols], HASHBYTES(...)). This is a
           full scan of the table on both sides - the one cost that can't be avoided if changes
           need to be detected without a trustworthy modified-date column. Only run this against
           tables that are actually expected to have changed; for a large table set, filter
           -Table down to the known-affected ones rather than passing everything.
        3. Compares the two (PK -> hash) sets in memory to find inserted, updated and (if
           -IncludeDelete) deleted primary keys. If nothing differs, the table is skipped entirely
           - no further reads or writes.
        4. For inserted/updated rows: pulls the full rows for just those primary keys from the
           source, loads them into a throwaway staging table on the destination
           (Write-DbaDbTableData), then applies them with a single MERGE (upsert) into the real
           target table. IDENTITY columns are handled via SET IDENTITY_INSERT around the MERGE.
        5. For deleted rows (-IncludeDelete): deletes the corresponding primary keys directly from
           the destination table.
        6. Drops the staging table.

    Row-value lists (source SELECT, DELETE) are chunked to 1000 keys per statement - SQL Server's
    hard limit for a VALUES row constructor - regardless of -BatchSize (which only controls the
    staging-table bulk load).

.PARAMETER Source
    Source SQL Server instance.

.PARAMETER SourceDatabase
    Source database name.

.PARAMETER Destination
    Target SQL Server instance.

.PARAMETER DestinationDatabase
    Target database name.

.PARAMETER Table
    One or more table names ('Table' or 'schema.Table'). Must already exist, with the same
    structure, on both sides.

.PARAMETER SourceCredential
    Optional PSCredential for the source instance.

.PARAMETER DestinationCredential
    Optional PSCredential for the target instance.

.PARAMETER IncludeDelete
    Also delete rows from the destination whose primary key no longer exists in the source.
    Default: $true (destination is kept as an exact mirror of the source).

.PARAMETER BatchSize
    Rows per batch for the staging-table bulk load. Default: the module's DefaultBatchSize.

.PARAMETER ContinueOnError
    Continue with the next table on error.

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
.PARAMETER WhatIf

.EXAMPLE
    Sync-sqmTableData -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -Table dbo.Orders,dbo.OrderDetails

    Hash-compares both tables and applies only the actual differences (insert/update/delete).

.EXAMPLE
    Sync-sqmTableData -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -Table dbo.Orders -IncludeDelete:$false -WhatIf

    Simulates an insert/update-only sync (no deletes) and reports what would change, without
    writing anything.

.NOTES
    Prerequisites: dbatools (Invoke-DbaQuery, Write-DbaDbTableData), Write-sqmTransferLog.
    Assumes identical schema on both sides (same columns/types) - use Copy-sqmTableSchema /
    -ScriptMetadata beforehand if the table might not exist yet on the target; this function does
    not create tables.
#>
function Sync-sqmTableData
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
		[string[]]$Table,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SourceCredential,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DestinationCredential,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeDelete = $true,
		[Parameter(Mandatory = $false)]
		[int]$BatchSize,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	$VALUES_CHUNK_SIZE = 1000

	$srcConnParams = @{ SqlInstance = $Source; Database = $SourceDatabase; ErrorAction = 'Stop' }
	$dstConnParams = @{ SqlInstance = $Destination; Database = $DestinationDatabase; ErrorAction = 'Stop' }
	if ($SourceCredential) { $srcConnParams['SqlCredential'] = $SourceCredential }
	if ($DestinationCredential) { $dstConnParams['SqlCredential'] = $DestinationCredential }

	if (-not $PSBoundParameters.ContainsKey('BatchSize'))
	{
		$BatchSize = Get-sqmTransferConfig -Key 'DefaultBatchSize'
		if (-not $BatchSize) { $BatchSize = 50000 }
	}

	function _FormatSqlLiteral
	{
		param ($Value)
		if ($null -eq $Value) { return 'NULL' }
		if ($Value -is [bool]) { return $(if ($Value) { '1' } else { '0' }) }
		if ($Value -is [byte[]]) { return '0x' + (($Value | ForEach-Object { $_.ToString('X2') }) -join '') }
		if ($Value -is [datetime]) { return "'" + $Value.ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + "'" }
		if ($Value -is [guid]) { return "'" + $Value.ToString() + "'" }
		if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
			$Value -is [decimal] -or $Value -is [double] -or $Value -is [single])
		{
			return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
		}
		return "'" + ($Value.ToString() -replace "'", "''") + "'"
	}

	function _BuildValuesClause
	{
		param ([string[]]$PkCols, [array]$KeyRows)
		# KeyRows: array of object[] (one array of PK values per row, in $PkCols order)
		$rowLiterals = foreach ($kr in $KeyRows)
		{
			'(' + (($kr | ForEach-Object { _FormatSqlLiteral $_ }) -join ',') + ')'
		}
		$aliasCols = ($PkCols | ForEach-Object { "[$_]" }) -join ','
		$joinCond = ($PkCols | ForEach-Object { "T.[$_] = X.[$_]" }) -join ' AND '
		return [PSCustomObject]@{
			ValuesSql = "(VALUES $($rowLiterals -join ',')) AS X($aliasCols)"
			JoinCond  = $joinCond
		}
	}

	$results = [System.Collections.Generic.List[PSCustomObject]]::new()

	foreach ($t in $Table)
	{
		$schemaName = 'dbo'
		$tableName = $t
		if ($t -match '^(?<schema>[^.]+)\.(?<name>.+)$') { $schemaName = $Matches['schema']; $tableName = $Matches['name'] }
		$qualified = "$schemaName.$tableName"
		$bracketed = "[$schemaName].[$tableName]"

		$sw = [System.Diagnostics.Stopwatch]::StartNew()
		Write-sqmTransferLog -Message "=== Sync '$qualified': '$Source'.'$SourceDatabase' -> '$Destination'.'$DestinationDatabase' ===" -FunctionName $functionName -Level 'INFO'

		try
		{
			# --- 1. PK + Spalten-Metadaten vom Ziel ermitteln -----------------------------
			$pkQuery = @"
SELECT c.name AS ColumnName
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID(N'$bracketed')
ORDER BY ic.key_ordinal
"@
			$pkCols = @(Invoke-DbaQuery @dstConnParams -Query $pkQuery -As PSObject -EnableException | ForEach-Object { $_.ColumnName })
			if ($pkCols.Count -eq 0)
			{
				throw "Keine PRIMARY KEY-Spalte(n) auf '$Destination'.'$DestinationDatabase'.$bracketed gefunden - Sync-sqmTableData benoetigt einen PK."
			}

			$colQuery = @"
SELECT c.name AS ColumnName, c.is_identity AS IsIdentity, c.is_computed AS IsComputed, ty.name AS TypeName
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'$bracketed')
ORDER BY c.column_id
"@
			$allCols = @(Invoke-DbaQuery @dstConnParams -Query $colQuery -As PSObject -EnableException)
			$writableCols = @($allCols | Where-Object { -not $_.IsComputed -and $_.TypeName -ne 'timestamp' })
			$writableColNames = @($writableCols | ForEach-Object { $_.ColumnName })
			$hashColNames = @($writableCols | Where-Object { $pkCols -notcontains $_.ColumnName } | ForEach-Object { $_.ColumnName })
			$hasIdentity = [bool]($writableCols | Where-Object IsIdentity)

			# --- 2. Hash-Ausdruck bauen und (PK, Hash) auf beiden Seiten abfragen -----------
			$binaryTypes = @('binary', 'varbinary', 'image')
			$hashFragments = if ($hashColNames.Count -gt 0)
			{
				foreach ($hc in $hashColNames)
				{
					$colMeta = $writableCols | Where-Object ColumnName -eq $hc | Select-Object -First 1
					if ($binaryTypes -contains $colMeta.TypeName)
					{
						"ISNULL(CONVERT(nvarchar(max), [$hc], 2), N'" + [char]1 + "')"
					}
					else
					{
						"ISNULL(CONVERT(nvarchar(max), [$hc]), N'" + [char]1 + "')"
					}
				}
			}
			else { , "N''" }
			$hashExpr = "HASHBYTES('SHA2_256', CONCAT_WS(NCHAR(31), $($hashFragments -join ', ')))"
			$pkSelectList = ($pkCols | ForEach-Object { "[$_]" }) -join ', '
			$hashQuery = "SELECT $pkSelectList, $hashExpr AS __sqmt_hash FROM $bracketed"

			$srcRows = @(Invoke-DbaQuery @srcConnParams -Query $hashQuery -As PSObject -EnableException)
			$dstRows = @(Invoke-DbaQuery @dstConnParams -Query $hashQuery -As PSObject -EnableException)

			function _KeyOf($row, [string[]]$cols) { ($cols | ForEach-Object { [string]$row.$_ }) -join ([char]31) }

			$srcMap = @{}
			foreach ($r in $srcRows) { $srcMap[(_KeyOf $r $pkCols)] = @{ Hash = [Convert]::ToBase64String($r.__sqmt_hash); Pk = @($pkCols | ForEach-Object { $r.$_ }) } }
			$dstMap = @{}
			foreach ($r in $dstRows) { $dstMap[(_KeyOf $r $pkCols)] = @{ Hash = [Convert]::ToBase64String($r.__sqmt_hash); Pk = @($pkCols | ForEach-Object { $r.$_ }) } }

			$insertKeys = @($srcMap.Keys | Where-Object { -not $dstMap.ContainsKey($_) })
			$updateKeys = @($srcMap.Keys | Where-Object { $dstMap.ContainsKey($_) -and $dstMap[$_].Hash -ne $srcMap[$_].Hash })
			$deleteKeys = @(if ($IncludeDelete) { @($dstMap.Keys | Where-Object { -not $srcMap.ContainsKey($_) }) })
			$changedKeys = @($insertKeys + $updateKeys)

			Write-sqmTransferLog -Message "Sync '$qualified': Quelle=$($srcRows.Count) Ziel=$($dstRows.Count) Neu=$($insertKeys.Count) Geaendert=$($updateKeys.Count) Geloescht=$($deleteKeys.Count)" `
								  -FunctionName $functionName -Level 'INFO'

			if ($changedKeys.Count -eq 0 -and $deleteKeys.Count -eq 0)
			{
				$sw.Stop()
				$results.Add([PSCustomObject]@{
						Table = $qualified; SourceRows = $srcRows.Count; DestinationRows = $dstRows.Count
						Inserted = 0; Updated = 0; Deleted = 0; Status = 'NoChanges'; Message = $null
						ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
					})
				continue
			}

			$action = "Sync '$qualified': $($insertKeys.Count) neu, $($updateKeys.Count) geaendert, $($deleteKeys.Count) geloescht"
			if (-not $PSCmdlet.ShouldProcess($Destination, $action))
			{
				$sw.Stop()
				$results.Add([PSCustomObject]@{
						Table = $qualified; SourceRows = $srcRows.Count; DestinationRows = $dstRows.Count
						Inserted = $insertKeys.Count; Updated = $updateKeys.Count; Deleted = $deleteKeys.Count
						Status = 'WhatIf'; Message = "WhatIf: $action"; ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
					})
				continue
			}

			# --- 3. Insert/Update ueber Staging-Tabelle + MERGE ------------------------------
			$stagingName = "__sqmSync_$([guid]::NewGuid().ToString('N'))"
			$stagingBracketed = "[dbo].[$stagingName]"
			$stagingCreated = $false

			try
			{
				if ($changedKeys.Count -gt 0)
				{
					$writableColList = ($writableColNames | ForEach-Object { "[$_]" }) -join ', '
					$writableColListQualified = ($writableColNames | ForEach-Object { "T.[$_]" }) -join ', '
					Invoke-DbaQuery @dstConnParams -Query "SELECT TOP (0) $writableColList INTO $stagingBracketed FROM $bracketed" -EnableException | Out-Null
					$stagingCreated = $true

					for ($i = 0; $i -lt $changedKeys.Count; $i += $VALUES_CHUNK_SIZE)
					{
						$chunk = $changedKeys[$i..([math]::Min($i + $VALUES_CHUNK_SIZE, $changedKeys.Count) - 1)]
						$keyRows = @($chunk | ForEach-Object { , $srcMap[$_].Pk })
						$vc = _BuildValuesClause -PkCols $pkCols -KeyRows $keyRows
						$selectSql = "SELECT $writableColListQualified FROM $bracketed AS T JOIN $($vc.ValuesSql) ON $($vc.JoinCond)"
						$writeParams = @{
							SqlInstance = $Destination; Database = $DestinationDatabase; Schema = 'dbo'; Table = $stagingName
							KeepIdentity = $true; BatchSize = $BatchSize; EnableException = $true; Confirm = $false
						}
						if ($DestinationCredential) { $writeParams['SqlCredential'] = $DestinationCredential }
						# -As DataTable statt PSObject: ConvertTo-DbaDataTable (intern in Write-DbaDbTableData
						# fuer PSObject-Input) reflektiert Spalten ueber Property-Namen und kollidiert dabei mit
						# .NET DataRow-Mitgliedern gleichen Namens (z.B. eine Spalte "Item" trifft auf
						# DataRow.Item[]) - eine direkt aus SQL gelesene DataTable hat dieses Problem nicht.
						$changedData = Invoke-DbaQuery @srcConnParams -Query $selectSql -As DataTable -EnableException
						Write-DbaDbTableData @writeParams -InputObject $changedData
					}

					$setClause = ($writableColNames | Where-Object { $pkCols -notcontains $_ } | ForEach-Object { "T.[$_] = S.[$_]" }) -join ', '
					$mergeOn = ($pkCols | ForEach-Object { "T.[$_] = S.[$_]" }) -join ' AND '
					$insertCols = ($writableColNames | ForEach-Object { "[$_]" }) -join ', '
					$insertVals = ($writableColNames | ForEach-Object { "S.[$_]" }) -join ', '
					$mergeSql = "MERGE INTO $bracketed AS T USING $stagingBracketed AS S ON $mergeOn " +
					$(if ($setClause) { "WHEN MATCHED THEN UPDATE SET $setClause " }) +
					"WHEN NOT MATCHED BY TARGET THEN INSERT ($insertCols) VALUES ($insertVals);"

					if ($hasIdentity)
					{
						$mergeSql = "SET IDENTITY_INSERT $bracketed ON; BEGIN TRY $mergeSql END TRY BEGIN CATCH SET IDENTITY_INSERT $bracketed OFF; THROW; END CATCH SET IDENTITY_INSERT $bracketed OFF;"
					}
					Invoke-DbaQuery @dstConnParams -Query $mergeSql -EnableException | Out-Null
				}

				# --- 4. Deletes --------------------------------------------------------------
				for ($i = 0; $i -lt $deleteKeys.Count; $i += $VALUES_CHUNK_SIZE)
				{
					$chunk = $deleteKeys[$i..([math]::Min($i + $VALUES_CHUNK_SIZE, $deleteKeys.Count) - 1)]
					$keyRows = @($chunk | ForEach-Object { , $dstMap[$_].Pk })
					$vc = _BuildValuesClause -PkCols $pkCols -KeyRows $keyRows
					$deleteSql = "DELETE T FROM $bracketed AS T JOIN $($vc.ValuesSql) ON $($vc.JoinCond)"
					Invoke-DbaQuery @dstConnParams -Query $deleteSql -EnableException | Out-Null
				}
			}
			finally
			{
				if ($stagingCreated)
				{
					try { Invoke-DbaQuery @dstConnParams -Query "DROP TABLE $stagingBracketed" -EnableException | Out-Null }
					catch { Write-Warning "Staging-Tabelle '$stagingName' konnte nicht entfernt werden: $($_.Exception.Message)" }
				}
			}

			$sw.Stop()
			$results.Add([PSCustomObject]@{
					Table = $qualified; SourceRows = $srcRows.Count; DestinationRows = $dstRows.Count
					Inserted = $insertKeys.Count; Updated = $updateKeys.Count; Deleted = $deleteKeys.Count
					Status = 'Success'; Message = $null; ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
				})
			Write-sqmTransferLog -Message "Sync '$qualified' abgeschlossen: +$($insertKeys.Count) ~$($updateKeys.Count) -$($deleteKeys.Count) ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)." `
								  -FunctionName $functionName -Level 'INFO'
		}
		catch
		{
			$sw.Stop()
			$msg = $_.Exception.Message
			$results.Add([PSCustomObject]@{
					Table = $qualified; SourceRows = $null; DestinationRows = $null
					Inserted = 0; Updated = 0; Deleted = 0; Status = 'Failed'; Message = $msg
					ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
				})
			Write-sqmTransferLog -Message "Sync fuer '$qualified' fehlgeschlagen: $msg" -FunctionName $functionName -Level 'ERROR'
			if ($EnableException -and -not $ContinueOnError) { throw }
		}
	}

	return $results
}
