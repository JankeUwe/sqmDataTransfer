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
	# Standard-Batchgroesse fuer Copy-sqmTableData (Copy-DbaDbTableData -BatchSize).
	DefaultBatchSize       = 50000
}

# Aktuelle Version aus der Manifestdatei lesen
$manifestPath = Join-Path $PSScriptRoot 'sqmDataTransfer.psd1'
if (Test-Path $manifestPath)
{
	try
	{
		$manifestData = Import-PowerShellDataFile -Path $manifestPath -ErrorAction Stop
		$script:sqmtModuleConfig['ModuleVersion'] = $manifestData.ModuleVersion
	}
	catch { }
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
