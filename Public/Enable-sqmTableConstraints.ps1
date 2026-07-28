<#
.SYNOPSIS
    Re-enables foreign keys and non-clustered indexes on one or more tables after a bulk data
    transfer.

.DESCRIPTION
    For each table, detects currently disabled foreign keys, non-clustered indexes and triggers
    (sys.foreign_keys / sys.indexes / sys.triggers) and re-enables them - no state needs to be
    passed in from a prior Disable-sqmTableConstraints call.

        - Foreign keys: ALTER TABLE ... WITH CHECK CHECK CONSTRAINT <name> (revalidates existing
          data by default) or WITH NOCHECK CHECK CONSTRAINT <name> when -Revalidate is $false
          (faster, but the constraint is then trusted without verifying the newly loaded rows).
        - Indexes: ALTER INDEX <name> ON <table> REBUILD (a disabled index has no valid ON/OFF
          switch - REBUILD is what SQL Server requires to bring it back online).
        - Triggers: ENABLE TRIGGER <name> ON <table>.

.PARAMETER SqlInstance
    Target SQL Server instance.

.PARAMETER Database
    Target database name.

.PARAMETER Table
    One or more table names ('Table' or 'schema.Table').

.PARAMETER SqlCredential
    Optional PSCredential for the instance.

.PARAMETER Revalidate
    Revalidate foreign key data on re-enable (WITH CHECK). Default: $true.
    Set to $false only when the data is already known to be consistent and revalidation cost
    should be avoided - the constraint is then marked NOT TRUSTED by SQL Server.

.PARAMETER Confirm
.PARAMETER WhatIf

.EXAMPLE
    Enable-sqmTableConstraints -SqlInstance SQL02 -Database Sales -Table Orders

.NOTES
    Prerequisites: dbatools (Invoke-DbaQuery), Write-sqmTransferLog.
    Counterpart: Disable-sqmTableConstraints.
#>
function Enable-sqmTableConstraints
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
		[bool]$Revalidate = $true
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database; ErrorAction = 'Stop' }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$results = [System.Collections.Generic.List[PSCustomObject]]::new()
	$checkKeyword = if ($Revalidate) { 'WITH CHECK' } else { 'WITH NOCHECK' }

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

		try
		{
			$fkQuery = @"
SELECT fk.name AS FkName
FROM sys.foreign_keys fk
WHERE fk.parent_object_id = OBJECT_ID(N'[$schemaName].[$tableName]')
  AND fk.is_disabled = 1
"@
			$fks = @(Invoke-DbaQuery @connParams -Query $fkQuery -As PSObject -EnableException)
			foreach ($fk in $fks)
			{
				$action = Get-sqmTransferString -Key 'Constraints.EnableFkAction' -FormatArgs @($fk.FkName, $qualified, $checkKeyword)
				if ($PSCmdlet.ShouldProcess($qualified, $action))
				{
					try
					{
						# Log VOR der Ausfuehrung - bei -Revalidate (WITH CHECK) ist das ein voller Scan gegen
						# die neu geladenen Daten und kann auf einer sehr grossen Tabelle lange dauern (siehe
						# gleiche Begruendung beim Index-REBUILD unten).
						Write-sqmTransferLog -Message "Start: $checkKeyword CHECK CONSTRAINT [$($fk.FkName)] auf $qualified" -FunctionName $functionName -Level 'INFO'
						Invoke-DbaQuery @connParams -Query "ALTER TABLE [$schemaName].[$tableName] $checkKeyword CHECK CONSTRAINT [$($fk.FkName)]" -EnableException | Out-Null
						$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'ForeignKey'; ObjectName = $fk.FkName; Action = 'Enable'; Status = 'Success' })
						Write-sqmTransferLog -Message (Get-sqmTransferString -Key 'Constraints.FkEnabled' -FormatArgs @($fk.FkName, $qualified, $checkKeyword)) -FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'ForeignKey'; ObjectName = $fk.FkName; Action = 'Enable'; Status = "Failed: $($_.Exception.Message)" })
						Write-sqmTransferLog -Message (Get-sqmTransferString -Key 'Constraints.FkEnableFailed' -FormatArgs @($fk.FkName, $qualified, $_.Exception.Message)) -FunctionName $functionName -Level 'ERROR'
					}
				}
				else
				{
					$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'ForeignKey'; ObjectName = $fk.FkName; Action = 'Enable'; Status = 'WhatIf' })
				}
			}
		}
		catch
		{
			$msg = Get-sqmTransferString -Key 'Constraints.DisabledFkQueryFailed' -FormatArgs @($qualified, $_.Exception.Message)
			Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
			$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'ForeignKey'; ObjectName = (Get-sqmTransferString -Key 'Common.All'); Action = 'Enable'; Status = "Failed: $($_.Exception.Message)" })
		}

		try
		{
			$idxQuery = @"
SELECT i.name AS IndexName
FROM sys.indexes i
WHERE i.object_id = OBJECT_ID(N'[$schemaName].[$tableName]')
  AND i.type_desc = 'NONCLUSTERED'
  AND i.is_disabled = 1
  AND i.name IS NOT NULL
"@
			$idxs = @(Invoke-DbaQuery @connParams -Query $idxQuery -As PSObject -EnableException)
			foreach ($idx in $idxs)
			{
				$action = Get-sqmTransferString -Key 'Constraints.EnableIdxAction' -FormatArgs @($idx.IndexName, $qualified)
				if ($PSCmdlet.ShouldProcess($qualified, $action))
				{
					try
					{
						# Log VOR der Ausfuehrung, nicht erst danach - ein REBUILD auf einer sehr grossen
						# Tabelle (ohne ONLINE) kann lange dauern, und ohne diesen Log-Eintrag sieht ein noch
						# laufender Rebuild in der Log-Datei identisch zu einem echten Haenger aus. Mit ihm
						# laesst sich am Zeitstempel ablesen, seit wann genau dieser Index laeuft.
						Write-sqmTransferLog -Message "Start: ALTER INDEX [$($idx.IndexName)] ON $qualified REBUILD" -FunctionName $functionName -Level 'INFO'
						Invoke-DbaQuery @connParams -Query "ALTER INDEX [$($idx.IndexName)] ON [$schemaName].[$tableName] REBUILD" -EnableException | Out-Null
						$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Index'; ObjectName = $idx.IndexName; Action = 'Enable'; Status = 'Success' })
						Write-sqmTransferLog -Message (Get-sqmTransferString -Key 'Constraints.IdxEnabled' -FormatArgs @($idx.IndexName, $qualified)) -FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Index'; ObjectName = $idx.IndexName; Action = 'Enable'; Status = "Failed: $($_.Exception.Message)" })
						Write-sqmTransferLog -Message (Get-sqmTransferString -Key 'Constraints.IdxEnableFailed' -FormatArgs @($idx.IndexName, $qualified, $_.Exception.Message)) -FunctionName $functionName -Level 'ERROR'
					}
				}
				else
				{
					$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Index'; ObjectName = $idx.IndexName; Action = 'Enable'; Status = 'WhatIf' })
				}
			}
		}
		catch
		{
			$msg = Get-sqmTransferString -Key 'Constraints.DisabledIdxQueryFailed' -FormatArgs @($qualified, $_.Exception.Message)
			Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
			$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Index'; ObjectName = (Get-sqmTransferString -Key 'Common.All'); Action = 'Enable'; Status = "Failed: $($_.Exception.Message)" })
		}

		try
		{
			$trgQuery = @"
SELECT tr.name AS TriggerName
FROM sys.triggers tr
WHERE tr.parent_id = OBJECT_ID(N'[$schemaName].[$tableName]')
  AND tr.is_disabled = 1
"@
			$trgs = @(Invoke-DbaQuery @connParams -Query $trgQuery -As PSObject -EnableException)
			foreach ($trg in $trgs)
			{
				$action = Get-sqmTransferString -Key 'Constraints.EnableTrgAction' -FormatArgs @($trg.TriggerName, $qualified)
				if ($PSCmdlet.ShouldProcess($qualified, $action))
				{
					try
					{
						Invoke-DbaQuery @connParams -Query "ENABLE TRIGGER [$($trg.TriggerName)] ON [$schemaName].[$tableName]" -EnableException | Out-Null
						$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Trigger'; ObjectName = $trg.TriggerName; Action = 'Enable'; Status = 'Success' })
						Write-sqmTransferLog -Message (Get-sqmTransferString -Key 'Constraints.TrgEnabled' -FormatArgs @($trg.TriggerName, $qualified)) -FunctionName $functionName -Level 'INFO'
					}
					catch
					{
						$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Trigger'; ObjectName = $trg.TriggerName; Action = 'Enable'; Status = "Failed: $($_.Exception.Message)" })
						Write-sqmTransferLog -Message (Get-sqmTransferString -Key 'Constraints.TrgEnableFailed' -FormatArgs @($trg.TriggerName, $qualified, $_.Exception.Message)) -FunctionName $functionName -Level 'ERROR'
					}
				}
				else
				{
					$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Trigger'; ObjectName = $trg.TriggerName; Action = 'Enable'; Status = 'WhatIf' })
				}
			}
		}
		catch
		{
			$msg = Get-sqmTransferString -Key 'Constraints.DisabledTrgQueryFailed' -FormatArgs @($qualified, $_.Exception.Message)
			Write-sqmTransferLog -Message $msg -FunctionName $functionName -Level 'ERROR'
			$results.Add([PSCustomObject]@{ Table = $qualified; ObjectType = 'Trigger'; ObjectName = (Get-sqmTransferString -Key 'Common.All'); Action = 'Enable'; Status = "Failed: $($_.Exception.Message)" })
		}
	}

	return $results
}
