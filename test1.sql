/* =====================================================================================
   PASO 0 (UNA SOLA VEZ): borrar lo que dejó la v3 al fallar y recuperar el espacio
   ------------------------------------------------------------------------------------
   DROP TABLE IF EXISTS dbo.STG_PP_SEGMENTOS;
   DROP TABLE IF EXISTS dbo.STG_PP_BASE;
   ===================================================================================== */

/* =====================================================================================
   PROCEDIMIENTO : dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO      (v4 - sin staging)
   MOTOR         : SQL Server 2016+
   ORIGEN        : BDS_SALDOS_CIERRE  (+ BDS_CALENDARIOS)
   DESTINO       : BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO

   RESTRICCIONES DEL SERVIDOR (lo que hizo fallar v1, v2 y v3)
   -------------------------------------------------------------------------------------
   - El log de tempdb no aguanta el volumen de un día     -> Msg 9002
   - El disco del filegroup PRIMARY está casi lleno       -> Msg 1101
   - No se puede modificar la base (sin tablas nuevas, sin índices, sin cambiar archivos)

   DISEÑO v4: NO SE MATERIALIZA NADA GRANDE
   -------------------------------------------------------------------------------------
   [D1] No hay #BASE, #UNION ni tablas de staging. Los datos van directo de
        BDS_SALDOS_CIERRE a BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO. El único espacio
        nuevo que se usa es el del propio destino, igual que en el proceso original.
   [D2] Originales y copias de días no hábiles: un INSERT por (día calendario, lote).
        Cada uno se confirma solo (autocommit).
   [D3] Huecos (inicio / intermedio / fin): se calculan leyendo el destino ya cargado
        del mes, con LAG/LEAD, y se insertan en el mismo INSERT. No hay tabla
        intermedia: la fila anterior al hueco ya tiene los atributos del último
        ORIGINAL (las copias los replican).
   [D4] @LOTES divide el trabajo por cuenta (NUM_CUENTA_BT). Cada sentencia mueve
        1/@LOTES del volumen, así que son más chicos el log, la memoria y los posibles
        derrames (spills) a tempdb. Si algo vuelve a fallar por espacio, sube @LOTES.
   [D5] El DELETE del mes se hace en bloques: libera páginas que el INSERT reutiliza.
   [D6] En tempdb solo quedan #CALENDARIO y #DIAS (≤ 62 filas).

   REEJECUCIÓN: no es atómico (se confirma por partes). Si falla, el log queda en ERROR
   y basta con volver a ejecutarlo con la misma fecha: borra el mes y lo recarga completo.

   Cambios funcionales que se mantienen:
   [C01] DELETE solo para [1.er día del mes, @FECHA_PROCESO] (antes borraba el mismo mes
         de los años anteriores).
   [C02] ANIO / MES se calculan desde la fecha de cada fila.
   [C03] Sin la separación EXISTS / NOT EXISTS contra BDS_OPERACIONES (no filtraba nada).
   [C04] Duplicados: se queda el de FECHA_CARGA / BATCH_ID más reciente.
   [C05] @FECHA_PROCESO NULL -> MAX(FECHA_PROCESO) de BDS_SALDOS_CIERRE.
   ===================================================================================== */

CREATE OR ALTER PROCEDURE dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO
    @FECHA_PROCESO DATE = NULL,
    @LOTES         INT  = 8
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT > 0
        THROW 50000, 'Ejecuta el SP fuera de una transacción (BEGIN TRAN abierto o IMPLICIT_TRANSACTIONS ON).', 1;
    IF @LOTES IS NULL OR @LOTES < 1 SET @LOTES = 1;

    DECLARE
        @FECHA_FIN      DATE,
        @FECHA_INICIO   DATE,          -- último día hábil del mes anterior
        @INICIO_MES     DATE,
        @DIA            DATE,
        @ORIGEN         DATE,
        @HABIL          VARCHAR(1),
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
           1. PARÁMETROS Y CALENDARIO (tablas pequeñas)
           ============================================================================== */
        SELECT @FECHA_INICIO = CAST(MAX(C.FEC_CALENDARIO) AS DATE)
        FROM dbo.BDS_CALENDARIOS C
        WHERE C.COD_CALENDARIO = 1
          AND C.IND_DIA_HABIL  = 'S'
          AND C.FEC_CALENDARIO <= EOMONTH(@FECHA_FIN, -1);

        IF @FECHA_INICIO IS NULL
            THROW 50001, 'No se encontró el último día hábil del mes anterior en BDS_CALENDARIOS.', 1;

        -- El rango empieza en un día hábil, así que FECHA_ORIGEN nunca queda en 1900.
        -- (Usar '19000101' en vez de NULL evita la advertencia "Null value is eliminated...")
        SELECT
            CAST(FEC_CALENDARIO AS DATE) AS FECHA_PROCESO,
            IND_DIA_HABIL,
            MAX(CASE WHEN IND_DIA_HABIL = 'S' THEN CAST(FEC_CALENDARIO AS DATE)
                     ELSE CAST('19000101' AS DATE) END)
                OVER (ORDER BY FEC_CALENDARIO ROWS UNBOUNDED PRECEDING) AS FECHA_ORIGEN
        INTO #CALENDARIO
        FROM dbo.BDS_CALENDARIOS
        WHERE COD_CALENDARIO = 1
          AND FEC_CALENDARIO BETWEEN @FECHA_INICIO AND @FECHA_FIN;

        SELECT TOP (DATEDIFF(DAY, @INICIO_MES, @FECHA_FIN) + 1)
               DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, @INICIO_MES) AS FECHA
        INTO #DIAS
        FROM sys.all_objects;

        /* ==============================================================================
           2. BORRAR EL MES EN EL DESTINO (en bloques)  [D5] [C01]
           ============================================================================== */
        SET @BORRADAS = 1;
        WHILE @BORRADAS > 0
        BEGIN
            DELETE TOP (100000) FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
            WHERE FECHA_PROCESO >= @INICIO_MES
              AND FECHA_PROCESO <  DATEADD(DAY, 1, @FECHA_FIN);
            SET @BORRADAS = @@ROWCOUNT;
        END;

        /* ==============================================================================
           3. ORIGINALES + COPIAS: directo del origen al destino, por día y lote  [D1] [D2] [D4]
           ============================================================================== */
        SET @DIA = @INICIO_MES;
        WHILE @DIA <= @FECHA_FIN
        BEGIN
            SELECT @ORIGEN = NULL, @HABIL = NULL;     -- si el día no está en el calendario, se salta
            SELECT @ORIGEN = FECHA_ORIGEN, @HABIL = IND_DIA_HABIL
            FROM #CALENDARIO WHERE FECHA_PROCESO = @DIA;

            SET @LOTE = 0;
            WHILE @ORIGEN IS NOT NULL AND @LOTE < @LOTES
            BEGIN
                INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (     -- VALIDAR: orden de columnas
                    ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                    COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                    COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                    FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                    MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                    IND_DIA_HABIL, TIPO_ORIGEN, FUENTE
                )
                SELECT
                    s.ID_CALC, @DIA, s.COD_EMPRESA, YEAR(@DIA), MONTH(@DIA), s.COD_SUCURSAL, s.COD_RUBRO,
                    s.COD_MONEDA, s.COD_PAPEL, s.PCT_TASA, s.NUM_CUENTA_BT, s.COD_OPERACION, s.COD_EJECUTIVO,
                    s.COD_SUB_OPERACION, s.COD_TIPO_OPERACION, s.COD_MODULO, s.COD_MODULO_PRODUCTO,
                    s.FEC_VENCIMIENTO, s.FEC_VALOR, s.IND_CATEGORIA_RIESGO, s.COD_ACTI_BCO_CENTRAL, s.COD_PRODUCTO,
                    s.MTO_SALDO_ORIGEN, s.MTO_SALDO_MN, s.MTO_SALDO_ME, s.MTO_SALDO_MO, s.MTO_INTERES, s.MTO_PREVISIONES,
                    @HABIL,
                    CASE WHEN @DIA = @ORIGEN THEN 'ORIGINAL' ELSE 'COPIA_HABIL' END,
                    s.FUENTE
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
                    WHERE c.FECHA_PROCESO >= @ORIGEN
                      AND c.FECHA_PROCESO <  DATEADD(DAY, 1, @ORIGEN)
                      AND (@LOTES = 1 OR ABS(CHECKSUM(c.NUM_CUENTA_BT)) % @LOTES = @LOTE)
                ) s
                WHERE s.RN = 1
                OPTION (RECOMPILE);

                SET @FILAS += @@ROWCOUNT;
                SET @LOTE  += 1;
            END;

            SET @DIA = DATEADD(DAY, 1, @DIA);
        END;

        /* ==============================================================================
           4. RELLENOS EN 0, leyendo el destino ya cargado (por lote)  [D3] [D4]
              Sobre las filas del mes (originales + copias), ordenadas por fecha:
              - INICIO     : primera fila del mes después del día 1 y que no es copia
                             -> [día 1, FECHA-1]
              - INTERMEDIO : salto de más de 1 día hasta la fila siguiente
                             -> [FECHA+1, FECHA_SIG-1]
              - FIN        : última fila antes de @FECHA_PROCESO
                             -> [FECHA+1, @FECHA_PROCESO]
              Los atributos salen de la propia fila (= último ORIGINAL), con montos en 0.
           ============================================================================== */
        SET @LOTE = 0;
        WHILE @LOTE < @LOTES
        BEGIN
            INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                IND_DIA_HABIL, TIPO_ORIGEN, FUENTE
            )
            SELECT
                W.ID_OPERACION_CIERRE, d.FECHA, W.COD_EMPRESA, YEAR(d.FECHA), MONTH(d.FECHA), W.COD_SUCURSAL, W.COD_RUBRO,
                W.COD_MONEDA, W.COD_PAPEL, W.PCT_TASA, W.NUM_CUENTA_BT, W.COD_OPERACION, W.COD_EJECUTIVO,
                W.COD_SUB_OPERACION, W.COD_TIPO_OPERACION, W.COD_MODULO, W.COD_MODULO_PRODUCTO,
                W.FEC_VENCIMIENTO, W.FEC_VALOR, W.IND_CATEGORIA_RIESGO, W.COD_ACTI_BCO_CENTRAL, W.COD_PRODUCTO,
                0, 0, 0, 0, 0, 0,
                'S',
                NULL,                                   -- igual que el original
                W.FUENTE
            FROM (
                SELECT
                    L.ID_OPERACION_CIERRE, L.FECHA_PROCESO, L.TIPO_ORIGEN,
                    L.COD_EMPRESA, L.COD_SUCURSAL, L.COD_RUBRO, L.COD_MONEDA, L.COD_PAPEL, L.PCT_TASA,
                    L.NUM_CUENTA_BT, L.COD_OPERACION, L.COD_EJECUTIVO, L.COD_SUB_OPERACION,
                    L.COD_TIPO_OPERACION, L.COD_MODULO, L.COD_MODULO_PRODUCTO, L.FEC_VENCIMIENTO,
                    L.FEC_VALOR, L.IND_CATEGORIA_RIESGO, L.COD_ACTI_BCO_CENTRAL, L.COD_PRODUCTO, L.FUENTE,
                    LAG (L.FECHA_PROCESO) OVER (PARTITION BY L.ID_OPERACION_CIERRE, L.COD_RUBRO
                                                ORDER BY L.FECHA_PROCESO) AS FECHA_ANT,
                    LEAD(L.FECHA_PROCESO) OVER (PARTITION BY L.ID_OPERACION_CIERRE, L.COD_RUBRO
                                                ORDER BY L.FECHA_PROCESO) AS FECHA_SIG
                FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO L
                WHERE L.FECHA_PROCESO >= @INICIO_MES
                  AND L.FECHA_PROCESO <= @FECHA_FIN
                  AND L.TIPO_ORIGEN IN ('ORIGINAL', 'COPIA_HABIL')
                  AND (@LOTES = 1 OR ABS(CHECKSUM(L.NUM_CUENTA_BT)) % @LOTES = @LOTE)
            ) W
            CROSS APPLY (VALUES
                -- INICIO
                (CASE WHEN W.FECHA_ANT IS NULL
                           AND W.FECHA_PROCESO > @INICIO_MES
                           AND W.TIPO_ORIGEN = 'ORIGINAL'
                      THEN @INICIO_MES END,
                 DATEADD(DAY, -1, W.FECHA_PROCESO)),
                -- INTERMEDIO
                (CASE WHEN DATEDIFF(DAY, W.FECHA_PROCESO, W.FECHA_SIG) > 1
                      THEN DATEADD(DAY, 1, W.FECHA_PROCESO) END,
                 DATEADD(DAY, -1, W.FECHA_SIG)),
                -- FIN
                (CASE WHEN W.FECHA_SIG IS NULL
                           AND W.FECHA_PROCESO < @FECHA_FIN
                      THEN DATEADD(DAY, 1, W.FECHA_PROCESO) END,
                 @FECHA_FIN)
            ) S (DESDE, HASTA)
            JOIN #DIAS d
              ON d.FECHA BETWEEN S.DESDE AND S.HASTA
            WHERE S.DESDE IS NOT NULL
            OPTION (RECOMPILE);

            SET @FILAS += @@ROWCOUNT;
            SET @LOTE  += 1;
        END;

        /* ==============================================================================
           5. Log de fin
           ============================================================================== */
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
                          N' | Reejecutar con la misma fecha (idempotente). Si es por espacio, subir @LOTES.');

        UPDATE dbo.ctl_log_proceso
           SET estado = 'ERROR', fec_termino = SYSDATETIME(), msg_error = LEFT(@MSG, 4000)
         WHERE id_log = @ID_LOG;

        EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO', @LockOwner = 'Session';
        THROW;
    END CATCH
END;
GO

/* ------------------------------------------------------------------------------------
   Ejecución
   ------------------------------------------------------------------------------------
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO @FECHA_PROCESO = '2026-10-31', @LOTES = 8;
   -- si vuelve a fallar por espacio o log:  @LOTES = 32
   ------------------------------------------------------------------------------------ */
