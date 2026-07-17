<#
.SYNOPSIS
    Schreibt eine Lognachricht in die tagesaktuelle Logdatei der Funktion.

.DESCRIPTION
    Erstellt pro Tag und aufrufender Funktion eine eigene Logdatei im konfigurierten LogPath.
    Schreibt nur, wenn $script:sqmtLoggingReady = $true (wird beim Modulimport gesetzt).

.PARAMETER Message
    Der zu protokollierende Text.

.PARAMETER FunctionName
    Name der aufrufenden Funktion (wird im Dateinamen verwendet).

.PARAMETER Level
    Log-Level: INFO, WARNING, ERROR, DEBUG, VERBOSE. Standard: INFO.
#>
function Write-sqmTransferLog
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$Message,
		[Parameter(Mandatory = $false)]
		[string]$FunctionName = 'General',
		[Parameter(Mandatory = $false)]
		[ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG', 'VERBOSE')]
		[string]$Level = 'INFO'
	)

	$logPath = Get-sqmTransferConfig -Key "LogPath"

	if ($script:sqmtLoggingReady -and $logPath)
	{
		try
		{
			if (-not (Test-Path $logPath -PathType Container))
			{
				# -WhatIf:$false: Logging ist ein Seitenkanal und darf nicht unter ShouldProcess fallen.
				New-Item -ItemType Directory -Path $logPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null
			}

			$dateStamp = Get-Date -Format "yyyyMMdd"
			$fileName = "sqmDataTransfer_$($dateStamp)_$($FunctionName).log"
			$fullPath = Join-Path $logPath $fileName

			$timestamp = Get-Date -Format "HH:mm:ss"
			"[$timestamp] [$Level] $Message" | Out-File -FilePath $fullPath -Append -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
		}
		catch
		{
			Write-Warning "Logging-Fehler fuer $FunctionName`: $($_.Exception.Message)"
		}
	}
}
