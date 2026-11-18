SELECT kc.name AS pk, c.name AS columna, ic.key_ordinal
FROM sys.key_constraints kc
JOIN sys.index_columns ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
JOIN sys.columns c        ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE kc.parent_object_id = OBJECT_ID('dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO')
  AND kc.type = 'PK'
ORDER BY ic.key_ordinal;