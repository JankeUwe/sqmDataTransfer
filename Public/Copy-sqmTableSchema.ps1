<#
.SYNOPSIS
    Scripts table metadata from a source instance and creates it on a target instance in one call.

.DESCRIPTION
    Convenience wrapper combining Export-sqmTableSchema (source) and New-sqmTableFromScript
    (target). Used by Invoke-sqmTableTransfer when -ScriptMetadata is requested, but can also be
    called standalone.

    Auto-detects the destination's actual SQL Server version (via Connect-DbaInstance) and passes
    it to Export-sqmTableSchema as -TargetServerVersion, so scripting from a newer source (e.g.
    SQL Server 2022) down to an older target (e.g. 2019) produces syntax the target can actually
    run, instead of source-native syntax that may not exist there.

.PARAMETER Source
    Source SQL Server instance.

.PARAMETER SourceDatabase
    Source database name.

.PARAMETER Destination
    Target SQL Server instance.

.PARAMETER DestinationDatabase
    Target database name.

.PARAMETER Table
    One or more table names ('Table' or 'schema.Table').

.PARAMETER SourceCredential
    Optional PSCredential for the source instance.

.PARAMETER DestinationCredential
    Optional PSCredential for the target instance.

.PARAMETER IncludeForeignKeys
    Include foreign keys in the scripted metadata. Default: $true.

.PARAMETER IncludeIndexes
    Include indexes in the scripted metadata. Default: $true.

.PARAMETER EnableException
    Throw immediately on the first failing batch instead of continuing.

.PARAMETER Confirm
.PARAMETER WhatIf

.EXAMPLE
    Copy-sqmTableSchema -Source SQL01 -SourceDatabase Sales -Destination SQL02 -DestinationDatabase Sales -Table Orders,Customers

.NOTES
    Prerequisites: Export-sqmTableSchema, New-sqmTableFromScript, Get-sqmSmoServerVersion.
#>
function Copy-sqmTableSchema
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
		[bool]$IncludeForeignKeys = $true,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeIndexes = $true,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name

	$targetVersion = $null
	try
	{
		$dstConnParams = @{ SqlInstance = $Destination; ErrorAction = 'Stop' }
		if ($DestinationCredential) { $dstConnParams['SqlCredential'] = $DestinationCredential }
		$dstServer = Connect-DbaInstance @dstConnParams
		$targetVersion = Get-sqmSmoServerVersion -VersionMajor $dstServer.VersionMajor -VersionMinor $dstServer.VersionMinor
		Write-sqmTransferLog -Message "Ziel '$Destination' erkannt als SQL Server $($dstServer.VersionMajor).$($dstServer.VersionMinor) -> TargetServerVersion $targetVersion." `
							  -FunctionName $functionName -Level 'INFO'
	}
	catch
	{
		Write-sqmTransferLog -Message "Zielversion von '$Destination' konnte nicht ermittelt werden - scripte ohne TargetServerVersion (Quellsyntax): $($_.Exception.Message)" `
							  -FunctionName $functionName -Level 'WARNING'
	}

	$exportParams = @{
		SqlInstance		    = $Source
		Database		    = $SourceDatabase
		Table			    = $Table
		SqlCredential	    = $SourceCredential
		IncludeForeignKeys  = $IncludeForeignKeys
		IncludeIndexes	    = $IncludeIndexes
	}
	if ($targetVersion) { $exportParams['TargetServerVersion'] = $targetVersion }

	$schema = Export-sqmTableSchema @exportParams

	if (-not $schema.ScriptBatches -or $schema.ScriptBatches.Count -eq 0)
	{
		# WICHTIG: nicht einfach 'return' (=$null) - der Aufrufer (Invoke-sqmTableTransfer) muss
		# dies als fehlgeschlagene/blockierte/nicht gefundene Tabelle erkennen koennen, statt es
		# mangels jeglicher Failed-Ergebniszeile stillschweigend als Erfolg zu werten.
		if ($schema.Blocked -and $schema.Blocked.Count -gt 0)
		{
			$msg = "Tabelle(n) blockiert fuer $($Table -join ', ') von '$Source'.'$SourceDatabase': $($schema.Blocked -join ' | ')"
			Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'WARNING'
			Write-Warning $msg
			return [PSCustomObject]@{ BatchNumber = 0; Status = 'Blocked'; Message = $msg }
		}
		$msg = "Kein Script erzeugt fuer $($Table -join ', ') von '$Source'.'$SourceDatabase' - Tabelle(n) nicht gefunden: $($schema.NotFound -join ', ')."
		Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'WARNING'
		Write-Warning $msg
		return [PSCustomObject]@{ BatchNumber = 0; Status = 'NotFound'; Message = $msg }
	}

	$action = "$($schema.Tables.Count) Tabelle(n) auf '$Destination'.'$DestinationDatabase' anlegen: $($schema.Tables -join ', ')"
	if ($schema.SchemasGuarded -and $schema.SchemasGuarded.Count -gt 0)
	{
		$action += " (inkl. Schema-Absicherung: $($schema.SchemasGuarded -join ', '))"
	}
	if ($PSCmdlet.ShouldProcess("$Destination.$DestinationDatabase", $action))
	{
		New-sqmTableFromScript -SqlInstance $Destination -Database $DestinationDatabase `
							    -ScriptBatches $schema.ScriptBatches -SqlCredential $DestinationCredential `
							    -EnableException:$EnableException -Confirm:$false
	}
	else
	{
		[PSCustomObject]@{ BatchNumber = 0; Status = 'WhatIf'; Message = "WhatIf: $action" }
	}
}
