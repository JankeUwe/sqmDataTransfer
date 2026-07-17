<#
.SYNOPSIS
    Returns the current sqmDataTransfer module configuration.

.DESCRIPTION
    Without parameters, the entire configuration is returned as a hashtable.
    With -Key, the value of the requested key is returned.
    If the key does not exist, a warning is shown and $null is returned.

.PARAMETER Key
    Name of the configuration key (e.g. 'LogPath', 'OutputPath', 'TrustServerCertificate', 'DefaultBatchSize').

.EXAMPLE
    Get-sqmTransferConfig

.EXAMPLE
    Get-sqmTransferConfig -Key 'LogPath'
#>
function Get-sqmTransferConfig
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[string]$Key
	)
	if ($Key)
	{
		if ($script:sqmtModuleConfig.ContainsKey($Key))
		{
			return $script:sqmtModuleConfig[$Key]
		}
		else
		{
			Write-Warning "Konfigurationsschluessel '$Key' existiert nicht. Verfuegbare Schluessel: $($script:sqmtModuleConfig.Keys -join ', ')"
			return $null
		}
	}
	return $script:sqmtModuleConfig
}
