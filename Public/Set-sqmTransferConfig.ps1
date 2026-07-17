<#
.SYNOPSIS
    Sets one or more configuration values for the sqmDataTransfer module.

.DESCRIPTION
    Allows setting of LogPath, OutputPath, TrustServerCertificate and DefaultBatchSize.
    Paths are validated for existence or creatability. The configuration is persisted
    in a JSON file in the user profile (%APPDATA%\SQLDataTransfer\config.json),
    separate from sqmSQLTool's configuration.

.PARAMETER LogPath
    Directory for log files (Write-sqmTransferLog).

.PARAMETER OutputPath
    Default output directory for scripted schema files.

.PARAMETER TrustServerCertificate
    Whether dbatools connections trust self-signed server certificates. Default: $true.

.PARAMETER DefaultBatchSize
    Default -BatchSize passed to Copy-DbaDbTableData by Copy-sqmTableData.

.PARAMETER PassThru
    Returns the updated configuration as an object.

.EXAMPLE
    Set-sqmTransferConfig -LogPath "D:\Logs\sqmDataTransfer"

.EXAMPLE
    Set-sqmTransferConfig -DefaultBatchSize 100000
#>
function Set-sqmTransferConfig
{
	[CmdletBinding(SupportsShouldProcess = $true)]
	param (
		[Parameter(Mandatory = $false)]
		[string]$LogPath,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[bool]$TrustServerCertificate,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 1000000)]
		[int]$DefaultBatchSize,
		[Parameter(Mandatory = $false)]
		[switch]$PassThru
	)

	function Test-AndCreatePath($Path, $Purpose)
	{
		if (-not $Path) { return $true }
		if ($Path -match '^\s*$')
		{
			Write-Error "Pfad fuer $Purpose darf nicht leer sein."
			return $false
		}
		try
		{
			if (-not (Test-Path $Path))
			{
				New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
				Write-Verbose "Verzeichnis '$Path' ($Purpose) wurde erstellt."
			}
			return $true
		}
		catch
		{
			Write-Warning "Pfad '$Path' ($Purpose) konnte nicht erstellt werden: $($_.Exception.Message). Wird spaeter automatisch angelegt. Konfiguration wird gespeichert."
			return $true
		}
	}

	$updated = $false
	$globalConfig = $script:sqmtModuleConfig

	if ($PSBoundParameters.ContainsKey('LogPath'))
	{
		if (Test-AndCreatePath $LogPath "LogPath")
		{
			if ($PSCmdlet.ShouldProcess('sqmtModuleConfig', "LogPath = '$LogPath'"))
			{
				$globalConfig['LogPath'] = $LogPath
				$updated = $true
			}
		}
		else { return }
	}
	if ($PSBoundParameters.ContainsKey('OutputPath'))
	{
		if (Test-AndCreatePath $OutputPath "OutputPath")
		{
			if ($PSCmdlet.ShouldProcess('sqmtModuleConfig', "OutputPath = '$OutputPath'"))
			{
				$globalConfig['OutputPath'] = $OutputPath
				$updated = $true
			}
		}
		else { return }
	}
	if ($PSBoundParameters.ContainsKey('TrustServerCertificate'))
	{
		if ($PSCmdlet.ShouldProcess('sqmtModuleConfig', "TrustServerCertificate = $TrustServerCertificate"))
		{
			$globalConfig['TrustServerCertificate'] = $TrustServerCertificate
			$updated = $true
		}
	}
	if ($PSBoundParameters.ContainsKey('DefaultBatchSize'))
	{
		if ($PSCmdlet.ShouldProcess('sqmtModuleConfig', "DefaultBatchSize = $DefaultBatchSize"))
		{
			$globalConfig['DefaultBatchSize'] = $DefaultBatchSize
			$updated = $true
		}
	}

	if (-not $updated)
	{
		Write-Warning "Es wurde kein gueltiger Konfigurationsparameter angegeben."
		return
	}

	$configFile = Join-Path $env:APPDATA "SQLDataTransfer\config.json"
	$configDir = Split-Path $configFile -Parent
	if (-not (Test-Path $configDir))
	{
		New-Item -ItemType Directory -Path $configDir -Force | Out-Null
	}

	$persistConfig = [ordered]@{}
	if (Test-Path $configFile)
	{
		try
		{
			$existingJson = Get-Content $configFile -Raw | ConvertFrom-Json
			foreach ($prop in $existingJson.PSObject.Properties) { $persistConfig[$prop.Name] = $prop.Value }
		}
		catch { }
	}

	foreach ($paramName in $PSBoundParameters.Keys)
	{
		if ($globalConfig.ContainsKey($paramName))
		{
			$persistConfig[$paramName] = $globalConfig[$paramName]
		}
	}

	$persistConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $configFile -Force
	Write-Verbose "Konfiguration gespeichert: $configFile"

	if ($PassThru)
	{
		return Get-sqmTransferConfig
	}
}
