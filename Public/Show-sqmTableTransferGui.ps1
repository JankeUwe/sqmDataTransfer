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
	$Global:__sqmDataTransferGuiCtx = [PSCustomObject]@{ cDim = $cDim; cOk = $cOk; cErr = $cErr; Form = $null }

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
	$Global:__sqmDataTransferGuiCtx.Form = $form
	$form.Text = Get-sqmTransferString -Key 'Gui.Title'
	$form.Size = New-Object System.Drawing.Size(980, 900)
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
				$lblConnStatus.Text = Get-sqmTransferString -Key 'Gui.Connecting'
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
					$lblConnStatus.Text = Get-sqmTransferString -Key 'Gui.Connected' -FormatArgs @($dbNames.Count, $srv.VersionString)
				}
				catch
				{
					$lblConnStatus.ForeColor = $ctx.cErr
					$lblConnStatus.Text = Get-sqmTransferString -Key 'Gui.ConnectError' -FormatArgs @($_.Exception.Message)
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

	$dgvTables.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($colChk, $colName, $colAction, $colRows))

	$form.Controls.AddRange(@($lblTables, $btnSelectAll, $btnSelectNone, $btnLoadTables, $dgvTables))

	$btnLoadTables.Add_Click({
			$dgvTables.Rows.Clear()
			try
			{
				$srcCred = Get-CredentialFromPanel $srcPanel
				$srcConnParams = @{ SqlInstance = $srcPanel.Instance.Text; Database = $srcPanel.Database.Text; ErrorAction = 'Stop' }
				if ($srcCred) { $srcConnParams['SqlCredential'] = $srcCred }
				$tables = Get-DbaDbTable @srcConnParams | Sort-Object Schema, Name

				# Bestehende Tabellen im Ziel ermitteln (best effort - Ziel evtl. noch nicht befuellt/erreichbar)
				$dstExisting = $null
				if ($dstPanel.Instance.Text -and $dstPanel.Database.Text)
				{
					try
					{
						$dstCred = Get-CredentialFromPanel $dstPanel
						$dstConnParams = @{ SqlInstance = $dstPanel.Instance.Text; Database = $dstPanel.Database.Text; ErrorAction = 'Stop' }
						if ($dstCred) { $dstConnParams['SqlCredential'] = $dstCred }
						$dstExisting = @(Get-DbaDbTable @dstConnParams | ForEach-Object { "$($_.Schema).$($_.Name)" })
					}
					catch { $dstExisting = $null }
				}

				foreach ($tbl in $tables)
				{
					$fullName = "$($tbl.Schema).$($tbl.Name)"
					$action = if ($null -eq $dstExisting) { Get-sqmTransferString -Key 'Gui.ActionUnknown' }
					elseif ($dstExisting -contains $fullName) { Get-sqmTransferString -Key 'Gui.ActionTransfer' }
					else { Get-sqmTransferString -Key 'Gui.ActionCreate' }
					$dgvTables.Rows.Add($false, $fullName, $action, '') | Out-Null
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
				$q = "SELECT COUNT_BIG(*) AS [RowCount] FROM [$($parts[0])].[$($parts[1])]"
				$cnt = (Invoke-DbaQuery @connParams -Query $q -As PSObject -EnableException).RowCount
				$row.Cells[3].Value = "$cnt"
			}
			catch
			{
				$row.Cells[3].Value = '?'
			}
		})

	$btnSelectAll.Add_Click({
			$suppressRowCountFetch = $true
			foreach ($row in $dgvTables.Rows) { $row.Cells[0].Value = $true }
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

	$grpOpt.Controls.AddRange(@($chkScriptMeta, $chkFks, $chkIdx, $chkKeepIdentity, $chkTruncate, $chkRevalidate, $chkWhatIf, $chkSkipCompleted, $lblBatch, $numBatch))
	$form.Controls.Add($grpOpt)

	# --- HTML report options -----------------------------------------------------
	# Ein Bericht wird nach jedem Lauf immer erzeugt (wie bei sqmSQLTool) - hier laesst sich nur
	# der Zielordner ueberschreiben und das automatische Oeffnen abschalten (-NoOpen).
	$grpReport = New-Object System.Windows.Forms.GroupBox
	$grpReport.Text = Get-sqmTransferString -Key 'Gui.ReportGroup'
	$grpReport.ForeColor = $cText
	$grpReport.Location = New-Object System.Drawing.Point(12, 530)
	$grpReport.Size = New-Object System.Drawing.Size(938, 58)
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

	$grpReport.Controls.AddRange(@($lblReportPath, $txtReportPath, $btnBrowseReport, $chkNoOpen))
	$form.Controls.Add($grpReport)

	# --- Run / Close buttons ------------------------------------------------------
	$btnRun = New-Object System.Windows.Forms.Button
	$btnRun.Text = Get-sqmTransferString -Key 'Gui.RunButton'
	Style-Button $btnRun
	$btnRun.BackColor = $cAccent
	$btnRun.Location = New-Object System.Drawing.Point(12, 600)
	$btnRun.Size = New-Object System.Drawing.Size(160, 32)

	$btnClose = New-Object System.Windows.Forms.Button
	$btnClose.Text = Get-sqmTransferString -Key 'Gui.CloseButton'
	Style-Button $btnClose
	$btnClose.Location = New-Object System.Drawing.Point(182, 600)
	$btnClose.Size = New-Object System.Drawing.Size(100, 32)
	$btnClose.Add_Click({ $form.Close() })

	$lblStatus = New-Object System.Windows.Forms.Label
	$lblStatus.Text = ''
	$lblStatus.Location = New-Object System.Drawing.Point(300, 606)
	$lblStatus.Size = New-Object System.Drawing.Size(650, 22)
	$lblStatus.Anchor = 'Top,Left,Right'
	$lblStatus.ForeColor = $cDim

	$form.Controls.AddRange(@($btnRun, $btnClose, $lblStatus))

	# --- Log output ----------------------------------------------------------------
	$lblLog = New-Object System.Windows.Forms.Label
	$lblLog.Text = Get-sqmTransferString -Key 'Gui.LogLabel'
	$lblLog.Location = New-Object System.Drawing.Point(12, 640)
	$lblLog.Size = New-Object System.Drawing.Size(200, 20)
	$lblLog.ForeColor = $cDim

	$txtLog = New-Object System.Windows.Forms.TextBox
	$txtLog.Location = New-Object System.Drawing.Point(12, 662)
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
	$lblGrid.Location = New-Object System.Drawing.Point(12, 758)
	$lblGrid.Size = New-Object System.Drawing.Size(300, 20)
	$lblGrid.ForeColor = $cDim
	$lblGrid.Anchor = 'Bottom,Left'

	$dgv = New-Object System.Windows.Forms.DataGridView
	$dgv.Location = New-Object System.Drawing.Point(12, 780)
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
				$srcCred = Get-CredentialFromPanel $srcPanel
				$dstCred = Get-CredentialFromPanel $dstPanel
				if ($srcCred) { $params['SourceCredential'] = $srcCred }
				if ($dstCred) { $params['DestinationCredential'] = $dstCred }

				$results = Invoke-sqmTableTransfer @params

				$dgv.DataSource = ($results | ConvertTo-DataTable)

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
