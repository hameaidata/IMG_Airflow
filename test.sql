/* =====================================================================================
   PROCEDIMIENTO : dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO      (v3 - sin tempdb para volumen)
   MOTOR         : SQL Server 2016+
   ORIGEN        : BDS_SALDOS_CIERRE  (+ BDS_CALENDARIOS)
   DESTINO       : BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO

   POR QUÉ LA v2 SEGUÍA FALLANDO (Msg 9002 en el INSERT INTO #BASE)
   -------------------------------------------------------------------------------------
   El log de tempdb no aguanta ni el volumen de UN día de BDS_SALDOS_CIERRE: tiene
   un tope chico o lo retiene otra sesión con una transacción abierta.
   Mientras los datos grandes pasen por una #temporal, el error va a seguir.

   QUÉ CAMBIA EN LA v3
   -------------------------------------------------------------------------------------
   [T1] Los datos grandes van a tablas de staging FÍSICAS en tu base de datos
        (dbo.STG_PP_BASE y dbo.STG_PP_SEGMENTOS). En tempdb solo quedan el calendario
        y la tabla de días (≤ 62 filas).
   [T2] Cada INSERT se confirma por separado (día por día y lote por lote). Ya no hay
        una transacción gigante que retenga el log.
   [T3] @LOTES divide cada día en N partes por cuenta (NUM_CUENTA_BT). Si un solo día
        sigue siendo demasiado grande para el log, sube @LOTES (4, 8, 16...).
        El mismo lote se usa al cargar el destino.
   [T4] El índice de staging se crea con SORT_IN_TEMPDB = OFF (el ordenamiento se hace en
        tu base, no en tempdb).
   [T5] El DELETE del mes en el destino se hace en bloques de 200.000 filas.
   [T6] sp_getapplock de sesión: evita dos ejecuciones simultáneas sobre el staging.

   TRADE-OFF: la carga del destino ya no es atómica (se confirma por lotes). Si el SP falla
   a la mitad, el log queda en ERROR y basta con volver a ejecutarlo con la misma fecha:
   borra el mes y lo recarga completo (es idempotente).

   Se mantienen los cambios funcionales de la v1 / v2:
   [C01] DELETE del destino solo para [1.er día del mes, @FECHA_PROCESO].
   [C02] ANIO / MES se calculan desde la fecha de cada fila.
   [C03] Sin la separación EXISTS / NOT EXISTS contra BDS_OPERACIONES.
   [C04] Duplicados: se queda el de FECHA_CARGA / BATCH_ID más reciente.
   [C05] @FECHA_PROCESO NULL -> MAX(FECHA_PROCESO) de BDS_SALDOS_CIERRE.
   ===================================================================================== */

CREATE OR ALTER PROCEDURE dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO
    @FECHA_PROCESO DATE = NULL,
    @LOTES         INT  = 4          -- [T3] subir si el log sigue llenándose
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT > 0
        THROW 50000, 'Ejecuta el SP fuera de una transacción (BEGIN TRAN abierto o IMPLICIT_TRANSACTIONS ON).', 1;
    IF @LOTES IS NULL OR @LOTES < 1 SET @LOTES = 1;

    DECLARE
        @FECHA_FIN      DATE,
        @FECHA_INICIO   DATE,
        @INICIO_MES     DATE,
        @DIA            DATE,
        @FIN_COB        DATE,
        @LOTE           INT,
        @BORRADAS       INT,
        @FILAS          BIGINT = 0,
        @MSG            NVARCHAR(4000) = NULL,
        @ID_LOG         BIGINT,
        @LOCK_RESULT    INT;

    IF @FECHA_PROCESO IS NULL
        SELECT @FECHA_PROCESO = CAST(MAX(FECHA_PROCESO) AS DATE) FROM dbo.BDS_SALDOS_CIERRE;

    SET @FECHA_FIN  = @FECHA_PROCESO;
    SET @INICIO_MES = DATEFROMPARTS(YEAR(@FECHA_FIN), MONTH(@FECHA_FIN), 1);

    /* [T6] Candado de sesión: el staging es compartido */
    EXEC @LOCK_RESULT = sp_getapplock
         @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO',
         @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0;
    IF @LOCK_RESULT < 0
        THROW 50002, 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO ya se está ejecutando en otra sesión.', 1;

    INSERT INTO dbo.ctl_log_proceso (nom_proceso, tabla_origen, tabla_destino, fec_inicio, estado)
    VALUES (N'DATAHUB_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO', N'BDS_SALDOS_CIERRE',
            N'BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO', SYSDATETIME(), 'EJECUTANDO');
    SET @ID_LOG = SCOPE_IDENTITY();

    BEGIN TRY

        /* ==============================================================================
           1. PARÁMETROS
           ============================================================================== */
        SELECT @FECHA_INICIO = CAST(MAX(C.FEC_CALENDARIO) AS DATE)
        FROM dbo.BDS_CALENDARIOS C
        WHERE C.COD_CALENDARIO = 1
          AND C.IND_DIA_HABIL  = 'S'
          AND C.FEC_CALENDARIO <= EOMONTH(@FECHA_FIN, -1);

        IF @FECHA_INICIO IS NULL
            THROW 50001, 'No se encontró el último día hábil del mes anterior en BDS_CALENDARIOS.', 1;

        /* ==============================================================================
           2. CALENDARIO y DÍAS (tablas pequeñas: pueden quedarse en tempdb)
           ============================================================================== */
        SELECT
            CAST(FEC_CALENDARIO AS DATE) AS FECHA_PROCESO,
            IND_DIA_HABIL,
            MAX(CASE WHEN IND_DIA_HABIL = 'S' THEN CAST(FEC_CALENDARIO AS DATE) ELSE NULL END)
                OVER (ORDER BY FEC_CALENDARIO ROWS UNBOUNDED PRECEDING) AS FECHA_ORIGEN
        INTO #CALENDARIO
        FROM dbo.BDS_CALENDARIOS
        WHERE COD_CALENDARIO = 1
          AND FEC_CALENDARIO BETWEEN @FECHA_INICIO AND @FECHA_FIN;

        SELECT TOP (DATEDIFF(DAY, @FECHA_INICIO, @FECHA_FIN) + 1)
               DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, @FECHA_INICIO) AS FECHA
        INTO #DIAS
        FROM sys.all_objects;

        /* ==============================================================================
           3. STAGING FÍSICO: dbo.STG_PP_BASE (solo días hábiles)  [T1] [T2] [T3]
           ============================================================================== */
        DROP TABLE IF EXISTS dbo.STG_PP_BASE;

        SELECT TOP (0)
            CAST('' AS VARCHAR(300)) AS ID_OPERACION_CIERRE,
            CAST(NULL AS DATE)       AS FECHA_PROCESO,
            CAST(NULL AS DATE)       AS FIN_COB,
            CAST(0 AS INT)           AS LOTE,
            c.COD_EMPRESA, c.COD_SUCURSAL, c.COD_RUBRO, c.COD_MONEDA, c.COD_PAPEL, c.PCT_TASA,
            c.NUM_CUENTA_BT, c.COD_OPERACION, c.COD_EJECUTIVO, c.COD_SUB_OPERACION,
            c.COD_TIPO_OPERACION, c.COD_MODULO, c.COD_MODULO_PRODUCTO, c.FEC_VENCIMIENTO,
            c.FEC_VALOR, c.IND_CATEGORIA_RIESGO, c.COD_ACTI_BCO_CENTRAL, c.COD_PRODUCTO,
            c.MTO_SALDO_ORIGEN, c.MTO_SALDO_MN, c.MTO_SALDO_ME, c.MTO_SALDO_MO,
            c.MTO_INTERES, c.MTO_PREVISIONES, c.FUENTE
        INTO dbo.STG_PP_BASE
        FROM dbo.BDS_SALDOS_CIERRE c;

        SET @DIA = (SELECT MIN(FECHA_ORIGEN) FROM #CALENDARIO);
        WHILE @DIA IS NOT NULL
        BEGIN
            SET @FIN_COB = (SELECT MAX(FECHA_PROCESO) FROM #CALENDARIO WHERE FECHA_ORIGEN = @DIA);
            SET @LOTE = 0;

            WHILE @LOTE < @LOTES
            BEGIN
                -- Cada INSERT es su propia transacción (autocommit): el log se libera entre lotes
                INSERT INTO dbo.STG_PP_BASE WITH (TABLOCK)
                SELECT
                    s.ID_CALC, @DIA, @FIN_COB, @LOTE,
                    s.COD_EMPRESA, s.COD_SUCURSAL, s.COD_RUBRO, s.COD_MONEDA, s.COD_PAPEL, s.PCT_TASA,
                    s.NUM_CUENTA_BT, s.COD_OPERACION, s.COD_EJECUTIVO, s.COD_SUB_OPERACION,
                    s.COD_TIPO_OPERACION, s.COD_MODULO, s.COD_MODULO_PRODUCTO, s.FEC_VENCIMIENTO,
                    s.FEC_VALOR, s.IND_CATEGORIA_RIESGO, s.COD_ACTI_BCO_CENTRAL, s.COD_PRODUCTO,
                    s.MTO_SALDO_ORIGEN, s.MTO_SALDO_MN, s.MTO_SALDO_ME, s.MTO_SALDO_MO,
                    s.MTO_INTERES, s.MTO_PREVISIONES, s.FUENTE
                FROM (
                    SELECT k.ID_CALC, c.*,
                           ROW_NUMBER() OVER (PARTITION BY k.ID_CALC, c.COD_RUBRO
                                              ORDER BY c.FECHA_CARGA DESC, c.BATCH_ID DESC) AS RN
                    FROM dbo.BDS_SALDOS_CIERRE c
                    CROSS APPLY (
                        SELECT CAST(CONCAT(c.COD_EMPRESA, '|', c.COD_MODULO, '|', c.COD_SUCURSAL, '|',
                                           c.COD_MONEDA, '|', c.COD_PAPEL, '|', c.NUM_CUENTA_BT, '|',
                                           c.COD_OPERACION, '|', c.COD_SUB_OPERACION, '|',
                                           c.COD_TIPO_OPERACION) AS VARCHAR(300)) AS ID_CALC
                    ) k
                    WHERE c.FECHA_PROCESO >= @DIA
                      AND c.FECHA_PROCESO <  DATEADD(DAY, 1, @DIA)
                      -- el lote va por cuenta: todas las filas de una operación caen en el mismo lote
                      AND (@LOTES = 1 OR ABS(CHECKSUM(c.NUM_CUENTA_BT)) % @LOTES = @LOTE)
                ) s
                WHERE s.RN = 1
                OPTION (RECOMPILE);

                SET @LOTE += 1;
            END;

            SET @DIA = (SELECT MIN(FECHA_ORIGEN) FROM #CALENDARIO WHERE FECHA_ORIGEN > @DIA);
        END;

        -- [T4] Ordenamiento en la base de usuario, no en tempdb
        CREATE UNIQUE CLUSTERED INDEX IX_STG_PP_BASE
            ON dbo.STG_PP_BASE (ID_OPERACION_CIERRE, COD_RUBRO, FECHA_PROCESO)
            WITH (SORT_IN_TEMPDB = OFF);

        /* ==============================================================================
           4. HUECOS: dbo.STG_PP_SEGMENTOS (una fila por hueco, no por día)
              Cada fila hábil cubre [FECHA_PROCESO, FIN_COB].
           ============================================================================== */
        DROP TABLE IF EXISTS dbo.STG_PP_SEGMENTOS;

        ;WITH W AS (
            SELECT
                b.ID_OPERACION_CIERRE, b.COD_RUBRO, b.FECHA_PROCESO, b.FIN_COB, b.LOTE,
                DATEFROMPARTS(YEAR(b.FECHA_PROCESO), MONTH(b.FECHA_PROCESO), 1) AS INICIO_MES_FILA,
                EOMONTH(b.FIN_COB)                                               AS FIN_MES_COB,
                LAG (b.FIN_COB)       OVER (PARTITION BY b.ID_OPERACION_CIERRE, b.COD_RUBRO
                                            ORDER BY b.FECHA_PROCESO) AS FIN_COB_ANT,
                LEAD(b.FECHA_PROCESO) OVER (PARTITION BY b.ID_OPERACION_CIERRE, b.COD_RUBRO
                                            ORDER BY b.FECHA_PROCESO) AS FECHA_SIG
            FROM dbo.STG_PP_BASE b
        )
        SELECT
            W.ID_OPERACION_CIERRE, W.COD_RUBRO, W.LOTE,
            W.FECHA_PROCESO AS FECHA_FUENTE,
            S.TIPO_RELLENO,
            CASE WHEN S.DESDE < @FECHA_INICIO THEN @FECHA_INICIO ELSE S.DESDE END AS DESDE,
            CASE WHEN S.HASTA > @FECHA_FIN    THEN @FECHA_FIN    ELSE S.HASTA END AS HASTA
        INTO dbo.STG_PP_SEGMENTOS
        FROM W
        CROSS APPLY (VALUES
            ('INICIO',
             CASE WHEN W.FECHA_PROCESO > W.INICIO_MES_FILA
                       AND (W.FIN_COB_ANT IS NULL OR W.FIN_COB_ANT < W.INICIO_MES_FILA)
                  THEN W.INICIO_MES_FILA END,
             DATEADD(DAY, -1, W.FECHA_PROCESO)),
            ('INTERMEDIO',
             CASE WHEN W.FECHA_SIG > DATEADD(DAY, 1, W.FIN_COB)
                       AND W.FECHA_SIG <= W.FIN_MES_COB
                  THEN DATEADD(DAY, 1, W.FIN_COB) END,
             DATEADD(DAY, -1, W.FECHA_SIG)),
            ('FIN',
             CASE WHEN (W.FECHA_SIG IS NULL OR W.FECHA_SIG > W.FIN_MES_COB)
                       AND W.FIN_COB < W.FIN_MES_COB
                  THEN DATEADD(DAY, 1, W.FIN_COB) END,
             W.FIN_MES_COB)
        ) S (TIPO_RELLENO, DESDE, HASTA)
        WHERE S.DESDE IS NOT NULL
          AND S.DESDE <= @FECHA_FIN
          AND S.HASTA >= @FECHA_INICIO;

        DELETE FROM dbo.STG_PP_SEGMENTOS WHERE DESDE > HASTA OR HASTA < @INICIO_MES;

        /* ==============================================================================
           5. DESTINO: borrar el mes en bloques y cargar por lotes  [T2] [T5] [C01]
           ============================================================================== */
        SET @BORRADAS = 1;
        WHILE @BORRADAS > 0
        BEGIN
            DELETE TOP (200000) FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
            WHERE FECHA_PROCESO >= @INICIO_MES
              AND FECHA_PROCESO <  DATEADD(DAY, 1, @FECHA_FIN);
            SET @BORRADAS = @@ROWCOUNT;
        END;

        SET @LOTE = 0;
        WHILE @LOTE < @LOTES
        BEGIN
            -- 5.1 ORIGINALES + COPIAS de días no hábiles
            INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (     -- VALIDAR: orden de columnas
                ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                IND_DIA_HABIL, TIPO_ORIGEN, FUENTE
            )
            SELECT
                b.ID_OPERACION_CIERRE, c.FECHA_PROCESO, b.COD_EMPRESA,
                YEAR(c.FECHA_PROCESO), MONTH(c.FECHA_PROCESO),
                b.COD_SUCURSAL, b.COD_RUBRO,
                b.COD_MONEDA, b.COD_PAPEL, b.PCT_TASA, b.NUM_CUENTA_BT, b.COD_OPERACION, b.COD_EJECUTIVO,
                b.COD_SUB_OPERACION, b.COD_TIPO_OPERACION, b.COD_MODULO, b.COD_MODULO_PRODUCTO,
                b.FEC_VENCIMIENTO, b.FEC_VALOR, b.IND_CATEGORIA_RIESGO, b.COD_ACTI_BCO_CENTRAL, b.COD_PRODUCTO,
                b.MTO_SALDO_ORIGEN, b.MTO_SALDO_MN, b.MTO_SALDO_ME, b.MTO_SALDO_MO, b.MTO_INTERES, b.MTO_PREVISIONES,
                c.IND_DIA_HABIL,
                CASE WHEN c.FECHA_PROCESO = b.FECHA_PROCESO THEN 'ORIGINAL' ELSE 'COPIA_HABIL' END,
                b.FUENTE
            FROM #CALENDARIO c
            INNER HASH JOIN dbo.STG_PP_BASE b             -- hash armado con el calendario (≤ 31 filas)
               ON c.FECHA_ORIGEN = b.FECHA_PROCESO
            WHERE c.FECHA_PROCESO >= @INICIO_MES
              AND c.FECHA_PROCESO <= @FECHA_FIN
              AND b.LOTE = @LOTE;

            SET @FILAS += @@ROWCOUNT;

            -- 5.2 RELLENOS en 0 (inicio / intermedio / fin de mes)
            INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                IND_DIA_HABIL, TIPO_ORIGEN, FUENTE
            )
            SELECT
                s.ID_OPERACION_CIERRE, d.FECHA, b.COD_EMPRESA,
                YEAR(d.FECHA), MONTH(d.FECHA),
                b.COD_SUCURSAL, b.COD_RUBRO,
                b.COD_MONEDA, b.COD_PAPEL, b.PCT_TASA, b.NUM_CUENTA_BT, b.COD_OPERACION, b.COD_EJECUTIVO,
                b.COD_SUB_OPERACION, b.COD_TIPO_OPERACION, b.COD_MODULO, b.COD_MODULO_PRODUCTO,
                b.FEC_VENCIMIENTO, b.FEC_VALOR, b.IND_CATEGORIA_RIESGO, b.COD_ACTI_BCO_CENTRAL, b.COD_PRODUCTO,
                0, 0, 0, 0, 0, 0,
                'S',
                NULL,
                b.FUENTE
            FROM dbo.STG_PP_SEGMENTOS s
            JOIN #DIAS d
              ON d.FECHA BETWEEN s.DESDE AND s.HASTA
            JOIN dbo.STG_PP_BASE b
              ON b.ID_OPERACION_CIERRE = s.ID_OPERACION_CIERRE
             AND b.COD_RUBRO           = s.COD_RUBRO
             AND b.FECHA_PROCESO       = s.FECHA_FUENTE
            WHERE s.LOTE = @LOTE
              AND d.FECHA >= @INICIO_MES
              AND d.FECHA <= @FECHA_FIN;

            SET @FILAS += @@ROWCOUNT;
            SET @LOTE  += 1;
        END;

        /* ==============================================================================
           6. Limpieza y log
           ============================================================================== */
        DROP TABLE IF EXISTS dbo.STG_PP_SEGMENTOS;
        DROP TABLE IF EXISTS dbo.STG_PP_BASE;

        IF @FILAS = 0
            SET @MSG = N'No se insertaron registros en BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO para '
                     + CONVERT(NVARCHAR(10), @FECHA_FIN, 23) + N'.';

        UPDATE dbo.ctl_log_proceso
           SET estado           = CASE WHEN @MSG IS NULL THEN 'TERMINADO' ELSE 'WARNING' END,
               fec_termino      = SYSDATETIME(),
               filas_insertadas = @FILAS,
               msg_error        = @MSG
         WHERE id_log = @ID_LOG;

        EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO', @LockOwner = 'Session';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        SET @MSG = CONCAT(N'Error ', ERROR_NUMBER(), N' (línea ', ERROR_LINE(), N'): ', ERROR_MESSAGE(),
                          N' | Reejecutar con la misma fecha: el proceso es idempotente.');

        UPDATE dbo.ctl_log_proceso
           SET estado = 'ERROR', fec_termino = SYSDATETIME(), msg_error = LEFT(@MSG, 4000)
         WHERE id_log = @ID_LOG;

        EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO', @LockOwner = 'Session';
        THROW;
    END CATCH
END;
GO

/* ------------------------------------------------------------------------------------
   Diagnóstico SIN permisos de administrador
   ------------------------------------------------------------------------------------
   -- ¿Qué impide liberar el log? (ACTIVE_TRANSACTION = hay una transacción abierta)
   SELECT name, recovery_model_desc, log_reuse_wait_desc
   FROM sys.databases
   WHERE name IN ('tempdb', DB_NAME());

   -- Tamaño y tope del log de tempdb
   SELECT name, type_desc, size * 8 / 1024 AS size_mb,
          CASE max_size WHEN -1 THEN 'ilimitado' ELSE CAST(max_size * 8 / 1024 AS VARCHAR(20)) + ' MB' END AS max_size,
          growth
   FROM tempdb.sys.database_files;

   -- Volumen de un día de origen (para decidir @LOTES)
   SELECT COUNT_BIG(*) FROM dbo.BDS_SALDOS_CIERRE
   WHERE FECHA_PROCESO >= '2026-10-30' AND FECHA_PROCESO < '2026-10-31';

   Ejecución
   ------------------------------------------------------------------------------------
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO @FECHA_PROCESO = '2026-10-31', @LOTES = 4;
   -- si vuelve a fallar por log:  @LOTES = 16
   ------------------------------------------------------------------------------------ */
