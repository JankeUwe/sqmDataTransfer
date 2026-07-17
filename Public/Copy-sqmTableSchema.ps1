<#
.SYNOPSIS
    Scripts table metadata from a source instance and creates it on a target instance in one call.

.DESCRIPTION
    Convenience wrapper combining Export-sqmTableSchema (source) and New-sqmTableFromScript
    (target). Used by Invoke-sqmTableTransfer when -ScriptMetadata is requested, but can also be
    called standalone.

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
    Prerequisites: Export-sqmTableSchema, New-sqmTableFromScript.
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

	$schema = Export-sqmTableSchema -SqlInstance $Source -Database $SourceDatabase -Table $Table `
									 -SqlCredential $SourceCredential -IncludeForeignKeys $IncludeForeignKeys `
									 -IncludeIndexes $IncludeIndexes

	if (-not $schema.ScriptBatches -or $schema.ScriptBatches.Count -eq 0)
	{
		$msg = "Kein Script erzeugt fuer $($Table -join ', ') von '$Source'.'$SourceDatabase' - Tabelle(n) nicht gefunden: $($schema.NotFound -join ', ')."
		Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'WARNING'
		Write-Warning $msg
		# WICHTIG: nicht einfach 'return' (=$null) - der Aufrufer (Invoke-sqmTableTransfer) muss
		# dies als fehlgeschlagene/nicht gefundene Tabelle erkennen koennen, statt es mangels
		# jeglicher Failed-Ergebniszeile stillschweigend als Erfolg zu werten.
		return [PSCustomObject]@{ BatchNumber = 0; Status = 'NotFound'; Message = $msg }
	}

	$action = "$($schema.Tables.Count) Tabelle(n) auf '$Destination'.'$DestinationDatabase' anlegen: $($schema.Tables -join ', ')"
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
