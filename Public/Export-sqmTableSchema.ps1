<#
.SYNOPSIS
    Scripts the DDL (CREATE TABLE, primary key, indexes, foreign keys, defaults, checks) of one
    or more tables from a source instance/database.

.DESCRIPTION
    Connects to the source instance via dbatools (SMO) and uses the SMO Scripter to generate the
    full metadata script for each requested table. The result is an array of independent SQL
    batches per table (no 'GO' separators needed - each SMO Scripter batch is already a complete,
    executable statement) plus a combined, human-readable script joined with 'GO' for documentation
    or -FilePath output.

    This function only reads from the source; it does not touch the target. Use
    New-sqmTableFromScript to execute the resulting batches against a target instance, or
    Copy-sqmTableSchema to do both in one call.

.PARAMETER SqlInstance
    Source SQL Server instance.

.PARAMETER Database
    Source database name.

.PARAMETER Table
    One or more table names to script. Accepts 'TableName' (schema defaults to 'dbo') or
    'schema.TableName'.

.PARAMETER SqlCredential
    Optional PSCredential for the source instance.

.PARAMETER IncludeForeignKeys
    Include foreign key constraints in the script. Default: $true.

.PARAMETER IncludeIndexes
    Include non-clustered/clustered indexes in the script. Default: $true.

.PARAMETER FilePath
    Optional path to write the combined script to (UTF8, batches separated by 'GO').

.EXAMPLE
    Export-sqmTableSchema -SqlInstance 'SQL01' -Database 'Sales' -Table 'Orders','dbo.Customers'

.EXAMPLE
    Export-sqmTableSchema -SqlInstance 'SQL01' -Database 'Sales' -Table 'Orders' -FilePath 'C:\Temp\Orders.sql'

.NOTES
    Prerequisites: dbatools (Connect-DbaInstance), SMO (loaded transitively via dbatools).
#>
function Export-sqmTableSchema
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $true)]
		[string]$Database,
		[Parameter(Mandatory = $true)]
		[string[]]$Table,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeForeignKeys = $true,
		[Parameter(Mandatory = $false)]
		[bool]$IncludeIndexes = $true,
		[Parameter(Mandatory = $false)]
		[string]$FilePath
	)

	$functionName = $MyInvocation.MyCommand.Name
	Write-sqmTransferLog -Message "Scripte Metadaten von '$SqlInstance'.'$Database' fuer Tabelle(n): $($Table -join ', ')" `
						  -FunctionName $functionName -Level 'INFO'

	$connParams = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	try
	{
		$server = Connect-DbaInstance @connParams
	}
	catch
	{
		$msg = "Verbindung zu '$SqlInstance' fehlgeschlagen: $($_.Exception.Message)"
		Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
		throw $msg
	}

	$db = $server.Databases[$Database]
	if (-not $db)
	{
		$msg = "Datenbank '$Database' auf '$SqlInstance' nicht gefunden."
		Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
		throw $msg
	}

	$smoTables = [System.Collections.Generic.List[object]]::new()
	$notFound = [System.Collections.Generic.List[string]]::new()

	foreach ($t in $Table)
	{
		$schemaName = 'dbo'
		$tableName = $t
		if ($t -match '^(?<schema>[^.]+)\.(?<name>.+)$')
		{
			$schemaName = $Matches['schema']
			$tableName = $Matches['name']
		}

		$smoTable = $db.Tables[$tableName, $schemaName]
		if ($smoTable)
		{
			$smoTables.Add($smoTable)
		}
		else
		{
			$notFound.Add("$schemaName.$tableName")
		}
	}

	if ($notFound.Count -gt 0)
	{
		$msg = "Tabelle(n) nicht gefunden auf '$SqlInstance'.'$Database': $($notFound -join ', ')"
		Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'WARNING'
		Write-Warning $msg
	}

	if ($smoTables.Count -eq 0)
	{
		$msg = "Keine der angegebenen Tabellen wurde gefunden. Vorgang abgebrochen."
		Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
		throw $msg
	}

	$scripter = New-Object Microsoft.SqlServer.Management.Smo.Scripter($server)
	$opts = New-Object Microsoft.SqlServer.Management.Smo.ScriptingOptions
	$opts.ScriptSchema = $true
	$opts.ScriptData = $false
	$opts.Indexes = $IncludeIndexes
	$opts.DriPrimaryKey = $true
	$opts.DriForeignKeys = $IncludeForeignKeys
	$opts.DriUniqueKeys = $true
	$opts.DriChecks = $true
	$opts.DriDefaults = $true
	$opts.Triggers = $false
	$opts.IncludeIfNotExists = $true
	$opts.AnsiPadding = $true
	$opts.ExtendedProperties = $false
	$scripter.Options = $opts

	$urns = New-Object Microsoft.SqlServer.Management.Smo.UrnCollection
	foreach ($smoTable in $smoTables) { $urns.Add($smoTable.Urn) }

	try
	{
		$batches = @($scripter.Script($urns))
	}
	catch
	{
		$msg = "Scripting fehlgeschlagen: $($_.Exception.Message)"
		Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
		throw
	}

	$combinedScript = ($batches -join "`r`nGO`r`n")

	if ($FilePath)
	{
		try
		{
			$dir = Split-Path $FilePath -Parent
			if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
			[System.IO.File]::WriteAllText($FilePath, $combinedScript, (New-Object System.Text.UTF8Encoding($false)))
			Write-sqmTransferLog -Message "Script geschrieben nach '$FilePath'." -FunctionName $functionName -Level 'INFO'
		}
		catch
		{
			Write-Warning "Konnte Script nicht nach '$FilePath' schreiben: $($_.Exception.Message)"
		}
	}

	Write-sqmTransferLog -Message "$($smoTables.Count) Tabelle(n) erfolgreich gescriptet ($($batches.Count) Batch(es))." `
						  -FunctionName $functionName -Level 'INFO'

	[PSCustomObject]@{
		SqlInstance   = $SqlInstance
		Database      = $Database
		Tables        = @($smoTables | ForEach-Object { "$($_.Schema).$($_.Name)" })
		NotFound      = @($notFound)
		ScriptBatches = $batches
		Script        = $combinedScript
		FilePath      = $FilePath
	}
}
