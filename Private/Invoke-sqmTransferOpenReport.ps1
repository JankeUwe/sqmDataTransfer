<#
.SYNOPSIS
    Opens a generated HTML report in the default browser, unless -NoOpen is given.

.DESCRIPTION
    Mirrors sqmSQLTool's Invoke-sqmOpenReport convention: reports auto-open by default after
    creation, with -NoOpen as the opt-out. Failures to open (e.g. no default handler registered)
    are logged verbosely and never throw - opening the report is a convenience, not a required step.

.PARAMETER HtmlFile
    Path to the HTML file to open.

.PARAMETER NoOpen
    Skip opening the report.
#>
function Invoke-sqmTransferOpenReport
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[string]$HtmlFile,
		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)
	if ($NoOpen) { return }
	if ($HtmlFile -and (Test-Path $HtmlFile))
	{
		try { Start-Process $HtmlFile | Out-Null }
		catch { Write-Verbose "Bericht konnte nicht geoeffnet werden: $($_.Exception.Message)" }
	}
}
