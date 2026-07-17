<#
.SYNOPSIS
    Launches a graphical interface (WinForms) for sqmDataTransfer.

.DESCRIPTION
    Lets the user pick a source and target instance/database, load and select tables, choose
    transfer options (script+create missing tables, disable/enable FKs and indexes, truncate,
    revalidate FKs on re-enable, batch size, simulate/WhatIf) and run Invoke-sqmTableTransfer.
    The step-by-step log for the run and the structured per-table/per-step result table are shown
    after completion.

    Runs synchronously in the current runspace: the interface blocks while a transfer is running,
    same as this module's other long-running operations.

.EXAMPLE
    Show-sqmTableTransferGui
    Opens the graphical interface.

.NOTES
    Requires Windows PowerShell with WinForms (System.Windows.Forms).
#>
function Show-sqmTableTransferGui
{
	[CmdletBinding()]
	param ()

	Add-Type -AssemblyName System.Windows.Forms
	Add-Type -AssemblyName System.Drawing

	# --- Visual Studio "Dark" colour palette (consistent with Show-sqmToolGui) ------
	$cWindow = [System.Drawing.Color]::FromArgb(30, 30, 30)
	$cPanel  = [System.Drawing.Color]::FromArgb(45, 45, 48)
	$cText   = [System.Drawing.Color]::FromArgb(220, 220, 220)
	$cDim    = [System.Drawing.Color]::FromArgb(153, 153, 153)
	$cBtn    = [System.Drawing.Color]::FromArgb(62, 62, 66)
	$cAccent = [System.Drawing.Color]::FromArgb(0, 122, 204)
	$cBorder = [System.Drawing.Color]::FromArgb(63, 63, 70)
	$cOk     = [System.Drawing.Color]::FromArgb(78, 201, 176)
	$cWarn   = [System.Drawing.Color]::FromArgb(220, 180, 60)
	$cErr    = [System.Drawing.Color]::FromArgb(224, 108, 117)

	function Style-Button($b)
	{
		$b.FlatStyle = 'Flat'
		$b.BackColor = $cBtn
		$b.ForeColor = $cText
		$b.FlatAppearance.BorderColor = $cBorder
		$b.FlatAppearance.MouseOverBackColor = $cAccent
	}
	function Style-TextBox($tb)
	{
		$tb.BackColor = $cWindow
		$tb.ForeColor = $cText
		$tb.BorderStyle = 'FixedSingle'
	}

	function ConvertTo-DataTable
	{
		param ([Parameter(ValueFromPipeline = $true)]$InputObject)
		begin { $dt = New-Object System.Data.DataTable; $first = $true }
		process
		{
			foreach ($obj in $InputObject)
			{
				if ($first)
				{
					foreach ($p in $obj.PSObject.Properties) { $dt.Columns.Add($p.Name, [string]) | Out-Null }
					$first = $false
				}
				$row = $dt.NewRow()
				foreach ($p in $obj.PSObject.Properties) { $row[$p.Name] = if ($null -eq $p.Value) { '' } else { "$($p.Value)" } }
				$dt.Rows.Add($row)
			}
		}
		end { return , $dt }
	}

	# --- Main form ---------------------------------------------------------------
	$form = New-Object System.Windows.Forms.Form
	$form.Text = 'sqmDataTransfer'
	$form.Size = New-Object System.Drawing.Size(980, 860)
	$form.StartPosition = 'CenterScreen'
	$form.BackColor = $cPanel
	$form.ForeColor = $cText
	$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
	$form.MinimumSize = New-Object System.Drawing.Size(820, 600)

	# --- Helper: instance/database/credential panel -------------------------------
	function New-InstancePanel($title, $x, $y, $width)
	{
		$grp = New-Object System.Windows.Forms.GroupBox
		$grp.Text = $title
		$grp.ForeColor = $cText
		$grp.Location = New-Object System.Drawing.Point($x, $y)
		$grp.Size = New-Object System.Drawing.Size($width, 175)
		$grp.Anchor = 'Top,Left,Right'

		$lblInst = New-Object System.Windows.Forms.Label
		$lblInst.Text = 'Instanz:'
		$lblInst.Location = New-Object System.Drawing.Point(10, 25)
		$lblInst.Size = New-Object System.Drawing.Size(90, 20)
		$lblInst.ForeColor = $cDim
		$txtInst = New-Object System.Windows.Forms.TextBox
		Style-TextBox $txtInst
		$txtInst.Location = New-Object System.Drawing.Point(105, 22)
		$txtInst.Size = New-Object System.Drawing.Size(($width - 120), 22)
		$txtInst.Anchor = 'Top,Left,Right'

		$lblDb = New-Object System.Windows.Forms.Label
		$lblDb.Text = 'Datenbank:'
		$lblDb.Location = New-Object System.Drawing.Point(10, 52)
		$lblDb.Size = New-Object System.Drawing.Size(90, 20)
		$lblDb.ForeColor = $cDim
		$txtDb = New-Object System.Windows.Forms.TextBox
		Style-TextBox $txtDb
		$txtDb.Location = New-Object System.Drawing.Point(105, 49)
		$txtDb.Size = New-Object System.Drawing.Size(($width - 120), 22)
		$txtDb.Anchor = 'Top,Left,Right'

		$chkSqlAuth = New-Object System.Windows.Forms.CheckBox
		$chkSqlAuth.Text = 'SQL-Authentifizierung'
		$chkSqlAuth.ForeColor = $cText
		$chkSqlAuth.Location = New-Object System.Drawing.Point(10, 78)
		$chkSqlAuth.Size = New-Object System.Drawing.Size(180, 22)

		$lblUser = New-Object System.Windows.Forms.Label
		$lblUser.Text = 'Login:'
		$lblUser.Location = New-Object System.Drawing.Point(10, 105)
		$lblUser.Size = New-Object System.Drawing.Size(90, 20)
		$lblUser.ForeColor = $cDim
		$txtUser = New-Object System.Windows.Forms.TextBox
		Style-TextBox $txtUser
		$txtUser.Location = New-Object System.Drawing.Point(105, 102)
		$txtUser.Size = New-Object System.Drawing.Size(($width - 120), 22)
		$txtUser.Anchor = 'Top,Left,Right'
		$txtUser.Enabled = $false

		$lblPass = New-Object System.Windows.Forms.Label
		$lblPass.Text = 'Passwort:'
		$lblPass.Location = New-Object System.Drawing.Point(10, 132)
		$lblPass.Size = New-Object System.Drawing.Size(90, 20)
		$lblPass.ForeColor = $cDim
		$txtPass = New-Object System.Windows.Forms.TextBox
		Style-TextBox $txtPass
		$txtPass.Location = New-Object System.Drawing.Point(105, 129)
		$txtPass.Size = New-Object System.Drawing.Size(($width - 120), 22)
		$txtPass.Anchor = 'Top,Left,Right'
		$txtPass.UseSystemPasswordChar = $true
		$txtPass.Enabled = $false

		$chkSqlAuth.Add_CheckedChanged({
				$txtUser.Enabled = $chkSqlAuth.Checked
				$txtPass.Enabled = $chkSqlAuth.Checked
			}.GetNewClosure())

		$grp.Controls.AddRange(@($lblInst, $txtInst, $lblDb, $txtDb, $chkSqlAuth, $lblUser, $txtUser, $lblPass, $txtPass))

		[PSCustomObject]@{
			GroupBox = $grp
			Instance = $txtInst
			Database = $txtDb
			SqlAuth  = $chkSqlAuth
			User	 = $txtUser
			Pass	 = $txtPass
		}
	}

	$srcPanel = New-InstancePanel 'Quelle (Source)' 12 12 460
	$dstPanel = New-InstancePanel 'Ziel (Destination)' 490 12 460
	$form.Controls.Add($srcPanel.GroupBox)
	$form.Controls.Add($dstPanel.GroupBox)

	function Get-CredentialFromPanel($panel)
	{
		if ($panel.SqlAuth.Checked -and $panel.User.Text)
		{
			$securePass = ConvertTo-SecureString $panel.Pass.Text -AsPlainText -Force
			return New-Object System.Management.Automation.PSCredential($panel.User.Text, $securePass)
		}
		return $null
	}

	# --- Table list + Load button --------------------------------------------------
	$lblTables = New-Object System.Windows.Forms.Label
	$lblTables.Text = 'Tabellen (aus Quelle laden, dann auswaehlen):'
	$lblTables.Location = New-Object System.Drawing.Point(12, 196)
	$lblTables.Size = New-Object System.Drawing.Size(340, 20)
	$lblTables.ForeColor = $cDim

	$btnLoadTables = New-Object System.Windows.Forms.Button
	$btnLoadTables.Text = 'Tabellen laden'
	Style-Button $btnLoadTables
	$btnLoadTables.Location = New-Object System.Drawing.Point(830, 192)
	$btnLoadTables.Size = New-Object System.Drawing.Size(120, 26)
	$btnLoadTables.Anchor = 'Top,Right'

	$clbTables = New-Object System.Windows.Forms.CheckedListBox
	$clbTables.Location = New-Object System.Drawing.Point(12, 220)
	$clbTables.Size = New-Object System.Drawing.Size(938, 110)
	$clbTables.Anchor = 'Top,Left,Right'
	$clbTables.BackColor = $cWindow
	$clbTables.ForeColor = $cText
	$clbTables.CheckOnClick = $true
	$clbTables.BorderStyle = 'FixedSingle'

	$form.Controls.AddRange(@($lblTables, $btnLoadTables, $clbTables))

	$btnLoadTables.Add_Click({
			$clbTables.Items.Clear()
			try
			{
				$connParams = @{ SqlInstance = $srcPanel.Instance.Text; Database = $srcPanel.Database.Text; ErrorAction = 'Stop' }
				$cred = Get-CredentialFromPanel $srcPanel
				if ($cred) { $connParams['SqlCredential'] = $cred }
				$tables = Get-DbaDbTable @connParams | Sort-Object Schema, Name
				foreach ($tbl in $tables) { $clbTables.Items.Add("$($tbl.Schema).$($tbl.Name)") | Out-Null }
				if ($clbTables.Items.Count -eq 0)
				{
					[System.Windows.Forms.MessageBox]::Show('Keine Tabellen in dieser Datenbank gefunden.', 'sqmDataTransfer', 'OK', 'Information') | Out-Null
				}
			}
			catch
			{
				[System.Windows.Forms.MessageBox]::Show("Tabellen konnten nicht geladen werden:`n$($_.Exception.Message)", 'sqmDataTransfer', 'OK', 'Error') | Out-Null
			}
		})

	# --- Options ---------------------------------------------------------------
	$grpOpt = New-Object System.Windows.Forms.GroupBox
	$grpOpt.Text = 'Optionen'
	$grpOpt.ForeColor = $cText
	$grpOpt.Location = New-Object System.Drawing.Point(12, 340)
	$grpOpt.Size = New-Object System.Drawing.Size(938, 140)
	$grpOpt.Anchor = 'Top,Left,Right'

	$chkScriptMeta = New-Object System.Windows.Forms.CheckBox
	$chkScriptMeta.Text = 'Fehlende Tabellen aus Quellmetadaten auf Ziel anlegen'
	$chkScriptMeta.ForeColor = $cText
	$chkScriptMeta.Location = New-Object System.Drawing.Point(15, 25)
	$chkScriptMeta.Size = New-Object System.Drawing.Size(360, 22)

	$chkFks = New-Object System.Windows.Forms.CheckBox
	$chkFks.Text = 'Foreign Keys ein-/ausschalten'
	$chkFks.ForeColor = $cText
	$chkFks.Checked = $true
	$chkFks.Location = New-Object System.Drawing.Point(15, 50)
	$chkFks.Size = New-Object System.Drawing.Size(230, 22)

	$chkIdx = New-Object System.Windows.Forms.CheckBox
	$chkIdx.Text = 'Indizes ein-/ausschalten'
	$chkIdx.ForeColor = $cText
	$chkIdx.Checked = $true
	$chkIdx.Location = New-Object System.Drawing.Point(15, 75)
	$chkIdx.Size = New-Object System.Drawing.Size(230, 22)

	$chkKeepIdentity = New-Object System.Windows.Forms.CheckBox
	$chkKeepIdentity.Text = 'Identity-Werte der Quelle beibehalten (KeepIdentity)'
	$chkKeepIdentity.ForeColor = $cText
	$chkKeepIdentity.Checked = $true
	$chkKeepIdentity.Location = New-Object System.Drawing.Point(15, 100)
	$chkKeepIdentity.Size = New-Object System.Drawing.Size(360, 22)

	$chkTruncate = New-Object System.Windows.Forms.CheckBox
	$chkTruncate.Text = 'Zieltabelle vor Kopie leeren (TRUNCATE)'
	$chkTruncate.ForeColor = $cText
	$chkTruncate.Location = New-Object System.Drawing.Point(390, 25)
	$chkTruncate.Size = New-Object System.Drawing.Size(300, 22)

	$chkRevalidate = New-Object System.Windows.Forms.CheckBox
	$chkRevalidate.Text = 'FKs nach Aktivierung neu validieren (WITH CHECK)'
	$chkRevalidate.ForeColor = $cText
	$chkRevalidate.Checked = $true
	$chkRevalidate.Location = New-Object System.Drawing.Point(390, 50)
	$chkRevalidate.Size = New-Object System.Drawing.Size(340, 22)

	$chkWhatIf = New-Object System.Windows.Forms.CheckBox
	$chkWhatIf.Text = 'Nur simulieren (WhatIf)'
	$chkWhatIf.ForeColor = $cWarn
	$chkWhatIf.Location = New-Object System.Drawing.Point(390, 75)
	$chkWhatIf.Size = New-Object System.Drawing.Size(230, 22)

	$lblBatch = New-Object System.Windows.Forms.Label
	$lblBatch.Text = 'Batchgroesse:'
	$lblBatch.Location = New-Object System.Drawing.Point(740, 27)
	$lblBatch.Size = New-Object System.Drawing.Size(90, 20)
	$lblBatch.ForeColor = $cDim
	$numBatch = New-Object System.Windows.Forms.NumericUpDown
	$numBatch.Location = New-Object System.Drawing.Point(740, 50)
	$numBatch.Size = New-Object System.Drawing.Size(100, 22)
	$numBatch.Minimum = 1000
	$numBatch.Maximum = 1000000
	$numBatch.Increment = 5000
	$numBatch.Value = [decimal](Get-sqmTransferConfig -Key 'DefaultBatchSize')
	$numBatch.BackColor = $cWindow
	$numBatch.ForeColor = $cText

	$grpOpt.Controls.AddRange(@($chkScriptMeta, $chkFks, $chkIdx, $chkKeepIdentity, $chkTruncate, $chkRevalidate, $chkWhatIf, $lblBatch, $numBatch))
	$form.Controls.Add($grpOpt)

	# --- HTML report options -----------------------------------------------------
	# Ein Bericht wird nach jedem Lauf immer erzeugt (wie bei sqmSQLTool) - hier laesst sich nur
	# der Zielordner ueberschreiben und das automatische Oeffnen abschalten (-NoOpen).
	$grpReport = New-Object System.Windows.Forms.GroupBox
	$grpReport.Text = 'HTML-Bericht (wird immer erzeugt)'
	$grpReport.ForeColor = $cText
	$grpReport.Location = New-Object System.Drawing.Point(12, 490)
	$grpReport.Size = New-Object System.Drawing.Size(938, 58)
	$grpReport.Anchor = 'Top,Left,Right'

	$lblReportPath = New-Object System.Windows.Forms.Label
	$lblReportPath.Text = 'Zielordner:'
	$lblReportPath.Location = New-Object System.Drawing.Point(15, 27)
	$lblReportPath.Size = New-Object System.Drawing.Size(90, 20)
	$lblReportPath.ForeColor = $cDim

	$txtReportPath = New-Object System.Windows.Forms.TextBox
	Style-TextBox $txtReportPath
	$txtReportPath.Location = New-Object System.Drawing.Point(110, 24)
	$txtReportPath.Size = New-Object System.Drawing.Size(640, 22)
	$txtReportPath.Anchor = 'Top,Left,Right'
	$txtReportPath.Text = Get-sqmTransferConfig -Key 'OutputPath'

	$btnBrowseReport = New-Object System.Windows.Forms.Button
	$btnBrowseReport.Text = '...'
	Style-Button $btnBrowseReport
	$btnBrowseReport.Location = New-Object System.Drawing.Point(755, 22)
	$btnBrowseReport.Size = New-Object System.Drawing.Size(40, 24)
	$btnBrowseReport.Anchor = 'Top,Right'
	$btnBrowseReport.Add_Click({
			$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
			$dlg.SelectedPath = $txtReportPath.Text
			if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtReportPath.Text = $dlg.SelectedPath }
		})

	$chkNoOpen = New-Object System.Windows.Forms.CheckBox
	$chkNoOpen.Text = 'Nicht automatisch oeffnen'
	$chkNoOpen.ForeColor = $cText
	$chkNoOpen.Checked = $false
	$chkNoOpen.Location = New-Object System.Drawing.Point(805, 26)
	$chkNoOpen.Size = New-Object System.Drawing.Size(130, 22)
	$chkNoOpen.Anchor = 'Top,Right'

	$grpReport.Controls.AddRange(@($lblReportPath, $txtReportPath, $btnBrowseReport, $chkNoOpen))
	$form.Controls.Add($grpReport)

	# --- Run / Close buttons ------------------------------------------------------
	$btnRun = New-Object System.Windows.Forms.Button
	$btnRun.Text = 'Transfer starten'
	Style-Button $btnRun
	$btnRun.BackColor = $cAccent
	$btnRun.Location = New-Object System.Drawing.Point(12, 560)
	$btnRun.Size = New-Object System.Drawing.Size(160, 32)

	$btnClose = New-Object System.Windows.Forms.Button
	$btnClose.Text = 'Schliessen'
	Style-Button $btnClose
	$btnClose.Location = New-Object System.Drawing.Point(182, 560)
	$btnClose.Size = New-Object System.Drawing.Size(100, 32)
	$btnClose.Add_Click({ $form.Close() })

	$lblStatus = New-Object System.Windows.Forms.Label
	$lblStatus.Text = ''
	$lblStatus.Location = New-Object System.Drawing.Point(300, 566)
	$lblStatus.Size = New-Object System.Drawing.Size(650, 22)
	$lblStatus.Anchor = 'Top,Left,Right'
	$lblStatus.ForeColor = $cDim

	$form.Controls.AddRange(@($btnRun, $btnClose, $lblStatus))

	# --- Log output ----------------------------------------------------------------
	$lblLog = New-Object System.Windows.Forms.Label
	$lblLog.Text = 'Protokoll:'
	$lblLog.Location = New-Object System.Drawing.Point(12, 600)
	$lblLog.Size = New-Object System.Drawing.Size(200, 20)
	$lblLog.ForeColor = $cDim

	$txtLog = New-Object System.Windows.Forms.TextBox
	$txtLog.Location = New-Object System.Drawing.Point(12, 622)
	$txtLog.Size = New-Object System.Drawing.Size(938, 90)
	$txtLog.Anchor = 'Top,Left,Right'
	$txtLog.Multiline = $true
	$txtLog.ScrollBars = 'Vertical'
	$txtLog.ReadOnly = $true
	$txtLog.BackColor = $cWindow
	$txtLog.ForeColor = $cText
	$txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)

	$form.Controls.AddRange(@($lblLog, $txtLog))

	# --- Result grid -----------------------------------------------------------
	$lblGrid = New-Object System.Windows.Forms.Label
	$lblGrid.Text = 'Ergebnis (je Tabelle/Schritt):'
	$lblGrid.Location = New-Object System.Drawing.Point(12, 718)
	$lblGrid.Size = New-Object System.Drawing.Size(300, 20)
	$lblGrid.ForeColor = $cDim
	$lblGrid.Anchor = 'Bottom,Left'

	$dgv = New-Object System.Windows.Forms.DataGridView
	$dgv.Location = New-Object System.Drawing.Point(12, 740)
	$dgv.Size = New-Object System.Drawing.Size(938, 70)
	$dgv.Anchor = 'Bottom,Top,Left,Right'
	$dgv.BackgroundColor = $cWindow
	$dgv.ForeColor = [System.Drawing.Color]::Black
	$dgv.ReadOnly = $true
	$dgv.AllowUserToAddRows = $false
	$dgv.AllowUserToDeleteRows = $false
	$dgv.RowHeadersVisible = $false
	$dgv.AutoSizeColumnsMode = 'Fill'
	$dgv.SelectionMode = 'FullRowSelect'

	$form.Controls.AddRange(@($lblGrid, $dgv))

	# --- Run handler -----------------------------------------------------------
	$btnRun.Add_Click({
			$selectedTables = @($clbTables.CheckedItems)
			if ($selectedTables.Count -eq 0)
			{
				[System.Windows.Forms.MessageBox]::Show('Bitte mindestens eine Tabelle auswaehlen.', 'sqmDataTransfer', 'OK', 'Warning') | Out-Null
				return
			}
			if (-not $srcPanel.Instance.Text -or -not $srcPanel.Database.Text -or -not $dstPanel.Instance.Text -or -not $dstPanel.Database.Text)
			{
				[System.Windows.Forms.MessageBox]::Show('Bitte Quelle und Ziel (Instanz + Datenbank) angeben.', 'sqmDataTransfer', 'OK', 'Warning') | Out-Null
				return
			}

			$btnRun.Enabled = $false
			$lblStatus.Text = 'Transfer laeuft...'
			$txtLog.Clear()
			$dgv.DataSource = $null
			$form.Refresh()
			[System.Windows.Forms.Application]::DoEvents()

			try
			{
				$params = @{
					Source			      = $srcPanel.Instance.Text
					SourceDatabase	      = $srcPanel.Database.Text
					Destination		      = $dstPanel.Instance.Text
					DestinationDatabase   = $dstPanel.Database.Text
					Table				  = $selectedTables
					ScriptMetadata	      = $chkScriptMeta.Checked
					IncludeForeignKeys    = $chkFks.Checked
					IncludeIndexes	      = $chkIdx.Checked
					SkipConstraintHandling = (-not $chkFks.Checked -and -not $chkIdx.Checked)
					RevalidateForeignKeys = $chkRevalidate.Checked
					Truncate			  = $chkTruncate.Checked
					KeepIdentity	      = $chkKeepIdentity.Checked
					BatchSize		      = [int]$numBatch.Value
					ContinueOnError	      = $true
					Confirm			      = $false
					WhatIf			      = $chkWhatIf.Checked
				}
				if ($txtReportPath.Text) { $params['OutputPath'] = $txtReportPath.Text }
				$params['NoOpen'] = $chkNoOpen.Checked

				$results = Invoke-sqmTableTransfer @params

				$dgv.DataSource = ($results | ConvertTo-DataTable)

				$failCount = @($results | Where-Object Status -in @('Failed', 'Mismatch', 'NotFound')).Count
				$lblStatus.ForeColor = if ($failCount -gt 0) { $cErr } else { $cOk }
				$lblStatus.Text = "Fertig - $($results.Count) Schritt(e), $failCount mit Fehler/Mismatch/NotFound."

				# Tagesaktuelle Logdatei fuer diese Funktion anzeigen
				try
				{
					$logPath = Get-sqmTransferConfig -Key 'LogPath'
					$logFile = Join-Path $logPath "sqmDataTransfer_$(Get-Date -Format 'yyyyMMdd')_Invoke-sqmTableTransfer.log"
					if (Test-Path $logFile)
					{
						$txtLog.Text = (Get-Content $logFile -Tail 500 -ErrorAction SilentlyContinue) -join "`r`n"
						$txtLog.SelectionStart = $txtLog.Text.Length
						$txtLog.ScrollToCaret()
					}
				}
				catch { }
			}
			catch
			{
				$lblStatus.ForeColor = $cErr
				$lblStatus.Text = 'Fehler beim Transfer.'
				[System.Windows.Forms.MessageBox]::Show("Transfer fehlgeschlagen:`n$($_.Exception.Message)", 'sqmDataTransfer', 'OK', 'Error') | Out-Null
			}
			finally
			{
				$btnRun.Enabled = $true
			}
		})

	[void]$form.ShowDialog()
}
