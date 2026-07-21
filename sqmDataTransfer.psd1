<#
	===========================================================================
	 Module Manifest
	-------------------------------------------------------------------------
	 Module Name: sqmDataTransfer
	===========================================================================
#>

@{
	# Script module or binary module file associated with this manifest
	RootModule			   = 'sqmDataTransfer.psm1'

	# Version number of this module.
	ModuleVersion		   = '0.1.0.0'

	# ID used to uniquely identify this module
	GUID				   = '0a8cb3da-acb1-45c5-afb7-85759e11c89d'

	Author				   = 'Uwe Janke'

	# Company or vendor of this module
	CompanyName		       = 'dtcSoftware'

	# Copyright statement for this module
	Copyright			   = '(c) 2026 Uwe Janke. MIT License.'

	# Description of the functionality provided by this module
	Description		       = 'Transfers table data between SQL Server instances via dbatools: optional metadata scripting/creation on the target, disabling and re-enabling foreign keys and indexes around the transfer, row-count reconciliation and full logging.'

	PowerShellVersion	   = '5.1'

	# Minimum version of the .NET Framework required by this module
	DotNetFrameworkVersion = '4.5'

	# Minimum version of the common language runtime (CLR) required by this module
	CLRVersion			   = '4.0'

	# Processor architecture (None, X86, Amd64, IA64) required by this module
	ProcessorArchitecture  = 'None'

	# Modules that must be imported into the global environment prior to importing this module
	#
	# dbatools MaximumVersion 2.999.999: dbatools 3.0 is announced as a C# module (binary
	# cmdlets instead of PowerShell functions) and is likely to change return objects/behavior.
	# The cap stops Update-Module dbatools from silently jumping to an incompatible major
	# version before this module has been tested and cleared against it.
	RequiredModules	       = @(@{ ModuleName = "dbatools"; MaximumVersion = "2.999.999" })

	# Assemblies that must be loaded prior to importing this module
	RequiredAssemblies	   = @()

	# Script files (.ps1) that are run in the caller's environment prior to importing this module
	ScriptsToProcess	   = @()

	# Type files (.ps1xml) to be loaded when importing this module
	TypesToProcess		   = @()

	# Format files (.ps1xml) to be loaded when importing this module
	FormatsToProcess	   = @()

	# Modules to import as nested modules of the module specified in ModuleToProcess
	NestedModules		   = @()

	# FunctionsToExport: Explizite Liste ALLER public Funktionen.
	# Export-ModuleMember wird in der .psm1 NICHT aufgerufen - nur diese Liste steuert den Export
	# (vermeidet die PowerShell-WARNING ueber "restricted characters" bei Verb-Noun-Bindestrichen).
	FunctionsToExport	   = @(
		'Get-sqmTransferConfig',
		'Set-sqmTransferConfig',
		'Export-sqmTableSchema',
		'Export-sqmTransferReport',
		'New-sqmTableFromScript',
		'Copy-sqmTableSchema',
		'Disable-sqmTableConstraints',
		'Enable-sqmTableConstraints',
		'Copy-sqmTableData',
		'Compare-sqmTableRowCount',
		'Compare-sqmDatabaseRowCount',
		'Sync-sqmTableData',
		'Invoke-sqmTableTransfer',
		'Show-sqmTableTransferGui'
	)

	# Keine Cmdlets im Modul - explizit leer statt '*'
	CmdletsToExport	       = @()

	# Keine Variablen exportieren - explizit leer statt '*'
	VariablesToExport	   = @()

	# Keine Aliases - explizit leer statt '*'
	AliasesToExport	       = @()

	# List of all modules packaged with this module
	ModuleList			   = @()

	# List of all files packaged with this module
	FileList			   = @()

	# Private data to pass to the module specified in ModuleToProcess.
	PrivateData		       = @{
		PSData = @{
			# Tags applied to this module. These help with module discovery in online galleries.
			Tags = @('SQLServer', 'DBA', 'DataTransfer', 'dbatools')

			# ReleaseNotes of this module
			ReleaseNotes = 'Initial version: schema scripting, constraint disable/enable, data copy, row-count compare, orchestration, GUI.'

			# External module dependencies
			ExternalModuleDependencies = @('dbatools')
		}
	}
}
