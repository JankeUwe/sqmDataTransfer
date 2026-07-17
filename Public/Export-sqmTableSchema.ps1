<#
.SYNOPSIS
    Scripts the DDL (CREATE TABLE, primary key, indexes, foreign keys, defaults, checks) of one
    or more tables from a source instance/database - together with anything else required for the
    CREATE to actually succeed on a target: the destination schema, and any user-defined types,
    sequences or FK-referenced tables the table depends on.

.DESCRIPTION
    Connects to the source instance via dbatools (SMO) and uses the SMO Scripter to generate the
    full metadata script for each requested table. The result is an array of independent SQL
    batches (no 'GO' separators needed - each SMO Scripter batch is already a complete, executable
    statement) plus a combined, human-readable script joined with 'GO' for documentation or
    -FilePath output.

    Dependency handling (so scripting "just this table" doesn't fail on the target for reasons
    that have nothing to do with the table's own definition):
        - Destination schema: a guarded 'IF NOT EXISTS ... CREATE SCHEMA' batch is prepended for
          each requested table's schema.
        - User-defined types, sequences, and FK-referenced tables: SMO's WithDependencies option
          walks the real dependency graph (sys.sql_expression_dependencies) and prepends whatever
          the table's columns/constraints actually reference, in the correct creation order.
        - Partitioned tables: physical partition layout (partition function/scheme, per-partition
          filegroups) is NOT replicated - this function has no way to know whether an equivalent
          scheme exists on the target, or what filegroups it has. Instead, partitioning is
          stripped from the script entirely (SMO NoFileGroup / NoTablePartitioningSchemes /
          NoIndexPartitioningSchemes) so the table and its indexes are created as normal,
          non-partitioned objects on the default filegroup (PRIMARY). The table is still fully
          scripted and transferred - only the physical partitioning itself is not recreated.
          Reported via -Warnings-.
        - CLR user-defined types: reported as a warning (assembly deployment is out of scope), the
          table is still scripted but that column's type will not resolve on the target unless the
          assembly is deployed manually first.

    This function only reads from the source; it does not touch the target. Use
    New-sqmTableFromScript to execute the resulting batches against a target instance, or
    Copy-sqmTableSchema to do both in one call (which also auto-detects the target's SQL Server
    version for -TargetServerVersion).

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

.PARAMETER TargetServerVersion
    SMO target version (Microsoft.SqlServer.Management.Smo.SqlServerVersion) to script
    compatible syntax for - important when the source is a newer SQL Server than the target (e.g.
    scripting from a 2022 source down to a 2019 target). When omitted, SMO scripts using
    source-native syntax, which may include features the target doesn't support.
    Copy-sqmTableSchema sets this automatically from the destination's actual version.

.PARAMETER FilePath
    Optional path to write the combined script to (UTF8, batches separated by 'GO').

.EXAMPLE
    Export-sqmTableSchema -SqlInstance 'SQL01' -Database 'Sales' -Table 'Orders','dbo.Customers'

.EXAMPLE
    Export-sqmTableSchema -SqlInstance 'SQL01' -Database 'Sales' -Table 'Orders' -FilePath 'C:\Temp\Orders.sql'

.EXAMPLE
    Export-sqmTableSchema -SqlInstance 'SQL01' -Database 'Sales' -Table 'Orders' `
        -TargetServerVersion ([Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version150)

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
		[Microsoft.SqlServer.Management.Smo.SqlServerVersion]$TargetServerVersion,
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
	$warnings = [System.Collections.Generic.List[string]]::new()
	$anyPartitioned = $false

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
		if (-not $smoTable)
		{
			$notFound.Add("$schemaName.$tableName")
			continue
		}

		if ($smoTable.IsPartitioned)
		{
			$anyPartitioned = $true
			$warnings.Add("$schemaName.${tableName}: Tabelle war partitioniert (Partitionsschema '$($smoTable.PartitionScheme)') - wird ohne Partitionierung auf dem Standard-Filegroup (PRIMARY) angelegt.")
		}

		# CLR-basierte benutzerdefinierte Typen: Scripting der Tabelle funktioniert, aber die
		# Assembly muss manuell auf dem Ziel bereitgestellt werden - kein Blocker, nur ein Hinweis.
		foreach ($col in $smoTable.Columns)
		{
			if ($col.DataType.SqlDataType.ToString() -eq 'UserDefinedType')
			{
				$warnings.Add("$schemaName.${tableName}: Spalte '$($col.Name)' nutzt den CLR-Typ '$($col.DataType.Schema).$($col.DataType.Name)' - die zugehoerige Assembly muss manuell auf dem Ziel bereitgestellt werden.")
			}
		}

		$smoTables.Add($smoTable)
	}

	if ($notFound.Count -gt 0)
	{
		$msg = "Tabelle(n) nicht gefunden auf '$SqlInstance'.'$Database': $($notFound -join ', ')"
		Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'WARNING'
		Write-Warning $msg
	}
	foreach ($w in $warnings)
	{
		Write-Warning $w
		Write-sqmTransferLog -Message $w -FunctionName $functionName -Level 'WARNING'
	}

	$batches = @()
	$schemasGuarded = @()

	if ($smoTables.Count -gt 0)
	{
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
		# Walkt die echte Abhaengigkeitskette (sys.sql_expression_dependencies): benutzerdefinierte
		# Typen, Sequenzen und per FK referenzierte Tabellen werden automatisch mitgescriptet, in
		# der richtigen Erstellungsreihenfolge - verhindert Fehlschlaege durch fehlende Abhaengigkeiten.
		$opts.WithDependencies = $true
		# Partitionierung entfernen: NoFileGroup allein reicht nicht (die ON [scheme]([col])-Klausel
		# bleibt sonst erhalten) - erst mit den beiden Partitioning-Optionen zusammen landen Tabelle
		# und Indizes ohne jeden Partitionsbezug auf dem Standard-Filegroup (PRIMARY). Verifiziert:
		# ohne diese beiden schlaegt CREATE TABLE am Ziel fehl, wenn das Partitionsschema dort fehlt.
		$opts.NoFileGroup = $true
		$opts.NoTablePartitioningSchemes = $true
		$opts.NoIndexPartitioningSchemes = $true
		if ($TargetServerVersion) { $opts.TargetServerVersion = $TargetServerVersion }
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

		# Ziel-Schema(s) absichern: ein fehlendes Schema wuerde CREATE TABLE sonst zum Scheitern
		# bringen, obwohl die Tabelle selbst korrekt gescriptet wurde.
		$schemasGuarded = @($smoTables | Select-Object -ExpandProperty Schema -Unique | Where-Object { $_ -ne 'dbo' })
		$schemaBatches = @(foreach ($schemaName in $schemasGuarded)
			{
				"IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'$($schemaName -replace "'", "''")')`r`nEXEC('CREATE SCHEMA [$schemaName]')"
			})
		$batches = @($schemaBatches) + @($batches)
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

	Write-sqmTransferLog -Message "$($smoTables.Count) Tabelle(n) erfolgreich gescriptet ($($batches.Count) Batch(es), $($schemasGuarded.Count) Schema(s) abgesichert$(if ($anyPartitioned) { ', Partitionierung entfernt' }))." `
						  -FunctionName $functionName -Level 'INFO'

	[PSCustomObject]@{
		SqlInstance   = $SqlInstance
		Database      = $Database
		Tables        = @($smoTables | ForEach-Object { "$($_.Schema).$($_.Name)" })
		NotFound      = @($notFound)
		Warnings      = @($warnings)
		SchemasGuarded = @($schemasGuarded)
		ScriptBatches = $batches
		Script        = $combinedScript
		FilePath      = $FilePath
	}
}
