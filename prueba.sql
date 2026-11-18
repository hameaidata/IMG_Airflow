SELECT kc.name AS pk, c.name AS columna, ic.key_ordinal
FROM sys.key_constraints kc
JOIN sys.index_columns ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
JOIN sys.columns c        ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE kc.parent_object_id = OBJECT_ID('dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO')
  AND kc.type = 'PK'
ORDER BY ic.key_ordinal;

USE GNBPE_DATAHUB;

-- Archivos: tamaño, espacio libre interno, máximo permitido y crecimiento
SELECT name, type_desc, physical_name,
       size/128                                         AS tamano_mb,
       size/128 - FILEPROPERTY(name,'SpaceUsed')/128    AS libre_mb,
       CASE max_size WHEN -1 THEN 'ilimitado' WHEN 0 THEN 'sin crecimiento'
            ELSE CAST(max_size/128 AS VARCHAR(20)) + ' MB' END AS maximo,
       CASE WHEN is_percent_growth = 1 THEN CAST(growth AS VARCHAR(10)) + ' %'
            ELSE CAST(growth/128 AS VARCHAR(10)) + ' MB' END  AS crecimiento
FROM sys.database_files;

-- Espacio libre en el disco donde están los archivos
SELECT DISTINCT vs.volume_mount_point,
       vs.total_bytes/1048576     AS disco_total_mb,
       vs.available_bytes/1048576 AS disco_libre_mb
FROM sys.database_files f
CROSS APPLY sys.dm_os_volume_stats(DB_ID(), f.file_id) vs;

-- Las 15 tablas que más espacio ocupan
SELECT TOP 15 SCHEMA_NAME(t.schema_id) + '.' + t.name AS tabla,
       SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count END) AS filas,
       SUM(ps.reserved_page_count)/128 AS reservado_mb
FROM sys.dm_db_partition_stats ps
JOIN sys.tables t ON t.object_id = ps.object_id
GROUP BY t.schema_id, t.name
ORDER BY reservado_mb DESC;