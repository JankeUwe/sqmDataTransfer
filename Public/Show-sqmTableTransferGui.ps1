<#
.SYNOPSIS
    Launches a graphical interface (WinForms) for sqmDataTransfer.

.DESCRIPTION
    Lets the user connect to a source and target instance (Verbinden button tests connectivity
    and fills the database dropdown), load tables from the source (showing for each whether it
    already exists on the target - Transfer - or needs to be created - Anlegen), select tables
    (individually, or via Alle/Keine), see the source row count for any checked table, choose
    transfer options (script+create missing tables, disable/enable FKs and indexes, truncate,
    revalidate FKs on re-enable, batch size, simulate/WhatIf, skip already-complete tables to
    resume an interrupted run) and run Invoke-sqmTableTransfer.
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

	# Bruecke fuer New-InstancePanel's Klick-Handler (siehe dort): $script: bindet sich in
	# einem per Modul (Get-ChildItem | ForEach-Object { . $_.FullName }) geladenen Skript NICHT
	# zuverlaessig an den echten Modul-Scope - verifiziert per Repro (funktioniert isoliert,
	# schlaegt aber exakt mit diesem Lademechanismus fehl). $Global: ist das einzige Scope, das
	# in beiden Faellen zuverlaessig funktioniert; ein einzelnes, klar benanntes Kontextobjekt
	# haelt den globalen Namensraum sauber. Wird am Ende der Funktion wieder entfernt.
	#
	# Aus demselben Grund wird hier auch eine direkte Referenz auf Get-sqmTransferString (eine
	# private Modul-Funktion) mitgegeben: ein unqualifizierter Aufruf des Funktionsnamens aus
	# einem .GetNewClosure()-Handler heraus, der ueber ein echtes WinForms-Click-Event (nicht per
	# direktem PowerShell-Aufruf) feuert, findet die Funktion nicht ("nicht erkannt") - reproduziert
	# per echtem Mausklick auf den fertig geladenen Modul-Dialog. Der per ${function:...}
	# eingefangene ScriptBlock wird stattdessen ueber & aufgerufen und umgeht die fehlgeschlagene
	# Namensaufloesung komplett.
	$Global:__sqmDataTransferGuiCtx = [PSCustomObject]@{
		cDim = $cDim; cOk = $cOk; cErr = $cErr; Form = $null
		GetString = ${function:Get-sqmTransferString}
	}

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

	# Kopierbarer Bestaetigungsdialog fuer die Grosse-Tabelle-Warnung (siehe btnRun-Handler unten) -
	# eine normale MessageBox erlaubt zwar Strg+C, kopiert dabei aber den kompletten Dialogtext
	# (Intro + jede Tabelle + Frage) statt nur der eigentlichen Befehlszeilen. Diese Textbox zeigt
	# denselben Text zum Lesen, der Copy-Button legt aber NUR die reinen Befehle in die
	# Zwischenablage - fertig zum Einfuegen in PowerShell, ohne Nacharbeit.
	function Show-LargeTableCopyDialog($introText, [string[]]$displayBlocks, [string[]]$commandsOnly)
	{
		$dlg = New-Object System.Windows.Forms.Form
		$dlg.Text = Get-sqmTransferString -Key 'Gui.MessageBoxTitle'
		$dlg.Size = New-Object System.Drawing.Size(760, 420)
		$dlg.StartPosition = 'CenterParent'
		$dlg.FormBorderStyle = 'FixedDialog'
		$dlg.MaximizeBox = $false
		$dlg.MinimizeBox = $false
		$dlg.BackColor = $cPanel
		$dlg.ForeColor = $cText
		$dlg.Font = $form.Font

		$lblIntro = New-Object System.Windows.Forms.Label
		$lblIntro.Text = $introText
		$lblIntro.ForeColor = $cText
		$lblIntro.Location = New-Object System.Drawing.Point(15, 15)
		$lblIntro.Size = New-Object System.Drawing.Size(715, 40)

		$txtCommands = New-Object System.Windows.Forms.TextBox
		$txtCommands.Multiline = $true
		$txtCommands.ReadOnly = $true
		$txtCommands.ScrollBars = 'Both'
		$txtCommands.WordWrap = $false
		$txtCommands.Location = New-Object System.Drawing.Point(15, 60)
		$txtCommands.Size = New-Object System.Drawing.Size(715, 210)
		$txtCommands.Text = ($displayBlocks -join "`r`n`r`n")
		Style-TextBox $txtCommands

		$lblQuestion = New-Object System.Windows.Forms.Label
		$lblQuestion.Text = Get-sqmTransferString -Key 'Gui.LargeTableWarningQuestion'
		$lblQuestion.ForeColor = $cText
		$lblQuestion.Location = New-Object System.Drawing.Point(15, 278)
		$lblQuestion.Size = New-Object System.Drawing.Size(715, 36)

		$btnCopy = New-Object System.Windows.Forms.Button
		$btnCopy.Text = Get-sqmTransferString -Key 'Gui.CopyToClipboard'
		Style-Button $btnCopy
		$btnCopy.Location = New-Object System.Drawing.Point(15, 320)
		$btnCopy.Size = New-Object System.Drawing.Size(190, 30)
		$btnCopy.Add_Click({ [System.Windows.Forms.Clipboard]::SetText(($commandsOnly -join "`r`n")) }.GetNewClosure())

		$btnContinue = New-Object System.Windows.Forms.Button
		$btnContinue.Text = Get-sqmTransferString -Key 'Gui.ContinueAnyway'
		Style-Button $btnContinue
		$btnContinue.Location = New-Object System.Drawing.Point(420, 320)
		$btnContinue.Size = New-Object System.Drawing.Size(150, 30)
		$btnContinue.DialogResult = [System.Windows.Forms.DialogResult]::Yes

		$btnCancel = New-Object System.Windows.Forms.Button
		$btnCancel.Text = Get-sqmTransferString -Key 'Gui.Cancel'
		Style-Button $btnCancel
		$btnCancel.Location = New-Object System.Drawing.Point(580, 320)
		$btnCancel.Size = New-Object System.Drawing.Size(150, 30)
		$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::No

		$dlg.AcceptButton = $btnContinue
		$dlg.CancelButton = $btnCancel
		$dlg.Controls.AddRange(@($lblIntro, $txtCommands, $lblQuestion, $btnCopy, $btnContinue, $btnCancel))

		$result = $dlg.ShowDialog($form)
		$dlg.Dispose()
		return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
	}

	# Ueber-Dialog - gleiche Konvention wie die AboutForm.cs der C#-Schwestertools (SqlRefactorAnalyzer,
	# SsisAnalyzer): Name fett, Version darunter gedimmt, kurze Beschreibung, Copyright-Zeile,
	# klickbarer Link auf powershelldba.de (Start-Process statt der C#-Variante ProcessStartInfo).
	function Show-AboutDialog
	{
		$dlg = New-Object System.Windows.Forms.Form
		$dlg.Text = Get-sqmTransferString -Key 'Gui.AboutTitle'
		$dlg.Size = New-Object System.Drawing.Size(460, 280)
		$dlg.StartPosition = 'CenterParent'
		$dlg.FormBorderStyle = 'FixedDialog'
		$dlg.MaximizeBox = $false
		$dlg.MinimizeBox = $false
		$dlg.BackColor = $cPanel
		$dlg.ForeColor = $cText
		$dlg.Font = $form.Font

		$lblName = New-Object System.Windows.Forms.Label
		$lblName.Text = 'sqmDataTransfer'
		$lblName.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
		$lblName.ForeColor = $cText
		$lblName.AutoSize = $true
		$lblName.Location = New-Object System.Drawing.Point(20, 20)

		$lblVersion = New-Object System.Windows.Forms.Label
		$lblVersion.Text = "Version $(Get-sqmTransferConfig -Key 'ModuleVersion')"
		$lblVersion.ForeColor = $cDim
		$lblVersion.AutoSize = $true
		$lblVersion.Location = New-Object System.Drawing.Point(22, 54)

		$lblDesc = New-Object System.Windows.Forms.Label
		$lblDesc.Text = Get-sqmTransferString -Key 'Gui.AboutDescription'
		$lblDesc.ForeColor = $cText
		$lblDesc.Location = New-Object System.Drawing.Point(20, 84)
		$lblDesc.Size = New-Object System.Drawing.Size(410, 80)

		$aboutYearSpan = "2026-$((Get-Date).ToString('yy'))"
		$lblCopyright = New-Object System.Windows.Forms.Label
		$lblCopyright.Text = "(c) dtcSoftware - Uwe Janke $aboutYearSpan"
		$lblCopyright.ForeColor = $cDim
		$lblCopyright.AutoSize = $true
		$lblCopyright.Location = New-Object System.Drawing.Point(22, 172)

		$lnkSite = New-Object System.Windows.Forms.LinkLabel
		$lnkSite.Text = 'www.powershelldba.de'
		$lnkSite.LinkColor = $cAccent
		$lnkSite.ActiveLinkColor = [System.Drawing.Color]::FromArgb(120, 180, 230)
		$lnkSite.VisitedLinkColor = $cAccent
		$lnkSite.AutoSize = $true
		$lnkSite.Location = New-Object System.Drawing.Point(22, 194)
		$lnkSite.Add_LinkClicked({
				try { Start-Process 'https://www.powershelldba.de' } catch { }
			})

		$btnCloseAbout = New-Object System.Windows.Forms.Button
		$btnCloseAbout.Text = Get-sqmTransferString -Key 'Gui.CloseButton'
		Style-Button $btnCloseAbout
		$btnCloseAbout.Location = New-Object System.Drawing.Point(320, 210)
		$btnCloseAbout.Size = New-Object System.Drawing.Size(110, 30)
		$btnCloseAbout.DialogResult = [System.Windows.Forms.DialogResult]::OK

		$dlg.AcceptButton = $btnCloseAbout
		$dlg.Controls.AddRange(@($lblName, $lblVersion, $lblDesc, $lblCopyright, $lnkSite, $btnCloseAbout))
		[void]$dlg.ShowDialog($form)
		$dlg.Dispose()
	}

	# Faerbt/beschriftet eine Tabellen-Grid-Zeile anhand eines Compare-sqmDatabaseRowCount-Status
	# (oder $null, wenn das Ziel beim Laden nicht erreichbar war - dann bleibt der bisherige
	# "Unbekannt"-Zustand erhalten). 'Match' = bereits fertig uebertragen: Haekchen raus, gruen
	# markiert und von "Alle" ausgenommen (siehe $btnSelectAll), damit ein Wiederholungslauf auf
	# einem grossen Tabellen-Set nicht versehentlich schon fertige Tabellen erneut anfasst.
	$doneBackColor = [System.Drawing.Color]::FromArgb(210, 240, 220)
	$doneForeColor = [System.Drawing.Color]::FromArgb(20, 90, 50)
	function Set-TableGridRowStatus($row, $cmp)
	{
		$isDone = $cmp -and $cmp.Status -eq 'Match'
		$action = if (-not $cmp) { Get-sqmTransferString -Key 'Gui.ActionUnknown' }
		elseif ($isDone) { Get-sqmTransferString -Key 'Gui.ActionDone' }
		elseif ($cmp.Status -eq 'MissingOnDestination') { Get-sqmTransferString -Key 'Gui.ActionCreate' }
		else { Get-sqmTransferString -Key 'Gui.ActionTransfer' }

		$row.Cells[2].Value = $action
		$row.Cells[4].Value = if ($cmp -and $null -ne $cmp.DestinationRows) { "{0:N0}" -f [int64]$cmp.DestinationRows } else { '' }

		if ($isDone)
		{
			$row.Cells[0].Value = $false
			$row.Tag = 'Done'
			$row.DefaultCellStyle.BackColor = $doneBackColor
			$row.DefaultCellStyle.ForeColor = $doneForeColor
		}
		else
		{
			$row.Tag = $null
			$row.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
			$row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Black
		}
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
	# Titel-Konvention wie sqmSQLTool\Show-sqmToolGui.ps1 / SQLMigration\SQL-Migration.ps1:
	# "{Tool}  v{Version}   |   powershelldba.de - Janke (c) {yearSpan}".
	$form = New-Object System.Windows.Forms.Form
	$Global:__sqmDataTransferGuiCtx.Form = $form
	$guiYearSpan = "2026-$((Get-Date).ToString('yy'))"
	$form.Text = "$(Get-sqmTransferString -Key 'Gui.Title')  v$(Get-sqmTransferConfig -Key 'ModuleVersion')   |   powershelldba.de - Janke (c) $guiYearSpan"
	$form.Size = New-Object System.Drawing.Size(980, 926)
	$form.StartPosition = 'CenterScreen'
	$form.BackColor = $cPanel
	$form.ForeColor = $cText
	$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
	$form.MinimumSize = New-Object System.Drawing.Size(820, 640)

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
		$lblInst.Text = Get-sqmTransferString -Key 'Gui.Instance'
		$lblInst.Location = New-Object System.Drawing.Point(10, 25)
		$lblInst.Size = New-Object System.Drawing.Size(90, 20)
		$lblInst.ForeColor = $cDim
		$txtInst = New-Object System.Windows.Forms.TextBox
		Style-TextBox $txtInst
		$txtInst.Location = New-Object System.Drawing.Point(105, 22)
		$txtInst.Size = New-Object System.Drawing.Size(($width - 210), 22)
		$txtInst.Anchor = 'Top,Left,Right'

		$btnConnect = New-Object System.Windows.Forms.Button
		$btnConnect.Text = Get-sqmTransferString -Key 'Gui.Connect'
		Style-Button $btnConnect
		$btnConnect.Location = New-Object System.Drawing.Point(($width - 95), 21)
		$btnConnect.Size = New-Object System.Drawing.Size(85, 24)
		$btnConnect.Anchor = 'Top,Right'

		$lblDb = New-Object System.Windows.Forms.Label
		$lblDb.Text = Get-sqmTransferString -Key 'Gui.Database'
		$lblDb.Location = New-Object System.Drawing.Point(10, 52)
		$lblDb.Size = New-Object System.Drawing.Size(90, 20)
		$lblDb.ForeColor = $cDim
		$cmbDb = New-Object System.Windows.Forms.ComboBox
		$cmbDb.DropDownStyle = 'DropDown'
		$cmbDb.BackColor = $cWindow
		$cmbDb.ForeColor = $cText
		$cmbDb.FlatStyle = 'Flat'
		$cmbDb.Location = New-Object System.Drawing.Point(105, 49)
		$cmbDb.Size = New-Object System.Drawing.Size(($width - 120), 22)
		$cmbDb.Anchor = 'Top,Left,Right'

		$chkSqlAuth = New-Object System.Windows.Forms.CheckBox
		$chkSqlAuth.Text = Get-sqmTransferString -Key 'Gui.SqlAuth'
		$chkSqlAuth.ForeColor = $cText
		$chkSqlAuth.Location = New-Object System.Drawing.Point(10, 78)
		$chkSqlAuth.Size = New-Object System.Drawing.Size(180, 22)

		$lblConnStatus = New-Object System.Windows.Forms.Label
		$lblConnStatus.Text = ''
		$lblConnStatus.Location = New-Object System.Drawing.Point(195, 78)
		$lblConnStatus.Size = New-Object System.Drawing.Size(($width - 210), 22)
		$lblConnStatus.Anchor = 'Top,Left,Right'
		$lblConnStatus.ForeColor = $cDim
		$lblConnStatus.AutoEllipsis = $true

		$lblUser = New-Object System.Windows.Forms.Label
		$lblUser.Text = Get-sqmTransferString -Key 'Gui.Login'
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
		$lblPass.Text = Get-sqmTransferString -Key 'Gui.Password'
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

		# GetNewClosure() ist hier noetig: New-InstancePanel ist bereits zurueckgekehrt, wenn der
		# Klick spaeter feuert, und ohne GetNewClosure() findet ein Scriptblock dann seine EIGENEN
		# lokalen Variablen (hier $txtUser/$txtPass/$chkSqlAuth) nicht mehr (werden $null/leer) -
		# verifiziert per Repro. Variablen aus der Elternfunktion (Paletten-Farben, $form) muessen
		# dagegen ueber $Global:__sqmDataTransferGuiCtx laufen (siehe btnConnect unten) - $script:
		# bindet sich in einem per Modul geladenen Skript NICHT an den echten Modul-Scope.
		$chkSqlAuth.Add_CheckedChanged({
				$txtUser.Enabled = $chkSqlAuth.Checked
				$txtPass.Enabled = $chkSqlAuth.Checked
			}.GetNewClosure())

		$panel = [PSCustomObject]@{
			GroupBox = $grp
			Instance = $txtInst
			Database = $cmbDb
			SqlAuth  = $chkSqlAuth
			User	 = $txtUser
			Pass	 = $txtPass
			Status   = $lblConnStatus
		}

		$btnConnect.Add_Click({
				$ctx = $Global:__sqmDataTransferGuiCtx
				$lblConnStatus.ForeColor = $ctx.cDim
				$lblConnStatus.Text = & $ctx.GetString -Key 'Gui.Connecting'
				$ctx.Form.Refresh()
				[System.Windows.Forms.Application]::DoEvents()
				try
				{
					$connParams = @{ SqlInstance = $txtInst.Text; ErrorAction = 'Stop' }
					if ($chkSqlAuth.Checked -and $txtUser.Text)
					{
						$securePass = ConvertTo-SecureString $txtPass.Text -AsPlainText -Force
						$connParams['SqlCredential'] = New-Object System.Management.Automation.PSCredential($txtUser.Text, $securePass)
					}
					$srv = Connect-DbaInstance @connParams
					$dbNames = @(Get-DbaDatabase -SqlInstance $srv | Sort-Object Name | Select-Object -ExpandProperty Name)
					$currentText = $cmbDb.Text
					$cmbDb.Items.Clear()
					foreach ($n in $dbNames) { $cmbDb.Items.Add($n) | Out-Null }
					if ($currentText) { $cmbDb.Text = $currentText }
					$lblConnStatus.ForeColor = $ctx.cOk
					$lblConnStatus.Text = & $ctx.GetString -Key 'Gui.Connected' -FormatArgs @($dbNames.Count, $srv.VersionString)
				}
				catch
				{
					$lblConnStatus.ForeColor = $ctx.cErr
					$lblConnStatus.Text = & $ctx.GetString -Key 'Gui.ConnectError' -FormatArgs @($_.Exception.Message)
				}
			}.GetNewClosure())

		$grp.Controls.AddRange(@($lblInst, $txtInst, $btnConnect, $lblDb, $cmbDb, $chkSqlAuth, $lblConnStatus, $lblUser, $txtUser, $lblPass, $txtPass))

		$panel
	}

	$srcPanel = New-InstancePanel (Get-sqmTransferString -Key 'Gui.SourceGroup') 12 12 460
	$dstPanel = New-InstancePanel (Get-sqmTransferString -Key 'Gui.DestinationGroup') 490 12 460
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

	# --- Table list + Load/Select buttons ------------------------------------------
	$lblTables = New-Object System.Windows.Forms.Label
	$lblTables.Text = Get-sqmTransferString -Key 'Gui.Tables'
	$lblTables.Location = New-Object System.Drawing.Point(12, 196)
	$lblTables.Size = New-Object System.Drawing.Size(70, 20)
	$lblTables.ForeColor = $cDim

	$btnSelectAll = New-Object System.Windows.Forms.Button
	$btnSelectAll.Text = Get-sqmTransferString -Key 'Gui.SelectAll'
	Style-Button $btnSelectAll
	$btnSelectAll.Location = New-Object System.Drawing.Point(85, 192)
	$btnSelectAll.Size = New-Object System.Drawing.Size(65, 26)

	$btnSelectNone = New-Object System.Windows.Forms.Button
	$btnSelectNone.Text = Get-sqmTransferString -Key 'Gui.SelectNone'
	Style-Button $btnSelectNone
	$btnSelectNone.Location = New-Object System.Drawing.Point(155, 192)
	$btnSelectNone.Size = New-Object System.Drawing.Size(65, 26)

	$btnLoadTables = New-Object System.Windows.Forms.Button
	$btnLoadTables.Text = Get-sqmTransferString -Key 'Gui.LoadTables'
	Style-Button $btnLoadTables
	$btnLoadTables.Location = New-Object System.Drawing.Point(830, 192)
	$btnLoadTables.Size = New-Object System.Drawing.Size(120, 26)
	$btnLoadTables.Anchor = 'Top,Right'

	# Datenbankweiter Vergleich, unabhaengig vom geladenen Grid/den ausgewaehlten Tabellen - siehe
	# Notiz oben bei Gui.ReportPerRun: Ersatz fuer "ein Bericht pro Invoke-sqmTableTransfer-Aufruf",
	# wenn ein grosses Tabellenset einzeln (Haekchen fuer Haekchen) uebertragen wird.
	$btnCompareAll = New-Object System.Windows.Forms.Button
	$btnCompareAll.Text = Get-sqmTransferString -Key 'Gui.CompareAllButton'
	Style-Button $btnCompareAll
	$btnCompareAll.Location = New-Object System.Drawing.Point(700, 192)
	$btnCompareAll.Size = New-Object System.Drawing.Size(120, 26)
	$btnCompareAll.Anchor = 'Top,Right'

	# Standardmaessig AUS: -VerifyMismatches ist ein echter COUNT_BIG(*)-Scan fuer jede als
	# Mismatch markierte Tabelle - bei einer noch nicht abgeschlossenen grossen Tabelle (z.B.
	# waehrend eines laufenden Chunk-Transfers) kann das Stunden dauern und wuerde den Button
	# (synchron, kein Hintergrund-Thread) fuer genauso lange einfrieren. Nur fuer den finalen,
	# tatsaechlich vollstaendigen Kundenreport gezielt einschalten.
	$chkVerifyMismatches = New-Object System.Windows.Forms.CheckBox
	$chkVerifyMismatches.Text = Get-sqmTransferString -Key 'Gui.VerifyMismatches'
	$chkVerifyMismatches.ForeColor = $cText
	$chkVerifyMismatches.Location = New-Object System.Drawing.Point(240, 196)
	$chkVerifyMismatches.Size = New-Object System.Drawing.Size(450, 22)
	$chkVerifyMismatches.Checked = $false

	# Tabellen-Grid: Checkbox | Tabelle | Aktion (Anlegen/Transfer-Symbol) | Zeilen (Quelle, lazy)
	$dgvTables = New-Object System.Windows.Forms.DataGridView
	$dgvTables.Location = New-Object System.Drawing.Point(12, 220)
	$dgvTables.Size = New-Object System.Drawing.Size(938, 150)
	$dgvTables.Anchor = 'Top,Left,Right'
	$dgvTables.BackgroundColor = $cWindow
	$dgvTables.ForeColor = [System.Drawing.Color]::Black
	$dgvTables.AllowUserToAddRows = $false
	$dgvTables.AllowUserToDeleteRows = $false
	$dgvTables.RowHeadersVisible = $false
	$dgvTables.SelectionMode = 'FullRowSelect'
	$dgvTables.AutoSizeColumnsMode = 'None'
	$dgvTables.EditMode = 'EditOnEnter'

	$colChk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
	$colChk.Name = 'Chk'; $colChk.HeaderText = ''; $colChk.Width = 32
	$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
	$colName.Name = 'TableName'; $colName.HeaderText = Get-sqmTransferString -Key 'Gui.ColTable'; $colName.ReadOnly = $true
	$colName.AutoSizeMode = 'Fill'
	$colAction = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
	$colAction.Name = 'Action'; $colAction.HeaderText = Get-sqmTransferString -Key 'Gui.ColAction'; $colAction.ReadOnly = $true; $colAction.Width = 110
	$colRows = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
	$colRows.Name = 'RowCount'; $colRows.HeaderText = Get-sqmTransferString -Key 'Gui.ColRowCount'; $colRows.ReadOnly = $true; $colRows.Width = 120
	$colRows.DefaultCellStyle.Alignment = 'MiddleRight'
	$colRowsDst = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
	$colRowsDst.Name = 'RowCountDst'; $colRowsDst.HeaderText = Get-sqmTransferString -Key 'Gui.ColRowCountDst'; $colRowsDst.ReadOnly = $true; $colRowsDst.Width = 120
	$colRowsDst.DefaultCellStyle.Alignment = 'MiddleRight'

	$dgvTables.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($colChk, $colName, $colAction, $colRows, $colRowsDst))

	$form.Controls.AddRange(@($lblTables, $btnSelectAll, $btnSelectNone, $chkVerifyMismatches, $btnCompareAll, $btnLoadTables, $dgvTables))

	$btnLoadTables.Add_Click({
			$dgvTables.Rows.Clear()
			try
			{
				$srcCred = Get-CredentialFromPanel $srcPanel
				$srcConnParams = @{ SqlInstance = $srcPanel.Instance.Text; Database = $srcPanel.Database.Text; ErrorAction = 'Stop' }
				if ($srcCred) { $srcConnParams['SqlCredential'] = $srcCred }
				$tables = Get-DbaDbTable @srcConnParams | Sort-Object Schema, Name

				# Zeilenzahl-Abgleich zum Ziel (best effort - Ziel evtl. noch nicht befuellt/erreichbar).
				# Compare-sqmDatabaseRowCount liest beide Seiten ueber sys.partitions (Metadaten, kein
				# Datenscan - siehe dort) in zwei Abfragen fuer ALLE Tabellen auf einmal, unabhaengig
				# von der Tabellengroesse. Liefert nebenbei auch, ob die Zieltabelle ueberhaupt existiert.
				$dstCompareByTable = $null
				if ($dstPanel.Instance.Text -and $dstPanel.Database.Text)
				{
					try
					{
						$dstCred = Get-CredentialFromPanel $dstPanel
						$cmpResults = Compare-sqmDatabaseRowCount -Source $srcPanel.Instance.Text -SourceDatabase $srcPanel.Database.Text `
																	-Destination $dstPanel.Instance.Text -DestinationDatabase $dstPanel.Database.Text `
																	-SourceCredential $srcCred -DestinationCredential $dstCred
						$dstCompareByTable = @{}
						foreach ($c in $cmpResults) { $dstCompareByTable[$c.Table] = $c }
					}
					catch { $dstCompareByTable = $null }
				}

				foreach ($tbl in $tables)
				{
					$fullName = "$($tbl.Schema).$($tbl.Name)"
					$cmp = if ($dstCompareByTable) { $dstCompareByTable[$fullName] } else { $null }
					$rowIndex = $dgvTables.Rows.Add($false, $fullName, '', '', '')
					Set-TableGridRowStatus $dgvTables.Rows[$rowIndex] $cmp
				}
				if ($dgvTables.Rows.Count -eq 0)
				{
					[System.Windows.Forms.MessageBox]::Show((Get-sqmTransferString -Key 'Gui.NoTablesFound'), (Get-sqmTransferString -Key 'Gui.MessageBoxTitle'), 'OK', 'Information') | Out-Null
				}
			}
			catch
			{
				[System.Windows.Forms.MessageBox]::Show((Get-sqmTransferString -Key 'Gui.TablesLoadError' -FormatArgs @($_.Exception.Message)), (Get-sqmTransferString -Key 'Gui.MessageBoxTitle'), 'OK', 'Error') | Out-Null
			}
		})

	# Ein einziger konsolidierter Bericht ueber die gesamte Quelle/Ziel-Kombination - Ersatz fuer
	# "X Einzelberichte" bei tabellenweisem Vorgehen (siehe Gui.ReportPerRun unten). Nutzt immer die
	# guenstige sys.partitions-Abfrage; ob als Mismatch markierte Tabellen zusaetzlich per echtem
	# COUNT_BIG(*) exakt nachgeprueft werden, steuert die Checkbox daneben (siehe deren Kommentar -
	# standardmaessig aus, weil das bei einer noch laufenden grossen Tabelle den Button-Klick fuer
	# Stunden blockieren wuerde, da hier kein Hintergrund-Thread existiert).
	$btnCompareAll.Add_Click({
			if (-not $srcPanel.Instance.Text -or -not $srcPanel.Database.Text -or -not $dstPanel.Instance.Text -or -not $dstPanel.Database.Text)
			{
				[System.Windows.Forms.MessageBox]::Show((Get-sqmTransferString -Key 'Gui.SpecifySourceAndDest'), (Get-sqmTransferString -Key 'Gui.MessageBoxTitle'), 'OK', 'Warning') | Out-Null
				return
			}

			$btnCompareAll.Enabled = $false
			$lblStatus.ForeColor = $cDim
			$lblStatus.Text = Get-sqmTransferString -Key 'Gui.CompareAllRunning'
			$form.Refresh()
			[System.Windows.Forms.Application]::DoEvents()

			try
			{
				$srcCred = Get-CredentialFromPanel $srcPanel
				$dstCred = Get-CredentialFromPanel $dstPanel
				$cmp = Compare-sqmDatabaseRowCount -Source $srcPanel.Instance.Text -SourceDatabase $srcPanel.Database.Text `
													-Destination $dstPanel.Instance.Text -DestinationDatabase $dstPanel.Database.Text `
													-SourceCredential $srcCred -DestinationCredential $dstCred -VerifyMismatches:$chkVerifyMismatches.Checked

				$reportPath = if ($txtReportPath.Text) { $txtReportPath.Text } else { Get-sqmTransferConfig -Key 'OutputPath' }
				if (-not (Test-Path $reportPath)) { New-Item -ItemType Directory -Path $reportPath -Force | Out-Null }
				$safeSource = "$($srcPanel.Instance.Text).$($srcPanel.Database.Text)" -replace '[\\:.]', '_'
				$safeDest = "$($dstPanel.Instance.Text).$($dstPanel.Database.Text)" -replace '[\\:.]', '_'
				$datestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
				$htmlFile = Join-Path $reportPath "sqmDataTransfer_Gesamtvergleich_${safeSource}_zu_${safeDest}_${datestamp}.html"

				Export-sqmDatabaseComparisonReport -Source $srcPanel.Instance.Text -SourceDatabase $srcPanel.Database.Text `
													-Destination $dstPanel.Instance.Text -DestinationDatabase $dstPanel.Database.Text `
													-Comparison $cmp -FilePath $htmlFile -NoOpen:$chkNoOpen.Checked

				# Grid live nachziehen, falls bereits geladen - dieselbe Logik wie nach einem Transfer-Lauf.
				$cmpByTable = @{}
				foreach ($c in $cmp) { $cmpByTable[$c.Table] = $c }
				foreach ($row in $dgvTables.Rows)
				{
					$tn = $row.Cells[1].Value
					if ($cmpByTable.ContainsKey($tn)) { Set-TableGridRowStatus $row $cmpByTable[$tn] }
				}

				$openCount = @($cmp | Where-Object Status -ne 'Match').Count
				$lblStatus.ForeColor = if ($openCount -gt 0) { $cErr } else { $cOk }
				$lblStatus.Text = Get-sqmTransferString -Key 'Gui.CompareAllDone' -FormatArgs @($cmp.Count, $openCount)
			}
			catch
			{
				$lblStatus.ForeColor = $cErr
				$lblStatus.Text = Get-sqmTransferString -Key 'Gui.CompareAllError' -FormatArgs @($_.Exception.Message)
				[System.Windows.Forms.MessageBox]::Show((Get-sqmTransferString -Key 'Gui.CompareAllError' -FormatArgs @($_.Exception.Message)), (Get-sqmTransferString -Key 'Gui.MessageBoxTitle'), 'OK', 'Error') | Out-Null
			}
			finally
			{
				$btnCompareAll.Enabled = $true
			}
		})

	# Checkbox-Klicks committen erst beim Verlassen der Zelle - sofort commiten, damit
	# CellValueChanged fuer die Zeilenzahl-Abfrage direkt nach dem Klick feuert.
	$dgvTables.Add_CurrentCellDirtyStateChanged({
			if ($dgvTables.IsCurrentCellDirty -and $dgvTables.CurrentCell -is [System.Windows.Forms.DataGridViewCheckBoxCell])
			{
				$dgvTables.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
			}
		})

	# "Alle"/"Keine" setzen viele Checkboxen auf einmal - waehrenddessen keine Zeilenzahl
	# abfragen (koennte bei vielen Tabellen lange dauern); nur ein direkter Einzelklick
	# durch den Anwender loest die Lazy-Abfrage aus.
	$suppressRowCountFetch = $false

	$dgvTables.Add_CellValueChanged({
			param ($senderObj, $e)
			if ($suppressRowCountFetch -or $e.RowIndex -lt 0 -or $e.ColumnIndex -ne 0) { return }
			$row = $dgvTables.Rows[$e.RowIndex]
			if (-not [bool]$row.Cells[0].Value) { return }
			if ($row.Cells[3].Value) { return }
			$tableName = $row.Cells[1].Value
			try
			{
				$parts = $tableName -split '\.', 2
				$cred = Get-CredentialFromPanel $srcPanel
				$connParams = @{ SqlInstance = $srcPanel.Instance.Text; Database = $srcPanel.Database.Text; ErrorAction = 'Stop' }
				if ($cred) { $connParams['SqlCredential'] = $cred }
				# sys.dm_db_partition_stats statt COUNT_BIG(*) - Metadaten-Lookup statt Scan, siehe
				# Compare-sqmTableRowCount -Fast. Hier vor dem eigentlichen Transfer (Checkbox-Klick
				# zum Auswaehlen einer Tabelle), also kein aktiver Schreibvorgang, der den Zaehler
				# verfaelschen koennte. index_id IN (0,1) = Heap bzw. Clustered Index.
				$q = "SELECT SUM(row_count) AS [RowCount] FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID(N'[$($parts[0])].[$($parts[1])]') AND index_id IN (0, 1)"
				$cnt = (Invoke-DbaQuery @connParams -Query $q -As PSObject -EnableException).RowCount
				if ($null -eq $cnt) { throw "Tabelle nicht gefunden." }
				$row.Cells[3].Value = "{0:N0}" -f [int64]$cnt
			}
			catch
			{
				$row.Cells[3].Value = '?'
			}
		})

	$btnSelectAll.Add_Click({
			$suppressRowCountFetch = $true
			# Bereits fertige (gruen markierte) Tabellen werden von "Alle" ausgenommen - siehe
			# Set-TableGridRowStatus oben.
			foreach ($row in $dgvTables.Rows) { if ($row.Tag -ne 'Done') { $row.Cells[0].Value = $true } }
			$suppressRowCountFetch = $false
		})
	$btnSelectNone.Add_Click({
			$suppressRowCountFetch = $true
			foreach ($row in $dgvTables.Rows) { $row.Cells[0].Value = $false }
			$suppressRowCountFetch = $false
		})

	# --- Options ---------------------------------------------------------------
	$grpOpt = New-Object System.Windows.Forms.GroupBox
	$grpOpt.Text = Get-sqmTransferString -Key 'Gui.OptionsGroup'
	$grpOpt.ForeColor = $cText
	$grpOpt.Location = New-Object System.Drawing.Point(12, 380)
	$grpOpt.Size = New-Object System.Drawing.Size(938, 140)
	$grpOpt.Anchor = 'Top,Left,Right'

	$chkScriptMeta = New-Object System.Windows.Forms.CheckBox
	$chkScriptMeta.Text = Get-sqmTransferString -Key 'Gui.ScriptMetadata'
	$chkScriptMeta.ForeColor = $cText
	$chkScriptMeta.Location = New-Object System.Drawing.Point(15, 25)
	$chkScriptMeta.Size = New-Object System.Drawing.Size(360, 22)

	$chkFks = New-Object System.Windows.Forms.CheckBox
	$chkFks.Text = Get-sqmTransferString -Key 'Gui.ToggleFks'
	$chkFks.ForeColor = $cText
	$chkFks.Checked = $true
	$chkFks.Location = New-Object System.Drawing.Point(15, 50)
	$chkFks.Size = New-Object System.Drawing.Size(230, 22)

	$chkIdx = New-Object System.Windows.Forms.CheckBox
	$chkIdx.Text = Get-sqmTransferString -Key 'Gui.ToggleIndexes'
	$chkIdx.ForeColor = $cText
	$chkIdx.Checked = $true
	$chkIdx.Location = New-Object System.Drawing.Point(15, 75)
	$chkIdx.Size = New-Object System.Drawing.Size(230, 22)

	$chkKeepIdentity = New-Object System.Windows.Forms.CheckBox
	$chkKeepIdentity.Text = Get-sqmTransferString -Key 'Gui.KeepIdentity'
	$chkKeepIdentity.ForeColor = $cText
	$chkKeepIdentity.Checked = $true
	$chkKeepIdentity.Location = New-Object System.Drawing.Point(15, 100)
	$chkKeepIdentity.Size = New-Object System.Drawing.Size(360, 22)

	$chkTruncate = New-Object System.Windows.Forms.CheckBox
	$chkTruncate.Text = Get-sqmTransferString -Key 'Gui.Truncate'
	$chkTruncate.ForeColor = $cText
	$chkTruncate.Location = New-Object System.Drawing.Point(390, 25)
	$chkTruncate.Size = New-Object System.Drawing.Size(300, 22)

	$chkRevalidate = New-Object System.Windows.Forms.CheckBox
	$chkRevalidate.Text = Get-sqmTransferString -Key 'Gui.Revalidate'
	$chkRevalidate.ForeColor = $cText
	$chkRevalidate.Checked = $true
	$chkRevalidate.Location = New-Object System.Drawing.Point(390, 50)
	$chkRevalidate.Size = New-Object System.Drawing.Size(340, 22)

	$chkWhatIf = New-Object System.Windows.Forms.CheckBox
	$chkWhatIf.Text = Get-sqmTransferString -Key 'Gui.WhatIf'
	$chkWhatIf.ForeColor = $cWarn
	$chkWhatIf.Location = New-Object System.Drawing.Point(390, 75)
	$chkWhatIf.Size = New-Object System.Drawing.Size(230, 22)

	$chkSkipCompleted = New-Object System.Windows.Forms.CheckBox
	$chkSkipCompleted.Text = Get-sqmTransferString -Key 'Gui.SkipCompleted'
	$chkSkipCompleted.ForeColor = $cText
	$chkSkipCompleted.Location = New-Object System.Drawing.Point(390, 100)
	$chkSkipCompleted.Size = New-Object System.Drawing.Size(340, 22)

	$lblBatch = New-Object System.Windows.Forms.Label
	$lblBatch.Text = Get-sqmTransferString -Key 'Gui.BatchSize'
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

	$chkTriggers = New-Object System.Windows.Forms.CheckBox
	$chkTriggers.Text = Get-sqmTransferString -Key 'Gui.ToggleTriggers'
	$chkTriggers.ForeColor = $cText
	$chkTriggers.Checked = $true
	$chkTriggers.Location = New-Object System.Drawing.Point(740, 75)
	$chkTriggers.Size = New-Object System.Drawing.Size(185, 22)

	$grpOpt.Controls.AddRange(@($chkScriptMeta, $chkFks, $chkIdx, $chkTriggers, $chkKeepIdentity, $chkTruncate, $chkRevalidate, $chkWhatIf, $chkSkipCompleted, $lblBatch, $numBatch))
	$form.Controls.Add($grpOpt)

	# --- HTML report options -----------------------------------------------------
	# Bericht pro Invoke-sqmTableTransfer-Aufruf ist per Checkbox abschaltbar (Gui.ReportPerRun) -
	# bei tabellenweisem Vorgehen ueber ein grosses Set haeuft sich sonst ein Bericht pro Klick an,
	# ohne Gesamtueberblick. $btnCompareAll (oben beim Tabellen-Grid) liefert den Gesamtueberblick
	# stattdessen ueber einen einzigen konsolidierten Bericht.
	$grpReport = New-Object System.Windows.Forms.GroupBox
	$grpReport.Text = Get-sqmTransferString -Key 'Gui.ReportGroup'
	$grpReport.ForeColor = $cText
	$grpReport.Location = New-Object System.Drawing.Point(12, 530)
	$grpReport.Size = New-Object System.Drawing.Size(938, 84)
	$grpReport.Anchor = 'Top,Left,Right'

	$lblReportPath = New-Object System.Windows.Forms.Label
	$lblReportPath.Text = Get-sqmTransferString -Key 'Gui.ReportFolder'
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
	$btnBrowseReport.Text = Get-sqmTransferString -Key 'Gui.Browse'
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
	$chkNoOpen.Text = Get-sqmTransferString -Key 'Gui.NoAutoOpen'
	$chkNoOpen.ForeColor = $cText
	$chkNoOpen.Checked = $false
	$chkNoOpen.Location = New-Object System.Drawing.Point(805, 26)
	$chkNoOpen.Size = New-Object System.Drawing.Size(130, 22)
	$chkNoOpen.Anchor = 'Top,Right'

	$chkReportPerRun = New-Object System.Windows.Forms.CheckBox
	$chkReportPerRun.Text = Get-sqmTransferString -Key 'Gui.ReportPerRun'
	$chkReportPerRun.ForeColor = $cText
	$chkReportPerRun.Checked = $true
	$chkReportPerRun.Location = New-Object System.Drawing.Point(15, 55)
	$chkReportPerRun.Size = New-Object System.Drawing.Size(260, 22)

	$grpReport.Controls.AddRange(@($lblReportPath, $txtReportPath, $btnBrowseReport, $chkNoOpen, $chkReportPerRun))
	$form.Controls.Add($grpReport)

	# --- Run / Close buttons ------------------------------------------------------
	$btnRun = New-Object System.Windows.Forms.Button
	$btnRun.Text = Get-sqmTransferString -Key 'Gui.RunButton'
	Style-Button $btnRun
	$btnRun.BackColor = $cAccent
	$btnRun.Location = New-Object System.Drawing.Point(12, 626)
	$btnRun.Size = New-Object System.Drawing.Size(160, 32)

	$btnClose = New-Object System.Windows.Forms.Button
	$btnClose.Text = Get-sqmTransferString -Key 'Gui.CloseButton'
	Style-Button $btnClose
	$btnClose.Location = New-Object System.Drawing.Point(182, 626)
	$btnClose.Size = New-Object System.Drawing.Size(100, 32)
	$btnClose.Add_Click({ $form.Close() })

	$btnAbout = New-Object System.Windows.Forms.Button
	$btnAbout.Text = Get-sqmTransferString -Key 'Gui.AboutButton'
	Style-Button $btnAbout
	$btnAbout.Location = New-Object System.Drawing.Point(292, 626)
	$btnAbout.Size = New-Object System.Drawing.Size(90, 32)
	$btnAbout.Add_Click({ Show-AboutDialog })

	$lblStatus = New-Object System.Windows.Forms.Label
	$lblStatus.Text = ''
	$lblStatus.Location = New-Object System.Drawing.Point(392, 632)
	$lblStatus.Size = New-Object System.Drawing.Size(558, 22)
	$lblStatus.Anchor = 'Top,Left,Right'
	$lblStatus.ForeColor = $cDim

	$form.Controls.AddRange(@($btnRun, $btnClose, $btnAbout, $lblStatus))

	# --- Log output ----------------------------------------------------------------
	$lblLog = New-Object System.Windows.Forms.Label
	$lblLog.Text = Get-sqmTransferString -Key 'Gui.LogLabel'
	$lblLog.Location = New-Object System.Drawing.Point(12, 666)
	$lblLog.Size = New-Object System.Drawing.Size(200, 20)
	$lblLog.ForeColor = $cDim

	$txtLog = New-Object System.Windows.Forms.TextBox
	$txtLog.Location = New-Object System.Drawing.Point(12, 688)
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
	$lblGrid.Text = Get-sqmTransferString -Key 'Gui.ResultLabel'
	$lblGrid.Location = New-Object System.Drawing.Point(12, 784)
	$lblGrid.Size = New-Object System.Drawing.Size(300, 20)
	$lblGrid.ForeColor = $cDim
	$lblGrid.Anchor = 'Bottom,Left'

	$dgv = New-Object System.Windows.Forms.DataGridView
	$dgv.Location = New-Object System.Drawing.Point(12, 806)
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
			$selectedTables = @(foreach ($row in $dgvTables.Rows) { if ([bool]$row.Cells[0].Value) { $row.Cells[1].Value } })
			if ($selectedTables.Count -eq 0)
			{
				[System.Windows.Forms.MessageBox]::Show((Get-sqmTransferString -Key 'Gui.SelectAtLeastOneTable'), (Get-sqmTransferString -Key 'Gui.MessageBoxTitle'), 'OK', 'Warning') | Out-Null
				return
			}
			if (-not $srcPanel.Instance.Text -or -not $srcPanel.Database.Text -or -not $dstPanel.Instance.Text -or -not $dstPanel.Database.Text)
			{
				[System.Windows.Forms.MessageBox]::Show((Get-sqmTransferString -Key 'Gui.SpecifySourceAndDest'), (Get-sqmTransferString -Key 'Gui.MessageBoxTitle'), 'OK', 'Warning') | Out-Null
				return
			}

			$srcCred = Get-CredentialFromPanel $srcPanel
			$dstCred = Get-CredentialFromPanel $dstPanel

			# Grosse-Tabelle-Vorabpruefung: Invoke-sqmTableTransfer warnt zwar selbst (siehe dort),
			# aber erst NACH dem Transfer - hier VOR dem Start, damit man noch abbrechen und
			# stattdessen den vorgeschlagenen Invoke-sqmChunkedTableTransfer-Befehl in PowerShell
			# nutzen kann (die GUI selbst kann nicht chunken). Metadaten-Lookup pro ausgewaehlter
			# Tabelle, kein Scan - eine fehlgeschlagene Pruefung darf den Transfer nicht verhindern.
			try
			{
				$largeThreshold = Get-sqmTransferConfig -Key 'LargeTableRowThreshold'
				if (-not $largeThreshold) { $largeThreshold = 10000000 }
				# Nur zum Chunking raten, wenn das Ziel schon einen nennenswerten Teil der Quelle
				# enthaelt (Default 30%) - bei einem leeren/frischen Ziel bringt Chunking (dessen
				# Vorteil Resumability ist) nichts, und der normale All-or-nothing-Copy ist schneller.
				# Gleiche Logik/Begruendung wie in Invoke-sqmTableTransfer's eigener Warnung.
				$minExistingPercent = Get-sqmTransferConfig -Key 'ChunkAdviceMinExistingPercent'
				if (-not $minExistingPercent) { $minExistingPercent = 30 }
				$largeTableMessages = [System.Collections.Generic.List[string]]::new()
				$largeTableCommands = [System.Collections.Generic.List[string]]::new()
				foreach ($t in $selectedTables)
				{
					$schemaNameChk = 'dbo'; $tableNameChk = $t
					if ($t -match '^(?<schema>[^.]+)\.(?<name>.+)$') { $schemaNameChk = $Matches['schema']; $tableNameChk = $Matches['name'] }
					$sizeParams = @{ SqlInstance = $srcPanel.Instance.Text; Database = $srcPanel.Database.Text; ErrorAction = 'Stop' }
					if ($srcCred) { $sizeParams['SqlCredential'] = $srcCred }
					$rc = (Invoke-DbaQuery @sizeParams -Query "SELECT SUM(row_count) AS [RowCount] FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID(N'[$schemaNameChk].[$tableNameChk]') AND index_id IN (0, 1)" -As PSObject -EnableException).RowCount
					if ($null -ne $rc -and [int64]$rc -gt $largeThreshold)
					{
						$dstRc = $null
						try
						{
							$dstSizeParams = @{ SqlInstance = $dstPanel.Instance.Text; Database = $dstPanel.Database.Text; ErrorAction = 'Stop' }
							if ($dstCred) { $dstSizeParams['SqlCredential'] = $dstCred }
							$dstRc = (Invoke-DbaQuery @dstSizeParams -Query "SELECT SUM(row_count) AS [RowCount] FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID(N'[$schemaNameChk].[$tableNameChk]') AND index_id IN (0, 1)" -As PSObject -EnableException).RowCount
						}
						catch { $dstRc = $null }
						$existingPercent = if ($null -ne $dstRc -and [int64]$rc -gt 0) { ([int64]$dstRc / [int64]$rc) * 100 } else { 0 }

						if ($existingPercent -ge $minExistingPercent)
						{
							$suggestedCol = Get-sqmSuggestedChunkColumn -SqlInstance $srcPanel.Instance.Text -Database $srcPanel.Database.Text -Table $t -SqlCredential $srcCred
							$colText = if ($suggestedCol) { $suggestedCol } else { '<ChunkSpalte>' }
							$cmdText = "Invoke-sqmChunkedTableTransfer -Source '$($srcPanel.Instance.Text)' -SourceDatabase '$($srcPanel.Database.Text)' -Destination '$($dstPanel.Instance.Text)' -DestinationDatabase '$($dstPanel.Database.Text)' -Table '$t' -ChunkColumn '$colText'"
							$largeTableMessages.Add("$t ($('{0:N0}' -f [int64]$rc) Zeilen, Ziel bereits $('{0:N1}' -f $existingPercent)% befuellt):`r`n$cmdText")
							$largeTableCommands.Add($cmdText)
						}
					}
				}
				if ($largeTableMessages.Count -gt 0)
				{
					$proceed = Show-LargeTableCopyDialog (Get-sqmTransferString -Key 'Gui.LargeTableWarningIntro') $largeTableMessages.ToArray() $largeTableCommands.ToArray()
					if (-not $proceed) { return }
				}
			}
			catch { }

			$btnRun.Enabled = $false
			$lblStatus.Text = Get-sqmTransferString -Key 'Gui.TransferRunning'
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
					SkipCompleted	      = $chkSkipCompleted.Checked
					IncludeForeignKeys    = $chkFks.Checked
					IncludeIndexes	      = $chkIdx.Checked
					IncludeTriggers	      = $chkTriggers.Checked
					SkipConstraintHandling = (-not $chkFks.Checked -and -not $chkIdx.Checked -and -not $chkTriggers.Checked)
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
				$params['NoReport'] = -not $chkReportPerRun.Checked
				if ($srcCred) { $params['SourceCredential'] = $srcCred }
				if ($dstCred) { $params['DestinationCredential'] = $dstCred }

				$results = Invoke-sqmTableTransfer @params

				$dgv.DataSource = ($results | ConvertTo-DataTable)

				# Tabellen-Grid live nachziehen: fertig uebertragene Tabellen (Quelle = Ziel) werden
				# gruen markiert, ihr Haekchen entfernt und die Zielzeilenzahl eingetragen - damit bei
				# einem tabellenweisen Ablauf ueber mehrere Laeufe hinweg auf einen Blick erkennbar ist,
				# was schon erledigt ist. Best effort: ein Fehlschlag hier darf den Lauf nicht als
				# Ganzes als fehlgeschlagen erscheinen lassen.
				try
				{
					$refreshCmp = Compare-sqmDatabaseRowCount -Source $srcPanel.Instance.Text -SourceDatabase $srcPanel.Database.Text `
															   -Destination $dstPanel.Instance.Text -DestinationDatabase $dstPanel.Database.Text `
															   -Table $selectedTables -SourceCredential $srcCred -DestinationCredential $dstCred
					$refreshByTable = @{}
					foreach ($c in $refreshCmp) { $refreshByTable[$c.Table] = $c }
					foreach ($row in $dgvTables.Rows)
					{
						$tn = $row.Cells[1].Value
						if ($refreshByTable.ContainsKey($tn)) { Set-TableGridRowStatus $row $refreshByTable[$tn] }
					}
				}
				catch { }

				$failCount = @($results | Where-Object Status -in @('Failed', 'Mismatch', 'NotFound')).Count
				$lblStatus.ForeColor = if ($failCount -gt 0) { $cErr } else { $cOk }
				$lblStatus.Text = Get-sqmTransferString -Key 'Gui.TransferDone' -FormatArgs @($results.Count, $failCount)

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
				$lblStatus.Text = Get-sqmTransferString -Key 'Gui.TransferError'
				[System.Windows.Forms.MessageBox]::Show((Get-sqmTransferString -Key 'Gui.TransferFailedBox' -FormatArgs @($_.Exception.Message)), (Get-sqmTransferString -Key 'Gui.MessageBoxTitle'), 'OK', 'Error') | Out-Null
			}
			finally
			{
				$btnRun.Enabled = $true
			}
		})

	# Beim Oeffnen zuverlaessig in den Vordergrund holen (auch wenn aus einer
	# Hintergrund-/Terminal-Session gestartet) - TopMost kurz an/aus erzwingt das
	# Nach-vorne-Holen einmalig, ohne das Fenster dauerhaft "immer im Vordergrund" zu pinnen.
	$form.Add_Shown({
			$form.Activate()
			$form.TopMost = $true
			$form.TopMost = $false
		})

	try
	{
		[void]$form.ShowDialog()
	}
	finally
	{
		# Aufraeumen: keine Reste im globalen Namensraum nach Schliessen der GUI hinterlassen.
		Remove-Variable -Name __sqmDataTransferGuiCtx -Scope Global -ErrorAction SilentlyContinue
	}
}
