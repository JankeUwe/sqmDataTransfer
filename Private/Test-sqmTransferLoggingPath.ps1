<#
.SYNOPSIS
    Prueft, ob der Logging-Pfad existiert und beschreibbar ist.

.DESCRIPTION
    Erstellt das Verzeichnis falls noetig, schreibt eine temporaere Testdatei
    und entfernt diese wieder. Gibt $true zurueck wenn der Pfad nutzbar ist.

.PARAMETER Path
    Zu pruefender Verzeichnispfad.
#>
function Test-sqmTransferLoggingPath
{
	[CmdletBinding()]
	param (
		[string]$Path = "C:\System\WinSrvLog\MSSQL"
	)

	try
	{
		if (-not (Test-Path $Path))
		{
			New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
			Write-Verbose "Logging-Pfad '$Path' wurde erstellt."
		}

		$testFile = Join-Path $Path ".write_test_$(Get-Date -Format 'yyyyMMddHHmmssfff')_$(Get-Random).tmp"
		"Test" | Out-File -FilePath $testFile -ErrorAction Stop
		Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue

		return $true
	}
	catch
	{
		Write-Warning (Get-sqmTransferString -Key 'LoggingPath.NotWritable' -FormatArgs @($Path, $_.Exception.Message))
		return $false
	}
}
