<#
.SYNOPSIS
    Builds the GROUP BY expression and the per-chunk WHERE predicate for a chunk column and
    granularity.

.DESCRIPTION
    Granularity 'Value': one chunk per distinct value, [col] = literal (previous behaviour).
    Granularity 'Month': one chunk per calendar month, for a day-resolution column:
      - date/datetime/datetime2/smalldatetime/datetimeoffset: bucket YEAR*100+MONTH,
        predicate [col] >= 'yyyyMM01' AND [col] < '<next month>01'
      - int/bigint holding yyyyMMdd (e.g. 20240115): bucket [col] / 100,
        predicate [col] >= yyyyMM00 AND [col] < (yyyyMM+1)00
      - char/varchar/nchar/nvarchar holding yyyyMMdd: bucket LEFT([col], 6),
        predicate [col] LIKE 'yyyyMM%'
    All month predicates are ranges or prefix-LIKEs on the bare column, so an index on the chunk
    column can still be used for a seek (a predicate on YEAR([col]) or [col] / 100 could not).

.OUTPUTS
    PSCustomObject: BucketExpr (string), Predicate (scriptblock: bucket value -> WHERE text),
    Literal (scriptblock: bucket value -> lookup key), Validate (scriptblock: bucket values ->
    throws on values that do not fit the granularity).

.NOTES
    Private helper for Invoke-sqmChunkedTableTransfer.
#>
function Get-sqmChunkBucketSql
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$ColumnName,
		[Parameter(Mandatory = $true)]
		[string]$DataType,
		[Parameter(Mandatory = $true)]
		[ValidateSet('Value', 'Month')]
		[string]$Granularity
	)

	$col = "[$ColumnName]"
	$dateTypes = @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
	$intTypes = @('int', 'bigint')
	$textTypes = @('char', 'varchar', 'nchar', 'nvarchar')

	# Laufzeittyp statt Formatierung raten - wie Format-SqlLiteral in Invoke-sqmChunkedTableTransfer.
	$formatLiteral = {
		param($value)
		if ($null -eq $value -or $value -is [System.DBNull]) { return 'NULL' }
		if ($value -is [datetime]) { return "'$($value.ToString('yyyy-MM-ddTHH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture))'" }
		if ($value -is [datetimeoffset]) { return "'$($value.ToString('yyyy-MM-ddTHH:mm:ss.fffffffzzz', [System.Globalization.CultureInfo]::InvariantCulture))'" }
		if ($value -is [string]) { return "N'$($value -replace "'", "''")'" }
		if ($value -is [bool]) { return $(if ($value) { '1' } else { '0' }) }
		return ([System.IFormattable]$value).ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
	}

	if ($Granularity -eq 'Value')
	{
		return [PSCustomObject]@{
			BucketExpr = $col
			Literal    = $formatLiteral
			# NULL braucht IS NULL - "= NULL" trifft nie, der Chunk wuerde still uebersprungen
			Predicate  = { param($v) if ($null -eq $v -or $v -is [System.DBNull]) { "$col IS NULL" } else { "$col = $(& $formatLiteral $v)" } }.GetNewClosure()
			Validate   = { param($values) }
		}
	}

	# Bucket-Wert yyyyMM als Zahl pruefen (fuer alle drei Typfamilien gleich)
	$validate = {
		param($values)
		$bad = @($values | Where-Object {
				if ($null -eq $_ -or $_ -is [System.DBNull]) { return $false }
				$s = "$_".Trim()
				-not ($s -match '^\d{6}$' -and [int]$s.Substring(4, 2) -ge 1 -and [int]$s.Substring(4, 2) -le 12 -and [int]$s.Substring(0, 4) -ge 1900)
			} | Select-Object -First 5)
		if ($bad.Count -gt 0)
		{
			throw "Spalte $col enthaelt Werte, die nicht im Format yyyyMMdd vorliegen (Monats-Buckets z.B.: $($bad -join ', ')) - -ChunkGranularity Month ist fuer diese Spalte nicht moeglich, -ChunkGranularity Value verwenden."
		}
	}.GetNewClosure()

	$monthStart = { param($v) [datetime]::ParseExact("$("$v".Trim())01", 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture) }

	if ($DataType -in $dateTypes)
	{
		$bucketExpr = "(YEAR($col) * 100 + MONTH($col))"
		$predicate = {
			param($v)
			if ($null -eq $v -or $v -is [System.DBNull]) { return "$col IS NULL" }
			$start = & $monthStart $v
			# 'yyyyMMdd' ist DATEFORMAT-unabhaengig
			"$col >= '$($start.ToString('yyyyMMdd'))' AND $col < '$($start.AddMonths(1).ToString('yyyyMMdd'))'"
		}.GetNewClosure()
	}
	elseif ($DataType -in $intTypes)
	{
		$bucketExpr = "($col / 100)"
		$predicate = {
			param($v)
			if ($null -eq $v -or $v -is [System.DBNull]) { return "$col IS NULL" }
			$b = [int64]"$v"
			"$col >= $($b * 100) AND $col < $(($b + 1) * 100)"
		}.GetNewClosure()
	}
	elseif ($DataType -in $textTypes)
	{
		$bucketExpr = "LEFT($col, 6)"
		$predicate = {
			param($v)
			if ($null -eq $v -or $v -is [System.DBNull]) { return "$col IS NULL" }
			"$col LIKE N'$("$v".Trim())%'"
		}.GetNewClosure()
	}
	else
	{
		throw "-ChunkGranularity Month wird fuer Spalte $col vom Typ '$DataType' nicht unterstuetzt (nur Datumstypen oder int/bigint/char/varchar mit yyyyMMdd-Werten)."
	}

	return [PSCustomObject]@{
		BucketExpr = $bucketExpr
		Literal    = $formatLiteral
		Predicate  = $predicate
		Validate   = $validate
	}
}
