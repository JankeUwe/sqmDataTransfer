<#
.SYNOPSIS
    Disables foreign keys and/or non-clustered indexes on one or more tables before a bulk data
    transfer.

.DESCRIPTION
    For each table:
        - Foreign keys are disabled individually (ALTER TABLE ... NOCHECK CONSTRAINT <name>),
          leaving other constraint types (CHECK, DEFAULT) untouched.
        - Non-clustered indexes are disabled individually (ALTER INDEX <name> ON <table> DISABLE).
          Clustered indexes are never disabled - disabling one makes the table inaccessible.
    Already-disabled objects are skipped (reported as 'AlreadyDisabled') so this is safe to call
    repeatedly. Use Enable-sqmTableConstraints afterwards to reverse the effect - it re-detects
    the currently disabled objects, no state needs to be passed between the two calls.

.PARAMETER SqlInstance
    Target SQL Server instance.

.PARAMETER Database
    Target database name.

.PARAMETER Table
    One or more table names ('Table' or 'schema.Table').

.PARAMETER SqlCredential
    Optional PSCredential for the instance.

.PARAMETER IncludeForeignKeys
    Disable foreign keys. Default: $true.

.PARAMETER IncludeIndexes
    Disable non-clustered indexes. Default: $true.

.PARAMETER Confirm
.PARAMETER WhatIf

.EXAMPLE
    Disable-sqmTableConstraints -SqlInstance SQL02 -Database Sales -Table Orders

.EXAMPLE
    Disable-sqmTableConstraints -SqlInstance SQL02 -Database Sales -Table Orders -IncludeIndexes $false

.NOTES
    Prerequisites: dbatools (Invoke-DbaQuery), Write-sqmTransferLog.
    Re-enabling: Enable-sqmTableConstraints.
#>
function Disable-sqmTableConstraints
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
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
		[bool]$IncludeIndexes = $true
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database; ErrorAction = 'Stop' }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$results = [System.Collections.Generic.List[PSCustomObject]]::new()

	foreach ($t in $Table)
	{
		$schemaName = 'dbo'
		$tableName = $t
		if ($t -match '^(?<schema>[^.]+)\.(?<name>.+)$')
		{
			$schemaName = $Matches['schema']
			$tableName = $Matches['name']
		}
		$qualified = "$schemaName.$tableName"

		if ($IncludeForeignKeys)
		{
			try
			{
				$fkQuery = @"
SELECT fk.name AS FkName
FROM sys.foreign_keys fk
WHERE fk.parent_object_id = OBJECT_ID(N'[$schemaName].[$tableName]')
  AND fk.is_disabled = 0
"@
				$fks = @(Invoke-DbaQuery @connParams -Query $fkQuery -As PSObject -EnableException)
				foreach ($fk in $fks)
				{
					$action = "Foreign Key '$($fk.FkName)' auf '$qualified' deaktivieren"
					if ($PSCmdlet.ShouldProcess($qualified, $action))
					{
						try
						{
							Invoke-DbaQuery @connParams -Query "ALTER TABLE [$schemaName].[$tableName] NOCHECK CONSTRAINT [$($fk.FkName)]" -EnableException | Out-Null
							$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'ForeignKey'; ObjectName = $fk.FkName; Action = 'Disable'; Status = 'Success' })
							Write-sqmTransferLog -Message "FK '$($fk.FkName)' auf '$qualified' deaktiviert." -FunctionName $functionName -Level 'INFO'
						}
						catch
						{
							$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'ForeignKey'; ObjectName = $fk.FkName; Action = 'Disable'; Status = "Failed: $($_.Exception.Message)" })
							Write-sqmTransferLog -Message "FK '$($fk.FkName)' auf '$qualified' konnte nicht deaktiviert werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
						}
					}
					else
					{
						$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'ForeignKey'; ObjectName = $fk.FkName; Action = 'Disable'; Status = 'WhatIf' })
					}
				}
				if ($fks.Count -eq 0)
				{
					Write-sqmTransferLog -Message "Keine aktiven Foreign Keys auf '$qualified' gefunden." -FunctionName $functionName -Level 'INFO'
				}
			}
			catch
			{
				$msg = "Fehler beim Ermitteln der Foreign Keys auf '$qualified': $($_.Exception.Message)"
				Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
				$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'ForeignKey'; ObjectName = '(alle)'; Action = 'Disable'; Status = "Failed: $($_.Exception.Message)" })
			}
		}

		if ($IncludeIndexes)
		{
			try
			{
				$idxQuery = @"
SELECT i.name AS IndexName
FROM sys.indexes i
WHERE i.object_id = OBJECT_ID(N'[$schemaName].[$tableName]')
  AND i.type_desc = 'NONCLUSTERED'
  AND i.is_disabled = 0
  AND i.name IS NOT NULL
"@
				$idxs = @(Invoke-DbaQuery @connParams -Query $idxQuery -As PSObject -EnableException)
				foreach ($idx in $idxs)
				{
					$action = "Index '$($idx.IndexName)' auf '$qualified' deaktivieren"
					if ($PSCmdlet.ShouldProcess($qualified, $action))
					{
						try
						{
							Invoke-DbaQuery @connParams -Query "ALTER INDEX [$($idx.IndexName)] ON [$schemaName].[$tableName] DISABLE" -EnableException | Out-Null
							$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Index'; ObjectName = $idx.IndexName; Action = 'Disable'; Status = 'Success' })
							Write-sqmTransferLog -Message "Index '$($idx.IndexName)' auf '$qualified' deaktiviert." -FunctionName $functionName -Level 'INFO'
						}
						catch
						{
							$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Index'; ObjectName = $idx.IndexName; Action = 'Disable'; Status = "Failed: $($_.Exception.Message)" })
							Write-sqmTransferLog -Message "Index '$($idx.IndexName)' auf '$qualified' konnte nicht deaktiviert werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
						}
					}
					else
					{
						$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Index'; ObjectName = $idx.IndexName; Action = 'Disable'; Status = 'WhatIf' })
					}
				}
				if ($idxs.Count -eq 0)
				{
					Write-sqmTransferLog -Message "Keine aktiven nicht-geclusterten Indizes auf '$qualified' gefunden." -FunctionName $functionName -Level 'INFO'
				}
			}
			catch
			{
				$msg = "Fehler beim Ermitteln der Indizes auf '$qualified': $($_.Exception.Message)"
				Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
				$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Index'; ObjectName = '(alle)'; Action = 'Disable'; Status = "Failed: $($_.Exception.Message)" })
			}
		}
	}

	return $results
}
