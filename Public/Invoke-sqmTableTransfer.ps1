<#
.SYNOPSIS
    Orchestrates a full table data transfer between two SQL Server instances.

.DESCRIPTION
    For each table, runs the following sequence:
        1. Optional: script the table's metadata from the source and create it on the target if
           it doesn't already exist yet (-ScriptMetadata).
        2. Disable foreign keys and non-clustered indexes on the target table
           (unless -SkipConstraintHandling).
        3. Copy the data (Copy-sqmTableData).
        4. Compare row counts between source and target (Compare-sqmTableRowCount).
        5. Re-enable foreign keys and indexes on the target table - guaranteed via a finally
           block scoped around steps 2-4, even if an earlier step in that window throws.
    Every step is logged (Write-sqmTransferLog) and reported in the returned result list.
    Continues with the next table on error unless -EnableException is set.

.PARAMETER Source
    Source SQL Server instance.

.PARAMETER SourceDatabase
    Source database name.

.PARAMETER Destination
    Target SQL Server instance.

.PARAMETER DestinationDatabase
    Target database name.

.PARAMETER Table
    One or more table names to transfer ('Table' or 'schema.Table').

.PARAMETER SqlCredential
    Optional PSCredential for both instances. For different credentials use
    -SourceCredential / -DestinationCredential.

.PARAMETER SourceCredential
    PSCredential specifically for the source instance.

.PARAMETER DestinationCredential
    PSCredential specifically for the target instance.

.PARAMETER ScriptMetadata
    Script the table's metadata from the source and create it on the target if it does not
    already exist there. Existing target tables are left untouched (never dropped/recreated).

.PARAMETER IncludeForeignKeys
    Include foreign keys in metadata scripting and in the disable/enable handling. Default: $true.

.PARAMETER IncludeIndexes
    Include indexes in metadata scripting and in the disable/enable handling. Default: $true.

.PARAMETER SkipConstraintHandling
    Skip disabling/re-enabling foreign keys and indexes entirely.

.PARAMETER RevalidateForeignKeys
    Revalidate foreign key data when re-enabling (WITH CHECK). Default: $true.

.PARAMETER Truncate
    Truncate the destination table before copying data.

.PARAMETER KeepIdentity
    Preserve source IDENTITY column values on the target. Default: $true.

.PARAMETER KeepNulls
    Preserve NULL values instead of applying target column defaults. Default: $true.

.PARAMETER BatchSize
    Rows per batch for the data copy. Default: the module's DefaultBatchSize.

.PARAMETER ContinueOnError
    Continue with the next table on error.

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER OutputPath
    Folder the HTML report is written to (filename is generated automatically). Same convention
    as sqmSQLTool's report-generating functions: defaults to Get-sqmTransferConfig -Key
    'OutputPath' (falling back to "C:\System\WinSrvLog\MSSQL") when not specified - i.e. the same
    location as sqmSQLTool uses by default. A report is always produced; there is no switch to
    turn it off. Report generation failures are logged/warned but do not fail the transfer itself.

.PARAMETER NoOpen
    Do not automatically open the HTML report after the run. Default: opens it (same convention
    as sqmSQLTool's Invoke-sqmOpenReport / -NoOpen).

.PARAMETER Confirm
.PARAMETER WhatIf

.EXAMPLE
    Invoke-sqmTableTransfer -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -Table Orders,Customers -ScriptMetadata -Truncate

    Scripts and creates missing tables on the target, disables FKs/indexes, copies data, compares
    row counts and re-enables FKs/indexes for both tables. Writes and opens the HTML report from
    the default OutputPath.

.EXAMPLE
    Invoke-sqmTableTransfer -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -Table Orders -WhatIf

    Simulates the full sequence without making any changes.

.EXAMPLE
    Invoke-sqmTableTransfer -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -Table Orders,Customers,Missing -ScriptMetadata -OutputPath C:\Temp -NoOpen

    Runs the transfer, writes the HTML report into C:\Temp (listing 'Missing' as not found on the
    source and comparing row counts for Orders/Customers) but does not open it automatically.

.NOTES
    Prerequisites : dbatools, Copy-sqmTableSchema, Disable-sqmTableConstraints,
                    Copy-sqmTableData, Compare-sqmTableRowCount, Enable-sqmTableConstraints,
                    Export-sqmTransferReport.
    Re-enable guarantee: scoped tightly around disable/transfer/compare per table in a finally
                    block, so a failure at any of those steps still re-enables what this run
                    disabled on that table.
#>
function Invoke-sqmTableTransfer
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
		[switch]$SkipConstraintHandling,
		[Parameter(Mandatory = $false)]
		[bool]$RevalidateForeignKeys = $true,
		[Parameter(Mandatory = $false)]
		[switch]$Truncate,
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

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		$srcCred = if ($SourceCredential) { $SourceCredential } elseif ($SqlCredential) { $SqlCredential } else { $null }
		$dstCred = if ($DestinationCredential) { $DestinationCredential } elseif ($SqlCredential) { $SqlCredential } else { $null }

		if (-not $PSBoundParameters.ContainsKey('BatchSize'))
		{
			$BatchSize = Get-sqmTransferConfig -Key 'DefaultBatchSize'
			if (-not $BatchSize) { $BatchSize = 50000 }
		}

		if (-not $PSBoundParameters.ContainsKey('OutputPath') -or [string]::IsNullOrWhiteSpace($OutputPath))
		{
			$OutputPath = Get-sqmTransferConfig -Key 'OutputPath'
			if (-not $OutputPath) { $OutputPath = "C:\System\WinSrvLog\MSSQL" }
		}

		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		$rowCountResults = [System.Collections.Generic.List[PSCustomObject]]::new()

		function _AddResult
		{
			param ([string]$TableName, [string]$Step, [string]$Status, [string]$Message)
			$results.Add([PSCustomObject]@{
					Table	  = $TableName
					Step	  = $Step
					Status	  = $Status
					Message   = $Message
					Timestamp = (Get-Date)
				})
		}

		Write-sqmTransferLog -Message "Start Invoke-sqmTableTransfer: '$Source'.'$SourceDatabase' -> '$Destination'.'$DestinationDatabase' | Tabellen: $($Table -join ', ')" `
							  -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		foreach ($t in $Table)
		{
			Write-sqmTransferLog -Message "=== Verarbeite Tabelle '$t' ===" -FunctionName $functionName -Level 'INFO'

			# ------------------------------------------------------------------
			# 1. Metadaten scripten + auf Ziel anlegen (falls noch nicht vorhanden)
			# ------------------------------------------------------------------
			if ($ScriptMetadata)
			{
				try
				{
					$existsParams = @{ SqlInstance = $Destination; Database = $DestinationDatabase; Table = $t; ErrorAction = 'SilentlyContinue' }
					if ($dstCred) { $existsParams['SqlCredential'] = $dstCred }
					$existing = Get-DbaDbTable @existsParams

					if ($existing)
					{
						_AddResult $t 'ScriptMetadata' 'Skipped' "Tabelle existiert bereits auf '$Destination'.'$DestinationDatabase' - wird nicht neu angelegt."
						Write-sqmTransferLog -Message "Tabelle '$t' existiert bereits auf Ziel - Metadaten-Erstellung uebersprungen." -FunctionName $functionName -Level 'INFO'
					}
					else
					{
						$createAction = "Tabelle '$t' auf '$Destination'.'$DestinationDatabase' aus Quellmetadaten anlegen"
						if ($PSCmdlet.ShouldProcess($Destination, $createAction))
						{
							$schemaResults = Copy-sqmTableSchema -Source $Source -SourceDatabase $SourceDatabase `
																  -Destination $Destination -DestinationDatabase $DestinationDatabase `
																  -Table $t -SourceCredential $srcCred -DestinationCredential $dstCred `
																  -IncludeForeignKeys $IncludeForeignKeys -IncludeIndexes $IncludeIndexes `
																  -EnableException:$EnableException -Confirm:$false

							$notFoundResult = $schemaResults | Where-Object Status -eq 'NotFound' | Select-Object -First 1
							if ($notFoundResult)
							{
								_AddResult $t 'ScriptMetadata' 'NotFound' $notFoundResult.Message
								if (-not $ContinueOnError -and $EnableException) { throw "Tabelle '$t' nicht auf Quelle '$Source'.'$SourceDatabase' gefunden." }
								# Ohne Quelltabelle sind Disable/Copy/Compare fuer diese Tabelle sinnlos - naechste Tabelle.
								continue
							}

							$schemaFailCount = @($schemaResults | Where-Object Status -eq 'Failed').Count
							if ($schemaFailCount -gt 0)
							{
								_AddResult $t 'ScriptMetadata' 'Failed' "$schemaFailCount von $($schemaResults.Count) Batch(es) fehlgeschlagen."
								if (-not $ContinueOnError -and $EnableException) { throw "Metadaten-Erstellung fuer '$t' fehlgeschlagen." }
							}
							else
							{
								_AddResult $t 'ScriptMetadata' 'Success' "Tabelle '$t' auf Ziel angelegt ($($schemaResults.Count) Batch(es))."
							}
						}
						else
						{
							_AddResult $t 'ScriptMetadata' 'WhatIf' "WhatIf: $createAction"
						}
					}
				}
				catch
				{
					$msg = "Fehler bei der Metadaten-Erstellung fuer '$t': $($_.Exception.Message)"
					_AddResult $t 'ScriptMetadata' 'Failed' $msg
					Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
					if ($EnableException -and -not $ContinueOnError) { throw }
					continue
				}
			}

			# ------------------------------------------------------------------
			# 2-4. Disable -> Copy -> Compare, mit garantiertem Re-Enable (finally)
			# ------------------------------------------------------------------
			$constraintsWereDisabled = $false
			try
			{
				if (-not $SkipConstraintHandling)
				{
					$disableAction = "FKs/Indizes auf '$Destination'.'$DestinationDatabase'.[$t] deaktivieren"
					if ($PSCmdlet.ShouldProcess($Destination, $disableAction))
					{
						$disableResults = Disable-sqmTableConstraints -SqlInstance $Destination -Database $DestinationDatabase `
																	   -Table $t -SqlCredential $dstCred `
																	   -IncludeForeignKeys $IncludeForeignKeys -IncludeIndexes $IncludeIndexes `
																	   -Confirm:$false
						$constraintsWereDisabled = $true
						$disableFailCount = @($disableResults | Where-Object Status -like 'Failed*').Count
						$status = if ($disableFailCount -gt 0) { 'Warning' } else { 'Success' }
						_AddResult $t 'DisableConstraints' $status "$($disableResults.Count) Objekt(e) verarbeitet, $disableFailCount Fehler."
					}
					else
					{
						_AddResult $t 'DisableConstraints' 'WhatIf' "WhatIf: $disableAction"
					}
				}
				else
				{
					_AddResult $t 'DisableConstraints' 'Skipped' 'SkipConstraintHandling gesetzt.'
				}

				# --- Daten kopieren ---
				$copyResults = Copy-sqmTableData -Source $Source -SourceDatabase $SourceDatabase `
												  -Destination $Destination -DestinationDatabase $DestinationDatabase `
												  -Table $t -SourceCredential $srcCred -DestinationCredential $dstCred `
												  -Truncate:$Truncate -KeepIdentity $KeepIdentity -KeepNulls $KeepNulls `
												  -BatchSize $BatchSize -ContinueOnError:$ContinueOnError -EnableException:$EnableException `
												  -Confirm:$false -WhatIf:$WhatIfPreference

				$copyResult = $copyResults | Select-Object -First 1
				if ($copyResult)
				{
					_AddResult $t 'CopyData' $copyResult.Status "$($copyResult.RowsCopied) Zeile(n) in $($copyResult.ElapsedSeconds)s. $($copyResult.Message)"
					if ($copyResult.Status -eq 'Failed' -and $EnableException -and -not $ContinueOnError) { throw "Datenkopie fuer '$t' fehlgeschlagen: $($copyResult.Message)" }
				}

				# --- Zeilen vergleichen (nur sinnvoll wenn tatsaechlich kopiert wurde) ---
				if ($copyResult -and $copyResult.Status -eq 'Success')
				{
					$compareResult = Compare-sqmTableRowCount -Source $Source -SourceDatabase $SourceDatabase `
															   -Destination $Destination -DestinationDatabase $DestinationDatabase `
															   -Table $t -SourceCredential $srcCred -DestinationCredential $dstCred |
					Select-Object -First 1

					if ($compareResult)
					{
						$cmpStatus = if ($compareResult.Message) { 'Failed' } elseif ($compareResult.Match) { 'Success' } else { 'Mismatch' }
						_AddResult $t 'CompareRowCount' $cmpStatus "Quelle=$($compareResult.SourceRows) Ziel=$($compareResult.DestinationRows) Differenz=$($compareResult.Difference)"
						$rowCountResults.Add($compareResult)
					}
				}
				else
				{
					_AddResult $t 'CompareRowCount' 'Skipped' 'Datenkopie nicht erfolgreich - Vergleich uebersprungen.'
				}
			}
			catch
			{
				$msg = "Fehler bei der Verarbeitung von '$t': $($_.Exception.Message)"
				_AddResult $t 'Transfer' 'Failed' $msg
				Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
				if ($EnableException -and -not $ContinueOnError) { throw }
			}
			finally
			{
				if ($constraintsWereDisabled)
				{
					try
					{
						$enableResults = Enable-sqmTableConstraints -SqlInstance $Destination -Database $DestinationDatabase `
																	 -Table $t -SqlCredential $dstCred -Revalidate $RevalidateForeignKeys `
																	 -Confirm:$false
						$enableFailCount = @($enableResults | Where-Object Status -like 'Failed*').Count
						$status = if ($enableFailCount -gt 0) { 'Warning' } else { 'Success' }
						_AddResult $t 'EnableConstraints' $status "$($enableResults.Count) Objekt(e) verarbeitet, $enableFailCount Fehler."
					}
					catch
					{
						# Nicht weiterwerfen - eine urspruengliche Ausnahme aus dem Transfer darf nicht verdeckt werden.
						$msg = "KRITISCH: Re-Enable von FKs/Indizes fuer '$t' fehlgeschlagen: $($_.Exception.Message)"
						Write-Warning $msg
						Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
						_AddResult $t 'EnableConstraints' 'Failed' $msg
					}
				}
			}
		}
	}

	end
	{
		$successCount = @($results | Where-Object Status -eq 'Success').Count
		$failCount = @($results | Where-Object Status -in @('Failed', 'Mismatch', 'NotFound')).Count
		$warnCount = @($results | Where-Object Status -in @('Warning', 'Skipped', 'WhatIf')).Count

		$summaryMsg = "Invoke-sqmTableTransfer abgeschlossen - Erfolg: $successCount | Fehler/Mismatch/NotFound: $failCount | Warnungen/Uebersprungen: $warnCount"
		Write-sqmTransferLog -Message $summaryMsg -FunctionName $functionName -Level 'INFO'
		Write-Host $summaryMsg -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' } else { 'Green' })

		try
		{
			if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

			$safeSource = "$Source.$SourceDatabase" -replace '[\\:.]', '_'
			$safeDest = "$Destination.$DestinationDatabase" -replace '[\\:.]', '_'
			$datestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
			$htmlFile = Join-Path $OutputPath "sqmDataTransfer_TransferReport_${safeSource}_to_${safeDest}_${datestamp}.html"

			Export-sqmTransferReport -Source $Source -SourceDatabase $SourceDatabase `
									  -Destination $Destination -DestinationDatabase $DestinationDatabase `
									  -Results $results -RowCounts $rowCountResults -FilePath $htmlFile -NoOpen:$NoOpen
		}
		catch
		{
			Write-Warning "HTML-Bericht konnte nicht erzeugt werden: $($_.Exception.Message)"
			Write-sqmTransferLog -Message "HTML-Bericht konnte nicht erzeugt werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
		}

		return $results
	}
}
