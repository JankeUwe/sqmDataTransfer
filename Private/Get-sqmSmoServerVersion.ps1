<#
.SYNOPSIS
    Maps a SQL Server VersionMajor/VersionMinor pair to the corresponding SMO
    ScriptingOptions.TargetServerVersion enum value.

.DESCRIPTION
    Used to auto-detect the destination instance's version so schema scripting (SMO Scripter)
    generates syntax compatible with an OLDER target when the source is newer (e.g. scripting
    from a SQL Server 2022 source down to a SQL Server 2019 target). Without this, SMO defaults
    to source-native syntax, which can include target-incompatible features.

.PARAMETER VersionMajor
    SMO/Server.VersionMajor (e.g. 16 for SQL Server 2022, 15 for 2019).

.PARAMETER VersionMinor
    SMO/Server.VersionMinor (only relevant to distinguish SQL Server 2008 from 2008 R2).

.EXAMPLE
    Get-sqmSmoServerVersion -VersionMajor 15 -VersionMinor 0
#>
function Get-sqmSmoServerVersion
{
	[CmdletBinding()]
	[OutputType([Microsoft.SqlServer.Management.Smo.SqlServerVersion])]
	param (
		[Parameter(Mandatory = $true)]
		[int]$VersionMajor,
		[Parameter(Mandatory = $false)]
		[int]$VersionMinor = 0
	)

	switch ($VersionMajor)
	{
		{ $_ -ge 16 } { return [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version160 } # 2022+
		15 { return [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version150 } # 2019
		14 { return [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version140 } # 2017
		13 { return [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version130 } # 2016
		12 { return [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version120 } # 2014
		11 { return [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version110 } # 2012
		10 { if ($VersionMinor -ge 50) { return [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version105 } else { return [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version100 } } # 2008 / 2008 R2
		9 { return [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version90 } # 2005
		default { return [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version80 } # 2000 oder unbekannt/aelter
	}
}
