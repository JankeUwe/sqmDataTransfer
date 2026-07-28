<#
	===========================================================================
	 Module Name: sqmDataTransfer
	===========================================================================
#>

# =============================================================================
# SCHRITT 1: Modulkonfiguration als ERSTES initialisieren
# (muss vor dem Laden der Funktionen und vor Get-sqmTransferConfig-Aufrufen stehen)
# =============================================================================
$script:sqmtModuleConfig = @{
	LogPath                = "C:\System\WinSrvLog\MSSQL"
	OutputPath             = "C:\System\WinSrvLog\MSSQL"
	ModuleVersion          = '0.1.0.0'
	# Verbindungssicherheit: TrustServerCertificate fuer alle dbatools-Verbindungen.
	# Self-signed Zertifikate (SQL 2022+ / neuere Microsoft.Data.SqlClient) schlagen
	# sonst mit "certificate chain was issued by an authority that is not trusted" fehl.
	TrustServerCertificate = $true
	# Standard-Batchgroesse fuer Copy-sqmTableData (Copy-DbaDbTableData -BatchSize) - 500k hat sich
	# in der Praxis (grosse Chunk-Transfers) gegenueber 200k als schneller erwiesen: weniger
	# Round-Trips/Transaktions-Overhead pro Zeile, ohne die Log-/Speicherbelastung von noch
	# groesseren Batches.
	DefaultBatchSize       = 500000
	# Ab dieser Quell-Zeilenzahl warnt Invoke-sqmTableTransfer (nicht-chunked Aufruf) mit einem
	# fertigen Invoke-sqmChunkedTableTransfer-Befehlsvorschlag statt die Tabelle stillschweigend
	# als einzelnen All-or-nothing-Copy zu behandeln.
	LargeTableRowThreshold = 10000000
	# Die Chunking-Empfehlung selbst wird nur ausgesprochen, wenn das Ziel bereits mindestens
	# diesen Anteil (in %) der Quellzeilen enthaelt - Chunking bringt seinen Vorteil (Resumability,
	# bereits vollstaendige Chunks ueberspringen) nur bei einem teilweise befuellten Ziel. Bei einem
	# leeren/frischen Ziel ist der normale All-or-nothing-Copy schlicht schneller (kein Pro-Chunk-
	# Overhead), darum dort keine Empfehlung.
	ChunkAdviceMinExistingPercent = 30
	# Obergrenze fuer die AUTOMATISCH ermittelte Chunk-Anzahl. Wird -MaxChunkValues nicht explizit
	# gesetzt, akzeptiert Invoke-sqmChunkedTableTransfer die tatsaechlich gefundene Anzahl
	# unterschiedlicher Werte bis zu dieser Grenze, statt an einem festen Default zu scheitern und
	# einen zweiten Anlauf mit passender Zahl zu erzwingen. Oberhalb der Grenze ist die Spalte zu
	# feingranular (Richtung Zeitstempel) und der Lauf bricht mit Begruendung ab.
	MaxChunkValueCeiling   = 2000
}

# Aktuelle Version bestimmen.
#
# Primaerquelle ist das Modulobjekt selbst: waehrend die .psm1 laeuft, ist
# $ExecutionContext.SessionState.Module genau dieses Modul, und dessen .Version stammt direkt aus
# dem Manifest. Das kann nicht fehlschlagen und braucht keinen Dateizugriff.
#
# Vorher wurde hier Import-PowerShellDataFile auf die .psd1 verwendet. Das ist unter Windows
# PowerShell 5.1 keine Cmdlet, sondern eine FUNKTION aus Microsoft.PowerShell.Utility - und die ist
# im Modulscope waehrend des Modulladens nicht zuverlaessig aufloesbar. Je nach Startkontext des
# Prozesses schlug der Aufruf mit CommandNotFoundException fehl, ein leeres catch verschluckte das,
# und die Version blieb still auf dem Platzhalter '0.1.0.0' stehen - sichtbar nur im GUI-Titel, der
# dann "v0.1.0.0" statt der echten Version anzeigte.
$script:sqmtModuleVersionSource = 'Fallback'
$manifestPath = Join-Path $PSScriptRoot 'sqmDataTransfer.psd1'
if (Test-Path $manifestPath)
{
	try
	{
		# Erster Weg: der uebliche Befehl - aber nur, wenn er hier auch aufloesbar ist.
		if (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue)
		{
			$manifestData = Import-PowerShellDataFile -Path $manifestPath -ErrorAction Stop
			$script:sqmtModuleConfig['ModuleVersion'] = $manifestData.ModuleVersion
			$script:sqmtModuleVersionSource = 'DataFile'
		}
		else
		{
			# Zweiter Weg ohne jede Befehlsaufloesung: das Manifest ueber den PowerShell-Parser
			# lesen. [System.Management.Automation.Language.Parser] ist ein .NET-Typ und damit
			# immer verfuegbar, egal in welchem Scope oder Ladezustand die .psm1 gerade laeuft.
			$manifestAst = [System.Management.Automation.Language.Parser]::ParseFile($manifestPath, [ref]$null, [ref]$null)
			$hashAst = $manifestAst.Find({ $args[0] -is [System.Management.Automation.Language.HashtableAst] }, $false)
			$versionPair = $hashAst.KeyValuePairs | Where-Object { $_.Item1.Extent.Text.Trim("'", '"', ' ') -eq 'ModuleVersion' } | Select-Object -First 1
			if ($versionPair)
			{
				$script:sqmtModuleConfig['ModuleVersion'] = $versionPair.Item2.Extent.Text.Trim("'", '"', ' ')
				$script:sqmtModuleVersionSource = 'Ast'
			}
		}
	}
	catch
	{
		# Nicht still verschlucken: sonst steht im GUI-Titel eine falsche Versionsnummer und
		# niemand erfaehrt, warum.
		Write-Warning "sqmDataTransfer: Modulversion konnte nicht aus '$manifestPath' gelesen werden, es gilt der Platzhalter '$($script:sqmtModuleConfig['ModuleVersion'])': $($_.Exception.Message)"
	}
}

# =============================================================================
# SCHRITT 1b: Persistierte Konfiguration laden (ueberschreibt Standardwerte)
# Eigene Config-Datei, getrennt von sqmSQLTool - kein gemeinsamer Zustand.
# =============================================================================
$configFile = Join-Path $env:APPDATA "SQLDataTransfer\config.json"
if (Test-Path $configFile)
{
	try
	{
		$userConfig = Get-Content $configFile -Raw | ConvertFrom-Json
		foreach ($key in $userConfig.PSObject.Properties)
		{
			$script:sqmtModuleConfig[$key.Name] = $key.Value
		}
	}
	catch
	{
		Write-Warning "sqmDataTransfer: Konfiguration konnte nicht geladen werden: $($_.Exception.Message)"
	}
}

# =============================================================================
# SCHRITT 2: dbatools-Verfuegbarkeit pruefen und einmalig laden
# =============================================================================
$script:sqmtDbatoolsAvailable = $false

if (Get-Module -Name dbatools)
{
	$script:sqmtDbatoolsAvailable = $true
}
else
{
	try
	{
		Import-Module dbatools -ErrorAction Stop
		$script:sqmtDbatoolsAvailable = $true
	}
	catch
	{
		# FITS-Fallback: lokaler UNC-Modulpfad, falls PSModulePath nichts findet
		$fitsFallback = @(
			'W:\75084-Datenbanken\MSSQL\SQLSources\Modules',
			'\\tsclient\W\75084-Datenbanken\MSSQL\SQLSources\Modules'
		) | Where-Object { Test-Path $_ } | Select-Object -First 1

		if ($fitsFallback)
		{
			$dbaDirs = @(Get-ChildItem -Path $fitsFallback -Directory -Filter 'dbatools*' -ErrorAction SilentlyContinue)
			if ($dbaDirs.Count -gt 0)
			{
				$dbaDir = ($dbaDirs | Sort-Object Name -Descending | Select-Object -First 1).FullName
				try
				{
					Import-Module $dbaDir -ErrorAction Stop
					$script:sqmtDbatoolsAvailable = $true
				}
				catch { $script:sqmtDbatoolsAvailable = $false }
			}
		}
	}
}

if (-not $script:sqmtDbatoolsAvailable)
{
	Write-Warning "sqmDataTransfer: dbatools-Modul nicht gefunden. Installation: Install-Module dbatools"
}
elseif ($script:sqmtModuleConfig['TrustServerCertificate'])
{
	try
	{
		Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $true -ErrorAction SilentlyContinue
	}
	catch { Write-Verbose "sqmDataTransfer: Konnte dbatools trustcert nicht setzen: $($_.Exception.Message)" }
}

# =============================================================================
# SCHRITT 3: Private und Public Funktionen laden
# =============================================================================
$PublicPath  = Join-Path $PSScriptRoot 'Public'
$PrivatePath = Join-Path $PSScriptRoot 'Private'

Get-ChildItem -Path $PrivatePath -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
	. $_.FullName
}

Get-ChildItem -Path $PublicPath -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
	. $_.FullName
}

# =============================================================================
# SCHRITT 4: Logging-Bereitschaft pruefen (NACH Funktionsladung und Config-Init)
# =============================================================================
$script:sqmtLoggingReady = Test-sqmTransferLoggingPath -Path (Get-sqmTransferConfig -Key "LogPath")

# Export wird ausschliesslich durch FunctionsToExport in sqmDataTransfer.psd1 gesteuert.
