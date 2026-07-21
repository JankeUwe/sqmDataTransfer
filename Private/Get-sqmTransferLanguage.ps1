<#
.SYNOPSIS
    Resolves the active UI language ('de' or 'en') for GUI labels and log messages.

.DESCRIPTION
    Honors an explicit override (Set-sqmTransferConfig -Key Language -Value 'de'/'en') if one is
    set; otherwise auto-detects from $PSUICulture (Windows display language) at call time -
    'de*' cultures resolve to German, everything else to English.
#>
function Get-sqmTransferLanguage
{
	[CmdletBinding()]
	[OutputType([string])]
	param ()

	$configured = $script:sqmtModuleConfig['Language']
	if ($configured -and @('de', 'en') -contains $configured) { return $configured }

	if ($PSUICulture -like 'de*') { return 'de' }
	return 'en'
}
