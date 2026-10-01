/* ============================================================================================
   sqmDataTransfer - Sammelskript zur Diagnose von ASYNC_NETWORK_IO waehrend eines Chunk-Transfers

   ZWECK
   Ein reproduzierbarer Einbruch bei immer derselben ZEILENZAHL (nicht zur selben Uhrzeit) ist
   mengenabhaengig, nicht lastabhaengig. Dieses Skript sammelt in einem Durchgang alles, was
   noetig ist, um die in Frage kommenden Ursachen auseinanderzuhalten, ohne Rueckfragen.

   KOSTEN
   Alle Abfragen lesen ausschliesslich Metadaten und DMVs. Kein Datenscan, kein Zugriff auf die
   Nutztabelle, keine Beeinflussung des Buffer Pools. Laufzeit: unter einer Sekunde, ABZUEGLICH
   Abschnitt 7, der bewusst 60 Sekunden misst (reines WAITFOR, keine Last).
   Abschnitt 4 (index_physical_stats) ist der EINZIGE potenziell teurere Teil, laeuft im Modus
   LIMITED und ist bewusst auskommentiert - erst einschalten, wenn Abschnitt 2 einen Clustered
   Index zeigt und die Fragmentierung wirklich die offene Frage ist.

   ANWENDUNG
   Abschnitte 1-8 und 10 auf dem ZIEL ausfuehren (das Skript wechselt per USE selbst in die
   Zieldatenbank), Abschnitt 9 auf der QUELLE.
   Am besten WAEHREND der Transfer laeuft und der Einbruch bereits sichtbar ist.
   Alle Ergebnisgitter zurueckschicken.

   Platzhalter vorher ersetzen:
     $(ZielDatenbank)  z.B. Zieldatenbank
     $(Schema)         z.B. dbo
     $(Tabelle)        die Zieltabelle des Transfers
     $(ChunkSpalte)    die im Log genannte Chunk-Spalte
   ============================================================================================ */

SET NOCOUNT ON;

-- Ohne diesen Kontextwechsel liefern OBJECT_ID, sys.dm_db_partition_stats und
-- sys.dm_db_log_space_usage Werte der aktuellen Datenbank (z.B. master) statt der Zieldatenbank.
USE [$(ZielDatenbank)];

DECLARE @db     sysname = N'$(ZielDatenbank)';
DECLARE @schema sysname = N'$(Schema)';
DECLARE @table  sysname = N'$(Tabelle)';
DECLARE @chunk  sysname = N'$(ChunkSpalte)';
DECLARE @object_id int  = OBJECT_ID(QUOTENAME(@schema) + N'.' + QUOTENAME(@table));

/* -----------------------------------------------------------------------------------------
   1) Eckdaten des Ziels: wie voll ist die Tabelle jetzt, wie gross ist sie
   Metadaten, kein Scan.
   ----------------------------------------------------------------------------------------- */
SELECT  N'1_Zieltabelle' AS Abschnitt,
        @schema                                       AS SchemaName,
        @table                                        AS TabellenName,
        SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END)          AS Zeilen,
        SUM(ps.reserved_page_count) * 8.0 / 1024 / 1024                            AS ReserviertGB,
        SUM(ps.in_row_data_page_count) * 8.0 / 1024 / 1024                         AS DatenGB
FROM sys.dm_db_partition_stats ps
WHERE ps.object_id = @object_id;

/* -----------------------------------------------------------------------------------------
   2) DIE Kernfrage: Heap oder Clustered Index, und passt der Clustered Key zur Einfuegereihenfolge
   Das Modul deaktiviert nur NONCLUSTERED-Indizes. Ein Clustered Index bleibt fuer den gesamten
   Lauf aktiv. Fuehrt sein Schluessel NICHT mit der Chunk-Spalte, streuen die Einfuegungen ueber
   die gesamte Tabelle: solange sie in den Buffer Pool passt, faellt das nicht auf, danach wird
   aus jedem Insert ein physischer Lesevorgang plus moeglicher Page Split. Genau das ergibt einen
   Einbruch bei immer derselben Zeilenzahl.
   IstFuehrendeChunkSpalte = 1 ist gut (Anhaengen), 0 ist der Verdachtsfall.
   ----------------------------------------------------------------------------------------- */
SELECT  N'2_Indexstruktur' AS Abschnitt,
        i.index_id,
        i.name                                          AS IndexName,
        i.type_desc                                     AS Typ,
        i.is_disabled                                   AS IstDeaktiviert,
        i.fill_factor                                   AS Fuellfaktor,
        STUFF((SELECT N', ' + c2.name
               FROM sys.index_columns ic2
               JOIN sys.columns c2 ON c2.object_id = ic2.object_id AND c2.column_id = ic2.column_id
               WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id AND ic2.is_included_column = 0
               ORDER BY ic2.key_ordinal
               FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'') AS SchluesselSpalten,
        CASE WHEN EXISTS (SELECT 1
                          FROM sys.index_columns ic3
                          JOIN sys.columns c3 ON c3.object_id = ic3.object_id AND c3.column_id = ic3.column_id
                          WHERE ic3.object_id = i.object_id AND ic3.index_id = i.index_id
                            AND ic3.key_ordinal = 1 AND c3.name = @chunk)
             THEN 1 ELSE 0 END                          AS IstFuehrendeChunkSpalte
FROM sys.indexes i
WHERE i.object_id = @object_id
ORDER BY i.index_id;

/* -----------------------------------------------------------------------------------------
   3) Recovery Model und Log: ist der Bulk-Insert ueberhaupt minimal geloggt
   SqlBulkCopy laeuft hier mit TABLOCK. Minimal geloggt wird aber nur unter SIMPLE/BULK_LOGGED -
   und bei einer Zieltabelle MIT Clustered Index, die bereits Daten enthaelt, greift die minimale
   Protokollierung ohnehin nur eingeschraenkt. Unter FULL wird jede der 370 Mio. Zeilen voll
   protokolliert; das Log waechst, bis es an eine Wand laeuft - wieder mengenabhaengig.
   ----------------------------------------------------------------------------------------- */
SELECT  N'3_Datenbank' AS Abschnitt,
        d.name                          AS Datenbank,
        d.recovery_model_desc           AS RecoveryModel,
        d.log_reuse_wait_desc           AS LogReuseWait,
        d.is_auto_shrink_on             AS AutoShrink,
        d.delayed_durability_desc       AS DelayedDurability,
        (SELECT MAX(bs.backup_finish_date) FROM msdb.dbo.backupset bs
          WHERE bs.database_name = d.name AND bs.type = 'L')  AS LetztesLogBackup
FROM sys.databases d
WHERE d.name = @db;

SELECT  N'3b_Dateien' AS Abschnitt,
        mf.name                                   AS LogischerName,
        mf.type_desc                              AS Typ,
        mf.physical_name                          AS Pfad,
        mf.size * 8.0 / 1024 / 1024               AS GroesseGB,
        CASE WHEN mf.max_size = -1 THEN NULL ELSE mf.max_size * 8.0 / 1024 / 1024 END AS MaxGB,
        CASE WHEN mf.is_percent_growth = 1
             THEN CONCAT(mf.growth, N' %')
             ELSE CONCAT(mf.growth * 8.0 / 1024, N' MB') END  AS Autogrowth
FROM sys.master_files mf
WHERE mf.database_id = DB_ID(@db);

/* Logauslastung und VLF-Anzahl - viele kleine VLFs bremsen jedes Logwachstum zusaetzlich. */
SELECT  N'3c_Log' AS Abschnitt,
        lsu.total_log_size_in_bytes / 1024.0 / 1024 / 1024   AS LogGroesseGB,
        lsu.used_log_space_in_percent                        AS LogGenutztProzent,
        (SELECT COUNT(*) FROM sys.dm_db_log_info(DB_ID(@db))) AS AnzahlVLF
FROM sys.dm_db_log_space_usage lsu;

/* Freier Platz auf den Laufwerken der Daten- und Logdateien. Laeuft ein Laufwerk voll, haengt
   der Bulk-Insert (bzw. bricht mit 1105/9002 ab) - typischerweise erst nach einer bestimmten
   Datenmenge, also wieder "nach ~100 Mio. Zeilen". */
SELECT DISTINCT N'3d_Laufwerke' AS Abschnitt,
        vs.volume_mount_point                         AS Laufwerk,
        vs.total_bytes     / 1024.0 / 1024 / 1024     AS GesamtGB,
        vs.available_bytes / 1024.0 / 1024 / 1024     AS FreiGB,
        CAST(100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0) AS decimal(5,1)) AS FreiProzent
FROM sys.master_files mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
WHERE mf.database_id IN (DB_ID(@db), DB_ID(N'tempdb'));

/* Instant File Initialization: ohne IFI muss jedes Wachstum der DATENdatei erst mit Nullen
   beschrieben werden - bei 1-GB-Schritten und langsamem Storage jedesmal Sekunden bis Minuten,
   in denen der Insert steht (Wartetyp PREEMPTIVE_OS_WRITEFILEGATHER). Logdateien werden immer
   genullt, IFI hilft dort nicht (ausser SQL 2022 bis 64 MB). */
SELECT  N'3e_InstantFileInit' AS Abschnitt, servicename, service_account,
        instant_file_initialization_enabled
FROM sys.dm_server_services
WHERE servicename LIKE N'SQL Server (%';

/* Autogrowth-Ereignisse der letzten Zeit aus dem Default Trace, mit Dauer. Haeufen sich lange
   Wachstumsvorgaenge genau zu den Zeiten, in denen der Transfer "haengt", ist das die Ursache.
   Liest nur die Default-Trace-Dateien (wenige MB), keine Nutzdaten. */
DECLARE @trace nvarchar(260) = (SELECT TOP (1) path FROM sys.traces WHERE is_default = 1);
IF @trace IS NOT NULL
    SELECT TOP (50) N'3f_Autogrowth' AS Abschnitt,
            te.name                          AS Ereignis,
            t.FileName                       AS Datei,
            t.StartTime,
            t.Duration / 1000                AS DauerMs,
            t.IntegerData * 8 / 1024         AS WachstumMB
    FROM sys.fn_trace_gettable(REVERSE(SUBSTRING(REVERSE(@trace), CHARINDEX(CHAR(92), REVERSE(@trace)), 260)) + N'log.trc', DEFAULT) t
    JOIN sys.trace_events te ON te.trace_event_id = t.EventClass
    WHERE t.EventClass IN (92, 93) AND t.DatabaseName IN (@db, N'tempdb')
    ORDER BY t.StartTime DESC;
ELSE
    SELECT N'3f_Autogrowth' AS Abschnitt, N'Default Trace ist deaktiviert' AS Hinweis;

/* -----------------------------------------------------------------------------------------
   4) OPTIONAL und nur bei Bedarf einschalten: Fragmentierung des Clustered Index.
      LIMITED liest nur die Zwischenebenen, ist aber auf einer Tabelle dieser Groesse trotzdem
      spuerbar. Erst ausfuehren, wenn Abschnitt 2 einen Clustered Index zeigt, der NICHT mit der
      Chunk-Spalte fuehrt, und die Page Splits belegt werden sollen.
   ----------------------------------------------------------------------------------------- */
-- SELECT N'4_Fragmentierung' AS Abschnitt, index_id, avg_fragmentation_in_percent, avg_page_space_used_in_percent, page_count
-- FROM sys.dm_db_index_physical_stats(DB_ID(@db), @object_id, NULL, NULL, 'LIMITED');

/* -----------------------------------------------------------------------------------------
   5) IO-Stalls je Datei: liegt die Wartezeit auf den Daten- oder auf den Logdateien
   Kumulativ seit Instanzstart, daher nur im Verhaeltnis der Dateien zueinander zu lesen.
   ----------------------------------------------------------------------------------------- */
SELECT  N'5_IOStalls' AS Abschnitt,
        mf.name                                            AS LogischerName,
        mf.type_desc                                       AS Typ,
        vfs.num_of_reads                                   AS Lesevorgaenge,
        vfs.num_of_writes                                  AS Schreibvorgaenge,
        vfs.io_stall_read_ms                               AS StallLesenMs,
        vfs.io_stall_write_ms                              AS StallSchreibenMs,
        CASE WHEN vfs.num_of_reads  > 0 THEN vfs.io_stall_read_ms  * 1.0 / vfs.num_of_reads  END AS MsProLesen,
        CASE WHEN vfs.num_of_writes > 0 THEN vfs.io_stall_write_ms * 1.0 / vfs.num_of_writes END AS MsProSchreiben
FROM sys.dm_io_virtual_file_stats(DB_ID(@db), NULL) vfs
JOIN sys.master_files mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id;

/* -----------------------------------------------------------------------------------------
   6) Momentaufnahme der laufenden Sitzungen: worauf wartet der Bulk-Insert JETZT
   ----------------------------------------------------------------------------------------- */
SELECT  N'6_LaufendeAnfragen' AS Abschnitt,
        r.session_id, r.status, r.command,
        r.wait_type, r.wait_time, r.last_wait_type, r.wait_resource,
        r.cpu_time, r.total_elapsed_time, r.reads, r.writes, r.logical_reads,
        r.granted_query_memory,
        s.host_name, s.program_name, s.login_name,
        SUBSTRING(t.text, 1, 300) AS Anfang
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id <> @@SPID AND s.is_user_process = 1;

SELECT  N'6b_WartendeTasks' AS Abschnitt,
        wt.session_id, wt.wait_type, wt.wait_duration_ms, wt.blocking_session_id, wt.resource_description
FROM sys.dm_os_waiting_tasks wt
WHERE wt.session_id <> @@SPID;

/* Speicher-Grants: wartet eine Anfrage auf Arbeitsspeicher (RESOURCE_SEMAPHORE), z.B. fuer die
   Sortierung eines Bulk-Inserts in einen Clustered Index? */
SELECT  N'6c_SpeicherGrants' AS Abschnitt, mg.session_id, mg.requested_memory_kb, mg.granted_memory_kb,
        mg.used_memory_kb, mg.wait_time_ms, mg.queue_id, mg.dop
FROM sys.dm_exec_query_memory_grants mg
WHERE mg.session_id <> @@SPID;

/* tempdb-Verbrauch je Sitzung (Sortier-Spills, Versionsspeicher). Waechst er mit dem Transfer,
   laeuft irgendwann tempdb voll. */
SELECT  N'6d_TempdbJeSitzung' AS Abschnitt, su.session_id,
        (SUM(su.user_objects_alloc_page_count)     - SUM(su.user_objects_dealloc_page_count))     * 8 / 1024 AS UserObjekteMB,
        (SUM(su.internal_objects_alloc_page_count) - SUM(su.internal_objects_dealloc_page_count)) * 8 / 1024 AS InterneObjekteMB
FROM sys.dm_db_task_space_usage su
WHERE su.session_id <> @@SPID
GROUP BY su.session_id
HAVING SUM(su.user_objects_alloc_page_count) + SUM(su.internal_objects_alloc_page_count) > 0;

/* -----------------------------------------------------------------------------------------
   7) Wait-Delta ueber 60 Sekunden - die eigentlich entscheidende Messung
   Kumulative Waits seit Instanzstart sagen bei einem seit Stunden laufenden Transfer nichts.
   Diese Differenzmessung zeigt, worauf das Ziel GERADE wartet:
     WRITELOG / LOGBUFFER              -> Log ist der Engpass (siehe Abschnitt 3)
     PAGEIOLATCH_*                     -> Datenseiten muessen gelesen werden, Buffer Pool zu klein
                                          fuer die inzwischen erreichte Tabellengroesse
     ASYNC_NETWORK_IO auf dem ZIEL     -> das Ziel wartet auf den Client, der Engpass liegt davor
     BACKUPIO / BACKUPBUFFER           -> ein paralleles Backup laeuft mit
     PREEMPTIVE_OS_WRITEFILEGATHER     -> Datei-Wachstum mit Nullschreiben (siehe 3e/3f)
     RESOURCE_SEMAPHORE                -> Anfrage wartet auf Arbeitsspeicher (siehe 6c)
     LCK_M_*                           -> Blockierung (siehe 6b, blocking_session_id)
     CXPACKET/CXCONSUMER, SOS_SCHEDULER_YIELD -> CPU-Konkurrenz durch Fremdlast
   Kostet exakt 60 Sekunden Wartezeit und sonst nichts.
   ----------------------------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#w1') IS NOT NULL DROP TABLE #w1;
SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
INTO #w1 FROM sys.dm_os_wait_stats;

WAITFOR DELAY '00:01:00';

SELECT TOP (25)
        N'7_WaitDelta60s' AS Abschnitt,
        w2.wait_type,
        w2.waiting_tasks_count - w1.waiting_tasks_count      AS Wartevorgaenge,
        w2.wait_time_ms        - w1.wait_time_ms             AS WartezeitMs,
        w2.signal_wait_time_ms - w1.signal_wait_time_ms      AS SignalWartezeitMs
FROM sys.dm_os_wait_stats w2
JOIN #w1 w1 ON w1.wait_type = w2.wait_type
WHERE w2.wait_time_ms - w1.wait_time_ms > 0
  AND w2.wait_type NOT IN (
        N'CLR_SEMAPHORE', N'LAZYWRITER_SLEEP', N'RESOURCE_QUEUE', N'SLEEP_TASK',
        N'SLEEP_SYSTEMTASK', N'SQLTRACE_BUFFER_FLUSH', N'WAITFOR', N'LOGMGR_QUEUE',
        N'CHECKPOINT_QUEUE', N'REQUEST_FOR_DEADLOCK_SEARCH', N'XE_TIMER_EVENT',
        N'BROKER_TO_FLUSH', N'BROKER_TASK_STOP', N'CLR_MANUAL_EVENT', N'CLR_AUTO_EVENT',
        N'DISPATCHER_QUEUE_SEMAPHORE', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'XE_DISPATCHER_WAIT',
        N'XE_DISPATCHER_JOIN', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'DIRTY_PAGE_POLL',
        N'SP_SERVER_DIAGNOSTICS_SLEEP', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE', N'QDS_SHUTDOWN_QUEUE',
        N'PREEMPTIVE_XE_DISPATCHER', N'SOS_WORK_DISPATCHER')
ORDER BY WartezeitMs DESC;

/* -----------------------------------------------------------------------------------------
   8) Speicher- und Checkpoint-Kennzahlen: reicht der Buffer Pool noch
   Page life expectancy, die faellt, waehrend der Transfer laeuft, ist der Beleg dafuer, dass die
   Zieltabelle den Buffer Pool verdraengt - der klassische Ausloeser fuer den Kipppunkt.
   ----------------------------------------------------------------------------------------- */
SELECT  N'8_Speicher' AS Abschnitt, object_name, counter_name, instance_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name IN (N'Page life expectancy', N'Checkpoint pages/sec', N'Lazy writes/sec',
                       N'Log Flush Wait Time', N'Log Flush Waits/sec', N'Page Splits/sec',
                       N'Free list stalls/sec', N'Target Server Memory (KB)', N'Total Server Memory (KB)')
  AND (instance_name IN (N'', N'_Total') OR instance_name = @db);

/* =========================================================================================
   9) AUF DER QUELLE ausfuehren
   Zeigt ASYNC_NETWORK_IO auf der QUELLE, dann hat die Quelle Zeilen bereit, die der Client
   nicht abholt - weil er im SqlBulkCopy auf das Ziel wartet. Der Engpass liegt dann NICHT hier.
   Zeigt die Quelle dagegen PAGEIOLATCH oder CXPACKET, ist das Lesen der Chunks das Problem
   (z.B. fehlender Index auf der Chunk-Spalte, sodass jeder Chunk die Tabelle voll scannt).
   ========================================================================================= */
/*
IF OBJECT_ID('tempdb..#s1') IS NOT NULL DROP TABLE #s1;
SELECT wait_type, waiting_tasks_count, wait_time_ms INTO #s1 FROM sys.dm_os_wait_stats;
WAITFOR DELAY '00:01:00';
SELECT TOP (15) N'9_QuelleWaitDelta60s' AS Abschnitt, s2.wait_type,
       s2.waiting_tasks_count - s1.waiting_tasks_count AS Wartevorgaenge,
       s2.wait_time_ms - s1.wait_time_ms               AS WartezeitMs
FROM sys.dm_os_wait_stats s2 JOIN #s1 s1 ON s1.wait_type = s2.wait_type
WHERE s2.wait_time_ms - s1.wait_time_ms > 0
  AND s2.wait_type NOT IN (N'WAITFOR', N'LAZYWRITER_SLEEP', N'SLEEP_TASK', N'DIRTY_PAGE_POLL',
                           N'LOGMGR_QUEUE', N'CHECKPOINT_QUEUE', N'REQUEST_FOR_DEADLOCK_SEARCH',
                           N'XE_TIMER_EVENT', N'SOS_WORK_DISPATCHER', N'QDS_ASYNC_QUEUE')
ORDER BY WartezeitMs DESC;

-- Gibt es auf der QUELLE ueberhaupt einen Index auf der Chunk-Spalte? Ohne ihn scannt jeder
-- einzelne Chunk die gesamte Quelltabelle. Metadaten, kein Scan.
SELECT N'9b_QuellIndexAufChunkSpalte' AS Abschnitt, i.name AS IndexName, i.type_desc,
       ic.key_ordinal, i.is_disabled
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'$(Schema).$(Tabelle)') AND c.name = N'$(ChunkSpalte)';
*/
