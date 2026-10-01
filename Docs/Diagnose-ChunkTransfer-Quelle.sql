/* ============================================================================================
   sqmDataTransfer - Diagnose auf der QUELLE, wenn die Ziel-Session (INSERT BULK) auf
   ASYNC_NETWORK_IO wartet

   ZWECK
   ASYNC_NETWORK_IO an der INSERT-BULK-Session heisst: das Ziel hat alles geschrieben und wartet
   auf das naechste Datenpaket vom Client. Der Engpass liegt also VOR dem Ziel, entweder beim
   Lesen auf der Quelle oder im Client-Prozess (PowerShell/SqlBulkCopy). Dieses Skript zeigt fuer
   die lesende Session auf der Quelle:
     - worauf sie gerade wartet,
     - ob der Chunk per Table/Index Scan oder per Seek gelesen wird,
     - wie viele Seiten der Scan schon gelesen hat, im Verhaeltnis zur Tabellengroesse,
     - wie viele Zeilen er bisher geliefert hat.

   Lesart:
     Quelle wartet auf ASYNC_NETWORK_IO
        -> die Quelle hat Zeilen bereit, der CLIENT holt sie nicht ab: Engpass im Client
           (CPU/Speicher des PowerShell-Prozesses pruefen, siehe unten).
     Quelle wartet auf PAGEIOLATCH_SH / CXPACKET / CXCONSUMER, Plan = Table Scan,
     GeleseneSeiten waechst, GelieferteZeilen kaum
        -> jeder Chunk liest die gesamte Tabelle, um die Zeilen eines Monats zu finden. Der Client
           wartet auf die Quelle, das Ziel wartet auf den Client.

   KOSTEN
   Nur DMVs, kein Datenzugriff. sys.dm_exec_query_profiles liefert Zeilenzahlen je Planoperator,
   wenn Lightweight Query Profiling aktiv ist (Standard ab SQL Server 2019, ab 2016 SP1 per
   Trace-Flag 7412); sonst bleibt Abschnitt Q3 leer, Q1/Q2 reichen dann trotzdem.

   ANWENDUNG
   Auf der QUELLE ausfuehren, WAEHREND der Transfer haengt. Platzhalter ersetzen:
     $(QuellDatenbank)  Quelldatenbank
     $(Schema)          z.B. dbo
     $(Tabelle)         Quelltabelle
   ============================================================================================ */

SET NOCOUNT ON;
USE [$(QuellDatenbank)];

DECLARE @object_id int = OBJECT_ID(N'[$(Schema)].[$(Tabelle)]');

/* Q0) Groesse der Quelltabelle - Referenz fuer den Scan-Fortschritt in Q3 */
SELECT  N'Q0_Quelltabelle' AS Abschnitt,
        SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END)            AS Zeilen,
        SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.in_row_data_page_count ELSE 0 END) AS DatenSeiten,
        SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.reserved_page_count ELSE 0 END) * 8.0 / 1024 / 1024 AS ReserviertGB,
        MAX(CASE WHEN ps.index_id = 0 THEN 1 ELSE 0 END)                              AS IstHeap
FROM sys.dm_db_partition_stats ps
WHERE ps.object_id = @object_id;

/* Q1) Die lesende Session des Transfers: SELECT ... FROM <Quelltabelle> WHERE <Chunk> */
SELECT  N'Q1_LesendeSession' AS Abschnitt,
        r.session_id, r.status, r.wait_type, r.wait_time AS WartezeitMs, r.last_wait_type,
        r.total_elapsed_time / 1000 AS LaufzeitSek, r.cpu_time AS CpuMs,
        r.reads AS PhysischeLesevorgaenge, r.logical_reads AS LogischeLesevorgaenge,
        r.row_count AS ZeilenBisher, r.dop,
        s.host_name, s.program_name,
        SUBSTRING(t.text, 1, 300) AS Abfrage
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id <> @@SPID
  AND t.text LIKE N'%$(Tabelle)%'
  AND t.text LIKE N'SELECT%';

/* Q2) Wie wird gelesen: Scan oder Seek? (Plan der laufenden Anfrage) */
SELECT  N'Q2_Zugriffsart' AS Abschnitt,
        r.session_id,
        CASE WHEN CAST(qp.query_plan AS nvarchar(max)) LIKE N'%PhysicalOp="Table Scan"%'           THEN N'Table Scan (Heap)'
             WHEN CAST(qp.query_plan AS nvarchar(max)) LIKE N'%PhysicalOp="Clustered Index Scan"%' THEN N'Clustered Index Scan'
             WHEN CAST(qp.query_plan AS nvarchar(max)) LIKE N'%PhysicalOp="Index Seek"%'
              AND CAST(qp.query_plan AS nvarchar(max)) LIKE N'%PhysicalOp="RID Lookup"%'           THEN N'Index Seek + RID Lookup'
             WHEN CAST(qp.query_plan AS nvarchar(max)) LIKE N'%PhysicalOp="Index Seek"%'           THEN N'Index Seek'
             WHEN CAST(qp.query_plan AS nvarchar(max)) LIKE N'%PhysicalOp="Clustered Index Seek"%' THEN N'Clustered Index Seek'
             ELSE N'anderes - query_plan ansehen' END AS Zugriffsart,
        qp.query_plan
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE r.session_id <> @@SPID
  AND t.text LIKE N'%$(Tabelle)%'
  AND t.text LIKE N'SELECT%';

/* Q3) Live-Fortschritt je Planoperator: gelesene Seiten gegen Tabellengroesse (Q0), gelieferte
   Zeilen. Viele gelesene Seiten bei wenig gelieferten Zeilen = der Scan sucht die Zeilen des
   Chunks in der ganzen Tabelle. */
SELECT  N'Q3_ScanFortschritt' AS Abschnitt,
        qp.session_id, qp.node_id, qp.physical_operator_name AS Operator,
        OBJECT_NAME(qp.object_id) AS Objekt, qp.index_id,
        SUM(qp.row_count)            AS GelieferteZeilen,
        SUM(qp.estimate_row_count)   AS GeschaetzteZeilen,
        SUM(qp.logical_read_count)   AS GeleseneSeiten,
        SUM(qp.physical_read_count)  AS PhysischGelesen,
        SUM(qp.read_ahead_count)     AS ReadAhead
FROM sys.dm_exec_query_profiles qp
WHERE qp.session_id <> @@SPID
  AND qp.object_id = @object_id
GROUP BY qp.session_id, qp.node_id, qp.physical_operator_name, qp.object_id, qp.index_id
ORDER BY qp.session_id, qp.node_id;

/* Q4) Gibt es einen Index mit der Chunk-Spalte als fuehrender Spalte? (Metadaten) */
SELECT  N'Q4_IndizesDerQuelle' AS Abschnitt, i.index_id, i.name AS IndexName, i.type_desc, i.is_disabled,
        STUFF((SELECT N', ' + c.name
               FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
               WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
               ORDER BY ic.key_ordinal FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'') AS SchluesselSpalten
FROM sys.indexes i
WHERE i.object_id = @object_id
ORDER BY i.index_id;

/* ============================================================================================
   CLIENT (auf dem Rechner, auf dem der Transfer laeuft, in PowerShell):
   Wartet die Quelle in Q1 ebenfalls auf ASYNC_NETWORK_IO, liegt der Engpass im Client-Prozess.
   Zweimal im Abstand von 10 Sekunden ausfuehren und vergleichen (CPU-Sekunden, Speicher):

     Get-Process powershell*, pwsh -ErrorAction SilentlyContinue |
         Select-Object Id, CPU, @{n='WorkingSetMB';e={[int]($_.WorkingSet64/1MB)}}, StartTime

   Steigt CPU um ~10 s je 10 s (ein Kern voll) oder waechst der Speicher stetig, ist der Client
   der Engpass.
   ============================================================================================ */
