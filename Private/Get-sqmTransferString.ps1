<#
.SYNOPSIS
    Returns a formatted, localized string for log messages and GUI text.

.DESCRIPTION
    Looks up -Key in the string table for the active language (Get-sqmTransferLanguage), applies
    -FormatArgs via the -f operator if given, and returns the result. Falls back to German (the
    table this module started with) if the active language is missing a key, and to the raw key
    name as a last resort so a missing translation never throws.

.PARAMETER Key
    String table key, e.g. 'Copy.Action'.

.PARAMETER FormatArgs
    Optional array of values substituted into the template via the -f operator ({0}, {1}, ...).
#>
function Get-sqmTransferString
{
	[CmdletBinding()]
	[OutputType([string])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$Key,
		[Parameter(Mandatory = $false)]
		[object[]]$FormatArgs
	)

	$lang = Get-sqmTransferLanguage
	$template = $script:sqmtStrings[$lang][$Key]
	if (-not $template) { $template = $script:sqmtStrings['de'][$Key] }
	if (-not $template) { return $Key }

	if ($FormatArgs -and $FormatArgs.Count -gt 0) { return ($template -f $FormatArgs) }
	return $template
}

$script:sqmtStrings = @{
	de = @{
		'Common.WhatIf' = 'WhatIf: {0}'
		'Common.All'    = '(alle)'

		'Compare.SourceError' = 'Quelle: {0}'
		'Compare.DestError'   = 'Ziel: {0}'
		'Compare.LogMessage'  = 'Zeilenvergleich [{0}] -> [{1}]: Quelle={2} Ziel={3} Match={4}{5}'
		'Compare.ErrorSuffix' = ' Fehler: {0}'

		'CompareDb.Start'     = "Vergleiche Zeilenzahlen aller Tabellen: '{0}'.'{1}' -> '{2}'.'{3}' (Metadaten, kein Datenscan)."
		'CompareDb.Summary'   = '{0} Tabelle(n) verglichen: {1} identisch, {2} abweichend, {3} nur auf Quelle, {4} nur auf Ziel.'
		'CompareDb.Verifying' = '{0} abweichende Tabelle(n) werden mit exaktem COUNT_BIG(*) nachgeprueft.'

		'Copy.Action'           = "Daten von '{0}'.'{1}'.[{2}] nach '{3}'.'{4}'.[{5}] kopieren"
		'Copy.RowsCopied'       = '{0} Zeile(n) kopiert: [{1}] -> [{2}] ({3}s).'
		'Copy.Failed'           = 'Datenkopie fehlgeschlagen fuer [{0}]: {1}'
		'Copy.ProgressActivity' = 'Kopiere [{0}]'
		'Copy.ProgressStatus'   = '{0:N0} Zeile(n) kopiert...'

		'CopySchema.TargetVersionDetected' = "Ziel '{0}' erkannt als SQL Server {1}.{2} -> TargetServerVersion {3}."
		'CopySchema.TargetVersionFailed'   = "Zielversion von '{0}' konnte nicht ermittelt werden - scripte ohne TargetServerVersion (Quellsyntax): {1}"
		'CopySchema.NoScript'              = "Kein Script erzeugt fuer {0} von '{1}'.'{2}' - Tabelle(n) nicht gefunden: {3}."
		'CopySchema.CreateAction'          = "{0} Tabelle(n) auf '{1}'.'{2}' anlegen: {3}"
		'CopySchema.SchemaGuardSuffix'     = ' (inkl. Schema-Absicherung: {0})'

		'Constraints.DisableFkAction'        = "Foreign Key '{0}' auf '{1}' deaktivieren"
		'Constraints.FkDisabled'             = "FK '{0}' auf '{1}' deaktiviert."
		'Constraints.FkDisableFailed'        = "FK '{0}' auf '{1}' konnte nicht deaktiviert werden: {2}"
		'Constraints.NoActiveFks'            = "Keine aktiven Foreign Keys auf '{0}' gefunden."
		'Constraints.FkQueryFailed'          = "Fehler beim Ermitteln der Foreign Keys auf '{0}': {1}"
		'Constraints.DisableIdxAction'       = "Index '{0}' auf '{1}' deaktivieren"
		'Constraints.IdxDisabled'            = "Index '{0}' auf '{1}' deaktiviert."
		'Constraints.IdxDisableFailed'       = "Index '{0}' auf '{1}' konnte nicht deaktiviert werden: {2}"
		'Constraints.NoActiveIndexes'        = "Keine aktiven nicht-geclusterten Indizes auf '{0}' gefunden."
		'Constraints.IdxQueryFailed'         = "Fehler beim Ermitteln der Indizes auf '{0}': {1}"
		'Constraints.EnableFkAction'         = "Foreign Key '{0}' auf '{1}' aktivieren ({2})"
		'Constraints.FkEnabled'              = "FK '{0}' auf '{1}' aktiviert ({2})."
		'Constraints.FkEnableFailed'         = "FK '{0}' auf '{1}' konnte nicht aktiviert werden: {2}"
		'Constraints.DisabledFkQueryFailed'  = "Fehler beim Ermitteln deaktivierter Foreign Keys auf '{0}': {1}"
		'Constraints.EnableIdxAction'        = "Index '{0}' auf '{1}' rebuilden (aktivieren)"
		'Constraints.IdxEnabled'             = "Index '{0}' auf '{1}' rebuilded/aktiviert."
		'Constraints.IdxEnableFailed'        = "Index '{0}' auf '{1}' konnte nicht rebuilded werden: {2}"
		'Constraints.DisabledIdxQueryFailed' = "Fehler beim Ermitteln deaktivierter Indizes auf '{0}': {1}"

		'ExportSchema.Start'                = "Scripte Metadaten von '{0}'.'{1}' fuer Tabelle(n): {2}"
		'ExportSchema.ConnectFailed'        = "Verbindung zu '{0}' fehlgeschlagen: {1}"
		'ExportSchema.DatabaseNotFound'     = "Datenbank '{0}' auf '{1}' nicht gefunden."
		'ExportSchema.PartitionedWarning'   = "{0}.{1}: Tabelle war partitioniert (Partitionsschema '{2}') - wird ohne Partitionierung auf dem Standard-Filegroup (PRIMARY) angelegt."
		'ExportSchema.ClrWarning'           = "{0}.{1}: Spalte '{2}' nutzt den CLR-Typ '{3}.{4}' - die zugehoerige Assembly muss manuell auf dem Ziel bereitgestellt werden."
		'ExportSchema.TablesNotFound'       = "Tabelle(n) nicht gefunden auf '{0}'.'{1}': {2}"
		'ExportSchema.ScriptingFailed'      = 'Scripting fehlgeschlagen: {0}'
		'ExportSchema.ScriptWritten'        = "Script geschrieben nach '{0}'."
		'ExportSchema.WriteFailed'          = "Konnte Script nicht nach '{0}' schreiben: {1}"
		'ExportSchema.Summary'              = '{0} Tabelle(n) erfolgreich gescriptet ({1} Batch(es), {2} Schema(s) abgesichert{3}).'
		'ExportSchema.PartitionRemovedSuffix' = ', Partitionierung entfernt'

		'NewTableFromScript.BatchAction'  = "Batch {0}/{1} auf '{2}'.'{3}' ausfuehren"
		'NewTableFromScript.BatchSuccess' = "Batch {0} erfolgreich ausgefuehrt auf '{1}'.'{2}'."
		'NewTableFromScript.BatchFailed'  = "Batch {0} fehlgeschlagen auf '{1}'.'{2}': {3}"
		'NewTableFromScript.BatchWhatIf'  = 'WhatIf: Batch wuerde ausgefuehrt.'
		'NewTableFromScript.Summary'      = "New-sqmTableFromScript abgeschlossen auf '{0}'.'{1}' - {2} Batch(es), {3} Fehler."

		'ExportReport.Written'           = "HTML-Bericht geschrieben nach '{0}'."
		'ExportReport.WriteFailedWarning' = "Konnte HTML-Bericht nicht nach '{0}' schreiben: {1}"
		'ExportReport.WriteFailedLog'    = "Fehler beim Schreiben des HTML-Berichts nach '{0}': {1}"

		'InvokeTransfer.Start'                        = "Start Invoke-sqmTableTransfer: '{0}'.'{1}' -> '{2}'.'{3}' | Tabellen: {4}"
		'InvokeTransfer.ProgressActivity'             = 'Tabellen werden uebertragen'
		'InvokeTransfer.ProgressStatus'               = 'Tabelle {0} von {1}: {2}'
		'InvokeTransfer.SkipCompletedChecking'        = 'SkipCompleted aktiv - pruefe {0} Tabelle(n) auf bereits abgeschlossenen Transfer.'
		'InvokeTransfer.SkipCompletedResultMsg'       = 'Quelle und Ziel haben bereits identische Zeilenzahl ({0}) - Transfer uebersprungen.'
		'InvokeTransfer.SkipCompletedSummary'         = 'SkipCompleted: {0} von {1} Tabelle(n) bereits vollstaendig - werden uebersprungen. Verbleibend: {2}.'
		'InvokeTransfer.SkipCompletedCheckFailedWarning' = 'SkipCompleted-Pruefung fehlgeschlagen, alle Tabellen werden regulaer verarbeitet: {0}'
		'InvokeTransfer.SkipCompletedCheckFailedLog'  = 'SkipCompleted-Pruefung fehlgeschlagen: {0}'
		'InvokeTransfer.ProcessingTable'              = "=== Verarbeite Tabelle '{0}' ==="
		'InvokeTransfer.TableExistsSkipped'           = "Tabelle existiert bereits auf '{0}'.'{1}' - wird nicht neu angelegt."
		'InvokeTransfer.TableExistsSkippedLog'        = "Tabelle '{0}' existiert bereits auf Ziel - Metadaten-Erstellung uebersprungen."
		'InvokeTransfer.CreateAction'                 = "Tabelle '{0}' auf '{1}'.'{2}' aus Quellmetadaten anlegen"
		'InvokeTransfer.TableNotFoundOnSource'        = "Tabelle '{0}' nicht auf Quelle '{1}'.'{2}' gefunden."
		'InvokeTransfer.BatchesFailed'                = '{0} von {1} Batch(es) fehlgeschlagen.'
		'InvokeTransfer.MetadataCreationFailed'       = "Metadaten-Erstellung fuer '{0}' fehlgeschlagen."
		'InvokeTransfer.TableCreated'                 = "Tabelle '{0}' auf Ziel angelegt ({1} Batch(es))."
		'InvokeTransfer.MetadataCreationError'        = "Fehler bei der Metadaten-Erstellung fuer '{0}': {1}"
		'InvokeTransfer.DisableAction'                = "FKs/Indizes auf '{0}'.'{1}'.[{2}] deaktivieren"
		'InvokeTransfer.ObjectsProcessed'             = '{0} Objekt(e) verarbeitet, {1} Fehler.'
		'InvokeTransfer.SkipConstraintHandlingSet'    = 'SkipConstraintHandling gesetzt.'
		'InvokeTransfer.RowsCopiedIn'                 = '{0} Zeile(n) in {1}s. {2}'
		'InvokeTransfer.DataCopyFailed'               = "Datenkopie fuer '{0}' fehlgeschlagen: {1}"
		'InvokeTransfer.CompareResult'                = 'Quelle={0} Ziel={1} Differenz={2}'
		'InvokeTransfer.CompareSkipped'                = 'Datenkopie nicht erfolgreich - Vergleich uebersprungen.'
		'InvokeTransfer.ProcessingError'              = "Fehler bei der Verarbeitung von '{0}': {1}"
		'InvokeTransfer.ReenableCritical'             = "KRITISCH: Re-Enable von FKs/Indizes fuer '{0}' fehlgeschlagen: {1}"
		'InvokeTransfer.Summary'                      = 'Invoke-sqmTableTransfer abgeschlossen - Erfolg: {0} | Fehler/Mismatch/NotFound: {1} | Warnungen/Uebersprungen: {2}'
		'InvokeTransfer.ReportFailed'                 = 'HTML-Bericht konnte nicht erzeugt werden: {0}'

		'Sync.Start'         = "=== Sync '{0}': '{1}'.'{2}' -> '{3}'.'{4}' ==="
		'Sync.NoPrimaryKey'  = "Keine PRIMARY KEY-Spalte(n) auf '{0}'.'{1}'.{2} gefunden - Sync-sqmTableData benoetigt einen PK."
		'Sync.Diff'          = 'Sync {0}: Quelle={1} Ziel={2} Neu={3} Geaendert={4} Geloescht={5}'
		'Sync.Action'        = "Sync '{0}': {1} neu, {2} geaendert, {3} geloescht"
		'Sync.Completed'     = "Sync '{0}' abgeschlossen: +{1} ~{2} -{3} ({4}s)."
		'Sync.Failed'        = "Sync fuer '{0}' fehlgeschlagen: {1}"

		'LoggingPath.NotWritable' = "Keine Schreibrechte auf '{0}' oder Pfad ungueltig: {1}"

		'Gui.Title'                 = 'sqmDataTransfer'
		'Gui.SourceGroup'           = 'Quelle (Source)'
		'Gui.DestinationGroup'      = 'Ziel (Destination)'
		'Gui.Instance'              = 'Instanz:'
		'Gui.Connect'               = 'Verbinden'
		'Gui.Database'              = 'Datenbank:'
		'Gui.SqlAuth'               = 'SQL-Authentifizierung'
		'Gui.Login'                 = 'Login:'
		'Gui.Password'              = 'Passwort:'
		'Gui.Connecting'            = 'Verbinde...'
		'Gui.Connected'             = 'verbunden ({0} DBs, {1})'
		'Gui.ConnectError'          = 'Fehler: {0}'
		'Gui.Tables'                = 'Tabellen:'
		'Gui.SelectAll'             = 'Alle'
		'Gui.SelectNone'            = 'Keine'
		'Gui.LoadTables'            = 'Tabellen laden'
		'Gui.ColTable'              = 'Tabelle'
		'Gui.ColAction'             = 'Aktion'
		'Gui.ColRowCount'           = 'Zeilen (Quelle)'
		'Gui.ActionTransfer'        = '-> Transfer'
		'Gui.ActionCreate'          = '+ Anlegen'
		'Gui.ActionUnknown'         = '?'
		'Gui.NoTablesFound'         = 'Keine Tabellen in dieser Datenbank gefunden.'
		'Gui.TablesLoadError'       = "Tabellen konnten nicht geladen werden:`n{0}"
		'Gui.OptionsGroup'          = 'Optionen'
		'Gui.ScriptMetadata'        = 'Fehlende Tabellen aus Quellmetadaten auf Ziel anlegen'
		'Gui.ToggleFks'             = 'Foreign Keys ein-/ausschalten'
		'Gui.ToggleIndexes'         = 'Indizes ein-/ausschalten'
		'Gui.KeepIdentity'          = 'Identity-Werte der Quelle beibehalten (KeepIdentity)'
		'Gui.Truncate'              = 'Zieltabelle vor Kopie leeren (TRUNCATE)'
		'Gui.Revalidate'            = 'FKs nach Aktivierung neu validieren (WITH CHECK)'
		'Gui.WhatIf'                = 'Nur simulieren (WhatIf)'
		'Gui.SkipCompleted'         = 'Bereits vollstaendige Tabellen ueberspringen (Wiederanlauf)'
		'Gui.BatchSize'             = 'Batchgroesse:'
		'Gui.ReportGroup'           = 'HTML-Bericht (wird immer erzeugt)'
		'Gui.ReportFolder'          = 'Zielordner:'
		'Gui.Browse'                = '...'
		'Gui.NoAutoOpen'            = 'Nicht automatisch oeffnen'
		'Gui.RunButton'             = 'Transfer starten'
		'Gui.CloseButton'           = 'Schliessen'
		'Gui.SelectAtLeastOneTable' = 'Bitte mindestens eine Tabelle auswaehlen.'
		'Gui.SpecifySourceAndDest'  = 'Bitte Quelle und Ziel (Instanz + Datenbank) angeben.'
		'Gui.TransferRunning'       = 'Transfer laeuft...'
		'Gui.TransferDone'          = 'Fertig - {0} Schritt(e), {1} mit Fehler/Mismatch/NotFound.'
		'Gui.TransferError'         = 'Fehler beim Transfer.'
		'Gui.TransferFailedBox'     = "Transfer fehlgeschlagen:`n{0}"
		'Gui.LogLabel'              = 'Protokoll:'
		'Gui.ResultLabel'           = 'Ergebnis (je Tabelle/Schritt):'
		'Gui.MessageBoxTitle'       = 'sqmDataTransfer'
	}
	en = @{
		'Common.WhatIf' = 'WhatIf: {0}'
		'Common.All'    = '(all)'

		'Compare.SourceError' = 'Source: {0}'
		'Compare.DestError'   = 'Target: {0}'
		'Compare.LogMessage'  = 'Row comparison [{0}] -> [{1}]: Source={2} Target={3} Match={4}{5}'
		'Compare.ErrorSuffix' = ' Error: {0}'

		'CompareDb.Start'     = "Comparing row counts for all tables: '{0}'.'{1}' -> '{2}'.'{3}' (metadata, no data scan)."
		'CompareDb.Summary'   = '{0} table(s) compared: {1} matching, {2} mismatched, {3} source-only, {4} destination-only.'
		'CompareDb.Verifying' = '{0} mismatched table(s) being re-checked with an exact COUNT_BIG(*).'

		'Copy.Action'           = "Copying data from '{0}'.'{1}'.[{2}] to '{3}'.'{4}'.[{5}]"
		'Copy.RowsCopied'       = '{0} row(s) copied: [{1}] -> [{2}] ({3}s).'
		'Copy.Failed'           = 'Data copy failed for [{0}]: {1}'
		'Copy.ProgressActivity' = 'Copying [{0}]'
		'Copy.ProgressStatus'   = '{0:N0} row(s) copied...'

		'CopySchema.TargetVersionDetected' = "Target '{0}' detected as SQL Server {1}.{2} -> TargetServerVersion {3}."
		'CopySchema.TargetVersionFailed'   = "Could not determine target version of '{0}' - scripting without TargetServerVersion (source syntax): {1}"
		'CopySchema.NoScript'              = "No script generated for {0} from '{1}'.'{2}' - table(s) not found: {3}."
		'CopySchema.CreateAction'          = "Creating {0} table(s) on '{1}'.'{2}': {3}"
		'CopySchema.SchemaGuardSuffix'     = ' (incl. schema safeguard: {0})'

		'Constraints.DisableFkAction'        = "Disabling foreign key '{0}' on '{1}'"
		'Constraints.FkDisabled'             = "FK '{0}' on '{1}' disabled."
		'Constraints.FkDisableFailed'        = "FK '{0}' on '{1}' could not be disabled: {2}"
		'Constraints.NoActiveFks'            = "No active foreign keys found on '{0}'."
		'Constraints.FkQueryFailed'          = "Error retrieving foreign keys on '{0}': {1}"
		'Constraints.DisableIdxAction'       = "Disabling index '{0}' on '{1}'"
		'Constraints.IdxDisabled'            = "Index '{0}' on '{1}' disabled."
		'Constraints.IdxDisableFailed'       = "Index '{0}' on '{1}' could not be disabled: {2}"
		'Constraints.NoActiveIndexes'        = "No active non-clustered indexes found on '{0}'."
		'Constraints.IdxQueryFailed'         = "Error retrieving indexes on '{0}': {1}"
		'Constraints.EnableFkAction'         = "Enabling foreign key '{0}' on '{1}' ({2})"
		'Constraints.FkEnabled'              = "FK '{0}' on '{1}' enabled ({2})."
		'Constraints.FkEnableFailed'         = "FK '{0}' on '{1}' could not be enabled: {2}"
		'Constraints.DisabledFkQueryFailed'  = "Error retrieving disabled foreign keys on '{0}': {1}"
		'Constraints.EnableIdxAction'        = "Rebuilding (enabling) index '{0}' on '{1}'"
		'Constraints.IdxEnabled'             = "Index '{0}' on '{1}' rebuilt/enabled."
		'Constraints.IdxEnableFailed'        = "Index '{0}' on '{1}' could not be rebuilt: {2}"
		'Constraints.DisabledIdxQueryFailed' = "Error retrieving disabled indexes on '{0}': {1}"

		'ExportSchema.Start'                = "Scripting metadata from '{0}'.'{1}' for table(s): {2}"
		'ExportSchema.ConnectFailed'        = "Connection to '{0}' failed: {1}"
		'ExportSchema.DatabaseNotFound'     = "Database '{0}' not found on '{1}'."
		'ExportSchema.PartitionedWarning'   = "{0}.{1}: table was partitioned (partition scheme '{2}') - will be created without partitioning on the default filegroup (PRIMARY)."
		'ExportSchema.ClrWarning'           = "{0}.{1}: column '{2}' uses CLR type '{3}.{4}' - the corresponding assembly has to be deployed on the target manually."
		'ExportSchema.TablesNotFound'       = "Table(s) not found on '{0}'.'{1}': {2}"
		'ExportSchema.ScriptingFailed'      = 'Scripting failed: {0}'
		'ExportSchema.ScriptWritten'        = "Script written to '{0}'."
		'ExportSchema.WriteFailed'          = "Could not write script to '{0}': {1}"
		'ExportSchema.Summary'              = '{0} table(s) scripted successfully ({1} batch(es), {2} schema(s) safeguarded{3}).'
		'ExportSchema.PartitionRemovedSuffix' = ', partitioning removed'

		'NewTableFromScript.BatchAction'  = "Running batch {0}/{1} on '{2}'.'{3}'"
		'NewTableFromScript.BatchSuccess' = "Batch {0} executed successfully on '{1}'.'{2}'."
		'NewTableFromScript.BatchFailed'  = "Batch {0} failed on '{1}'.'{2}': {3}"
		'NewTableFromScript.BatchWhatIf'  = 'WhatIf: batch would be executed.'
		'NewTableFromScript.Summary'      = "New-sqmTableFromScript completed on '{0}'.'{1}' - {2} batch(es), {3} error(s)."

		'ExportReport.Written'           = "HTML report written to '{0}'."
		'ExportReport.WriteFailedWarning' = "Could not write HTML report to '{0}': {1}"
		'ExportReport.WriteFailedLog'    = "Error writing HTML report to '{0}': {1}"

		'InvokeTransfer.Start'                        = "Start Invoke-sqmTableTransfer: '{0}'.'{1}' -> '{2}'.'{3}' | Tables: {4}"
		'InvokeTransfer.ProgressActivity'             = 'Transferring tables'
		'InvokeTransfer.ProgressStatus'               = 'Table {0} of {1}: {2}'
		'InvokeTransfer.SkipCompletedChecking'        = 'SkipCompleted active - checking {0} table(s) for an already-completed transfer.'
		'InvokeTransfer.SkipCompletedResultMsg'       = 'Source and target already have identical row counts ({0}) - transfer skipped.'
		'InvokeTransfer.SkipCompletedSummary'         = 'SkipCompleted: {0} of {1} table(s) already complete - being skipped. Remaining: {2}.'
		'InvokeTransfer.SkipCompletedCheckFailedWarning' = 'SkipCompleted check failed, all tables will be processed normally: {0}'
		'InvokeTransfer.SkipCompletedCheckFailedLog'  = 'SkipCompleted check failed: {0}'
		'InvokeTransfer.ProcessingTable'              = "=== Processing table '{0}' ==="
		'InvokeTransfer.TableExistsSkipped'           = "Table already exists on '{0}'.'{1}' - will not be recreated."
		'InvokeTransfer.TableExistsSkippedLog'        = "Table '{0}' already exists on target - metadata creation skipped."
		'InvokeTransfer.CreateAction'                 = "Creating table '{0}' on '{1}'.'{2}' from source metadata"
		'InvokeTransfer.TableNotFoundOnSource'        = "Table '{0}' not found on source '{1}'.'{2}'."
		'InvokeTransfer.BatchesFailed'                = '{0} of {1} batch(es) failed.'
		'InvokeTransfer.MetadataCreationFailed'       = "Metadata creation for '{0}' failed."
		'InvokeTransfer.TableCreated'                 = "Table '{0}' created on target ({1} batch(es))."
		'InvokeTransfer.MetadataCreationError'        = "Error creating metadata for '{0}': {1}"
		'InvokeTransfer.DisableAction'                = "Disabling FKs/indexes on '{0}'.'{1}'.[{2}]"
		'InvokeTransfer.ObjectsProcessed'             = '{0} object(s) processed, {1} error(s).'
		'InvokeTransfer.SkipConstraintHandlingSet'    = 'SkipConstraintHandling set.'
		'InvokeTransfer.RowsCopiedIn'                 = '{0} row(s) in {1}s. {2}'
		'InvokeTransfer.DataCopyFailed'               = "Data copy for '{0}' failed: {1}"
		'InvokeTransfer.CompareResult'                = 'Source={0} Target={1} Difference={2}'
		'InvokeTransfer.CompareSkipped'                = 'Data copy not successful - comparison skipped.'
		'InvokeTransfer.ProcessingError'              = "Error processing '{0}': {1}"
		'InvokeTransfer.ReenableCritical'             = "CRITICAL: re-enabling FKs/indexes for '{0}' failed: {1}"
		'InvokeTransfer.Summary'                      = 'Invoke-sqmTableTransfer completed - Success: {0} | Failed/Mismatch/NotFound: {1} | Warnings/Skipped: {2}'
		'InvokeTransfer.ReportFailed'                 = 'HTML report could not be generated: {0}'

		'Sync.Start'         = "=== Sync '{0}': '{1}'.'{2}' -> '{3}'.'{4}' ==="
		'Sync.NoPrimaryKey'  = "No PRIMARY KEY column(s) found on '{0}'.'{1}'.{2} - Sync-sqmTableData requires a PK."
		'Sync.Diff'          = 'Sync {0}: Source={1} Target={2} New={3} Changed={4} Deleted={5}'
		'Sync.Action'        = "Sync '{0}': {1} new, {2} changed, {3} deleted"
		'Sync.Completed'     = "Sync '{0}' completed: +{1} ~{2} -{3} ({4}s)."
		'Sync.Failed'        = "Sync for '{0}' failed: {1}"

		'LoggingPath.NotWritable' = "No write permission on '{0}' or path invalid: {1}"

		'Gui.Title'                 = 'sqmDataTransfer'
		'Gui.SourceGroup'           = 'Source'
		'Gui.DestinationGroup'      = 'Destination'
		'Gui.Instance'              = 'Instance:'
		'Gui.Connect'               = 'Connect'
		'Gui.Database'              = 'Database:'
		'Gui.SqlAuth'               = 'SQL Authentication'
		'Gui.Login'                 = 'Login:'
		'Gui.Password'              = 'Password:'
		'Gui.Connecting'            = 'Connecting...'
		'Gui.Connected'             = 'connected ({0} DBs, {1})'
		'Gui.ConnectError'          = 'Error: {0}'
		'Gui.Tables'                = 'Tables:'
		'Gui.SelectAll'             = 'All'
		'Gui.SelectNone'            = 'None'
		'Gui.LoadTables'            = 'Load tables'
		'Gui.ColTable'              = 'Table'
		'Gui.ColAction'             = 'Action'
		'Gui.ColRowCount'           = 'Rows (source)'
		'Gui.ActionTransfer'        = '-> Transfer'
		'Gui.ActionCreate'          = '+ Create'
		'Gui.ActionUnknown'         = '?'
		'Gui.NoTablesFound'         = 'No tables found in this database.'
		'Gui.TablesLoadError'       = "Could not load tables:`n{0}"
		'Gui.OptionsGroup'          = 'Options'
		'Gui.ScriptMetadata'        = 'Create missing tables on target from source metadata'
		'Gui.ToggleFks'             = 'Enable/disable foreign keys'
		'Gui.ToggleIndexes'         = 'Enable/disable indexes'
		'Gui.KeepIdentity'          = "Keep source's IDENTITY values (KeepIdentity)"
		'Gui.Truncate'              = 'Empty target table before copying (TRUNCATE)'
		'Gui.Revalidate'            = 'Revalidate FKs on re-enable (WITH CHECK)'
		'Gui.WhatIf'                = 'Simulate only (WhatIf)'
		'Gui.SkipCompleted'         = 'Skip already-complete tables (resume)'
		'Gui.BatchSize'             = 'Batch size:'
		'Gui.ReportGroup'           = 'HTML report (always generated)'
		'Gui.ReportFolder'          = 'Target folder:'
		'Gui.Browse'                = '...'
		'Gui.NoAutoOpen'            = "Don't open automatically"
		'Gui.RunButton'             = 'Start transfer'
		'Gui.CloseButton'           = 'Close'
		'Gui.SelectAtLeastOneTable' = 'Please select at least one table.'
		'Gui.SpecifySourceAndDest'  = 'Please specify source and destination (instance + database).'
		'Gui.TransferRunning'       = 'Transfer running...'
		'Gui.TransferDone'          = 'Done - {0} step(s), {1} with error/mismatch/not-found.'
		'Gui.TransferError'         = 'Transfer failed.'
		'Gui.TransferFailedBox'     = "Transfer failed:`n{0}"
		'Gui.LogLabel'              = 'Log:'
		'Gui.ResultLabel'           = 'Result (per table/step):'
		'Gui.MessageBoxTitle'       = 'sqmDataTransfer'
	}
}
