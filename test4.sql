/* =====================================================================================
   PROCEDIMIENTO : dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6
   MOTOR         : SQL Server 2016 SP1+
   DESCRIPCIÓN   : Arma la serie DIARIA y DENSA de saldos por (operación, rubro) del mes,
                   desde el día 1 hasta @FECHA_PROCESO, y la carga en
                   BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (insumo de SP_BDS_SALDOS_OPERATIVOS_14).
                     - Día hábil     -> saldo del día                      (TIPO_ORIGEN = ORIGINAL)
                     - Día no hábil  -> copia del último día hábil         (TIPO_ORIGEN = COPIA_HABIL)
                     - Días sin dato -> fila con montos en 0, con los atributos del registro
                                        anterior (o del primero, si es inicio de mes)
                                        (TIPO_ORIGEN = RELLENO_INICIO_MES / RELLENO_INTERMEDIO / RELLENO_FIN_MES)

   MEMORIA Y REGISTRO DE TRANSACCIONES (versión 2, tras el error 9002 en tempdb)
   -------------------------------------------------------------------------------------
   [M1] No hay recursión: los días salen de #CAL (como máximo 31 filas + el día semilla).
   [M2] Se carga UN DÍA POR VUELTA, con una transacción corta por día directo al destino:
        DELETE del día + INSERT del día + COMMIT. No hay ninguna transacción que dure todo
        el mes, así que el registro de transacciones se puede liberar entre días.
        Si falla a mitad de mes, los días ya cargados quedan confirmados; volver a ejecutar
        reprocesa el mes completo (el proceso es idempotente).
   [M3] Ya no existe #RESULT: el mes completo no se guarda en tempdb.
   [M4] Las #temporales se cargan como heap con WITH (TABLOCK) o SELECT INTO (mínimamente
        registrados en tempdb). Los índices se crean después de la carga.
   [M5] Se rechaza la ejecución dentro de una transacción abierta (@@TRANCOUNT > 0) y se
        fuerza IMPLICIT_TRANSACTIONS OFF: así nada queda colgado reteniendo el registro de tempdb.

   CAMBIOS DE LÓGICA RESPECTO A LA VERSIÓN SINGLESTORE
   -------------------------------------------------------------------------------------
   [C01] DELETE del destino por rango de fechas. Antes era MONTH()=V_MES AND FECHA<=V_FECHA_PROCESO,
         que BORRABA EL MISMO MES DE TODOS LOS AÑOS ANTERIORES.
   [C02] ANIO / MES se calculan desde la fecha del día generado (antes, en las copias venían
         del mes anterior y en los rellenos quedaban en NULL).
   [C03] TIPO_ORIGEN de los rellenos: RELLENO_INICIO_MES / _INTERMEDIO / _FIN_MES (antes NULL).
   [C04] IND_DIA_HABIL de los rellenos se toma del calendario (antes 'S' fijo).
   [C05] Duplicados en BDS_SALDOS_CIERRE: se toma la carga más reciente (FECHA_CARGA, BATCH_ID).
   [C06] Se eliminan pasos que no hacían nada (filtro sin efecto, split EXISTS / NOT EXISTS,
         V_FECHA_INICIO_MES, ALTER TABLE DROP COLUMN).
   [C07] Solo se generan rellenos del mes en proceso.
   [C09] CONCAT trata NULL como '' (antes, una llave con un componente NULL quedaba NULL).

   PUNTOS A VALIDAR (busca  -- VALIDAR)
   -------------------------------------------------------------------------------------
   V1. Si @FECHA_PROCESO llega NULL se usa el día anterior.
   V2. Criterio de deduplicación [C05].
   V3. Formato y largo de la llave ID_OPERACION_CIERRE (VARCHAR(200)).
   V4. Si algún consumidor filtra por TIPO_ORIGEN IS NULL, ajústalo a [C03].
   ===================================================================================== */

CREATE OR ALTER PROCEDURE dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6
    @FECHA_PROCESO DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET IMPLICIT_TRANSACTIONS OFF;                                   -- [M5]

    IF @@TRANCOUNT > 0                                               -- [M5]
        THROW 50012, 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6 no debe ejecutarse dentro de una transacción abierta (confirma por día).', 1;

    -- VALIDAR (V1)
    IF @FECHA_PROCESO IS NULL
        SET @FECHA_PROCESO = DATEADD(DAY, -1, CAST(SYSDATETIME() AS DATE));

    DECLARE
        @MES_INI        DATE = DATEFROMPARTS(YEAR(@FECHA_PROCESO), MONTH(@FECHA_PROCESO), 1),
        @FECHA_FIN      DATE = @FECHA_PROCESO,
        @FECHA_SEMILLA  DATE,            -- último día hábil del mes anterior (antes V_FECHA_INICIO)
        @DIA            DATE,
        @ORIGEN         DATE,
        @HABIL          CHAR(1),
        @FILAS          BIGINT = 0,
        @MSG_ERROR      NVARCHAR(4000) = NULL,
        @ID_LOG         BIGINT,
        @LOCK_RESULT    INT;

    INSERT INTO dbo.ctl_log_proceso (nom_proceso, tabla_origen, tabla_destino, fec_inicio, estado)
    VALUES (N'DATAHUB_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO', N'BDS_SALDOS_CIERRE',
            N'BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO', SYSDATETIME(), 'EJECUTANDO');
    SET @ID_LOG = SCOPE_IDENTITY();

    BEGIN TRY

        -- Una sola ejecución a la vez (bloqueo a nivel de sesión, se libera al final o en el CATCH)
        EXEC @LOCK_RESULT = sp_getapplock
             @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', @LockMode = 'Exclusive',
             @LockOwner = 'Session', @LockTimeout = 0;

        IF @LOCK_RESULT < 0
            THROW 50011, 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6 ya se está ejecutando en otra sesión.', 1;

        /* ==============================================================================
           1. FECHAS Y CALENDARIO
           ============================================================================== */
        SELECT @FECHA_SEMILLA = MAX(C.FEC_CALENDARIO)
        FROM dbo.BDS_CALENDARIOS C
        WHERE C.COD_CALENDARIO = 1
          AND C.IND_DIA_HABIL  = 'S'
          AND C.FEC_CALENDARIO <= EOMONTH(@FECHA_PROCESO, -1);

        IF @FECHA_SEMILLA IS NULL
            THROW 50010, 'No se encontró día hábil anterior al mes en BDS_CALENDARIOS (COD_CALENDARIO = 1).', 1;

        SELECT
            CAST(C.FEC_CALENDARIO AS DATE) AS FECHA_PROCESO,
            C.IND_DIA_HABIL,
            CAST(MAX(CASE WHEN C.IND_DIA_HABIL = 'S' THEN C.FEC_CALENDARIO END)
                 OVER (ORDER BY C.FEC_CALENDARIO ROWS UNBOUNDED PRECEDING) AS DATE) AS FECHA_ORIGEN
        INTO #CAL
        FROM dbo.BDS_CALENDARIOS C
        WHERE C.COD_CALENDARIO = 1
          AND C.FEC_CALENDARIO BETWEEN @FECHA_SEMILLA AND @FECHA_FIN;

        SELECT FECHA_ORIGEN, MIN(FECHA_PROCESO) AS DIA_MIN, MAX(FECHA_PROCESO) AS DIA_MAX
        INTO #ORIGENES
        FROM #CAL
        WHERE FECHA_PROCESO >= @MES_INI
        GROUP BY FECHA_ORIGEN;

        /* ==============================================================================
           2. #BASE: saldos de los días de origen, deduplicados (heap + TABLOCK, día por día)  [M4]
           ============================================================================== */
        SELECT TOP (0)
            CAST('' AS VARCHAR(200))  AS ID_OPERACION_CIERRE,      -- VALIDAR (V3)
            CAST(NULL AS DATE)        AS FECHA_PROCESO,
            s.COD_RUBRO,
            s.COD_EMPRESA, s.COD_SUCURSAL, s.COD_MONEDA, s.COD_PAPEL, s.PCT_TASA, s.NUM_CUENTA_BT,
            s.COD_OPERACION, s.COD_EJECUTIVO, s.COD_SUB_OPERACION, s.COD_TIPO_OPERACION, s.COD_MODULO,
            s.COD_MODULO_PRODUCTO, s.FEC_VENCIMIENTO, s.FEC_VALOR, s.IND_CATEGORIA_RIESGO,
            s.COD_ACTI_BCO_CENTRAL, s.COD_PRODUCTO, s.FUENTE,
            s.MTO_SALDO_ORIGEN, s.MTO_SALDO_MN, s.MTO_SALDO_ME, s.MTO_SALDO_MO, s.MTO_INTERES, s.MTO_PREVISIONES
        INTO #BASE
        FROM dbo.BDS_SALDOS_CIERRE s;

        DECLARE cur_origen CURSOR LOCAL FAST_FORWARD FOR
            SELECT FECHA_ORIGEN FROM #ORIGENES ORDER BY FECHA_ORIGEN;

        OPEN cur_origen;
        FETCH NEXT FROM cur_origen INTO @ORIGEN;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            INSERT INTO #BASE WITH (TABLOCK) (
                ID_OPERACION_CIERRE, FECHA_PROCESO, COD_RUBRO,
                COD_EMPRESA, COD_SUCURSAL, COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT,
                COD_OPERACION, COD_EJECUTIVO, COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO,
                COD_MODULO_PRODUCTO, FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO,
                COD_ACTI_BCO_CENTRAL, COD_PRODUCTO, FUENTE,
                MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES)
            SELECT
                x.ID_OPERACION_CIERRE, @ORIGEN, x.COD_RUBRO,
                x.COD_EMPRESA, x.COD_SUCURSAL, x.COD_MONEDA, x.COD_PAPEL, x.PCT_TASA, x.NUM_CUENTA_BT,
                x.COD_OPERACION, x.COD_EJECUTIVO, x.COD_SUB_OPERACION, x.COD_TIPO_OPERACION, x.COD_MODULO,
                x.COD_MODULO_PRODUCTO, x.FEC_VENCIMIENTO, x.FEC_VALOR, x.IND_CATEGORIA_RIESGO,
                x.COD_ACTI_BCO_CENTRAL, x.COD_PRODUCTO, x.FUENTE,
                x.MTO_SALDO_ORIGEN, x.MTO_SALDO_MN, x.MTO_SALDO_ME, x.MTO_SALDO_MO, x.MTO_INTERES, x.MTO_PREVISIONES
            FROM (
                SELECT
                    s.*,
                    k.ID_OPERACION_CIERRE,
                    ROW_NUMBER() OVER (PARTITION BY k.ID_OPERACION_CIERRE, s.COD_RUBRO
                                       ORDER BY s.FECHA_CARGA DESC, s.BATCH_ID DESC) AS RN   -- VALIDAR (V2)
                FROM dbo.BDS_SALDOS_CIERRE s
                CROSS APPLY (
                    SELECT CAST(CONCAT(s.COD_EMPRESA, '|', s.COD_MODULO, '|', s.COD_SUCURSAL, '|',
                                       s.COD_MONEDA, '|', s.COD_PAPEL, '|', s.NUM_CUENTA_BT, '|',
                                       s.COD_OPERACION, '|', s.COD_SUB_OPERACION, '|', s.COD_TIPO_OPERACION)
                                AS VARCHAR(200)) AS ID_OPERACION_CIERRE
                ) k
                WHERE s.FECHA_PROCESO >= @ORIGEN
                  AND s.FECHA_PROCESO <  DATEADD(DAY, 1, @ORIGEN)
            ) x
            WHERE x.RN = 1;

            FETCH NEXT FROM cur_origen INTO @ORIGEN;
        END

        CLOSE cur_origen;
        DEALLOCATE cur_origen;

        -- El índice se crea después de la carga (en tempdb la creación es mínimamente registrada)
        CREATE UNIQUE CLUSTERED INDEX IX_BASE ON #BASE (FECHA_PROCESO, ID_OPERACION_CIERRE, COD_RUBRO);

        /* ==============================================================================
           3. #KEYS y #ULTIMO (SELECT INTO = mínimamente registrado)
           ============================================================================== */
        SELECT
            b.ID_OPERACION_CIERRE,
            b.COD_RUBRO,
            MIN(o.DIA_MIN) AS PRIMER_DIA,
            MAX(o.DIA_MAX) AS ULTIMO_DIA
        INTO #KEYS
        FROM #BASE b
        JOIN #ORIGENES o ON o.FECHA_ORIGEN = b.FECHA_PROCESO
        GROUP BY b.ID_OPERACION_CIERRE, b.COD_RUBRO;

        CREATE UNIQUE CLUSTERED INDEX IX_KEYS ON #KEYS (ID_OPERACION_CIERRE, COD_RUBRO);

        -- Atributos vigentes por llave: arranca con los del primer registro del mes
        SELECT
            b.ID_OPERACION_CIERRE, b.COD_RUBRO,
            b.COD_EMPRESA, b.COD_SUCURSAL, b.COD_MONEDA, b.COD_PAPEL, b.PCT_TASA, b.NUM_CUENTA_BT,
            b.COD_OPERACION, b.COD_EJECUTIVO, b.COD_SUB_OPERACION, b.COD_TIPO_OPERACION, b.COD_MODULO,
            b.COD_MODULO_PRODUCTO, b.FEC_VENCIMIENTO, b.FEC_VALOR, b.IND_CATEGORIA_RIESGO,
            b.COD_ACTI_BCO_CENTRAL, b.COD_PRODUCTO, b.FUENTE
        INTO #ULTIMO
        FROM #KEYS k
        JOIN #CAL c   ON c.FECHA_PROCESO = k.PRIMER_DIA
        JOIN #BASE b  ON b.FECHA_PROCESO = c.FECHA_ORIGEN
                     AND b.ID_OPERACION_CIERRE = k.ID_OPERACION_CIERRE
                     AND b.COD_RUBRO = k.COD_RUBRO;

        CREATE UNIQUE CLUSTERED INDEX IX_ULTIMO ON #ULTIMO (ID_OPERACION_CIERRE, COD_RUBRO);

        /* ==============================================================================
           4. CARGA AL DESTINO, UNA TRANSACCIÓN CORTA POR DÍA  [M2] [C01]
           ============================================================================== */
        DECLARE cur_dia CURSOR LOCAL FAST_FORWARD FOR
            SELECT FECHA_PROCESO, FECHA_ORIGEN, IND_DIA_HABIL
            FROM #CAL
            WHERE FECHA_PROCESO >= @MES_INI
            ORDER BY FECHA_PROCESO;

        OPEN cur_dia;
        FETCH NEXT FROM cur_dia INTO @DIA, @ORIGEN, @HABIL;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRANSACTION;

            DELETE FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
            WHERE FECHA_PROCESO >= @DIA
              AND FECHA_PROCESO <  DATEADD(DAY, 1, @DIA);

            -- 4.1 Registros del día (ORIGINAL) o copia del último día hábil (COPIA_HABIL)
            INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
            SELECT
                b.ID_OPERACION_CIERRE, @DIA, b.COD_EMPRESA, YEAR(@DIA), MONTH(@DIA), b.COD_SUCURSAL, b.COD_RUBRO,
                b.COD_MONEDA, b.COD_PAPEL, b.PCT_TASA, b.NUM_CUENTA_BT, b.COD_OPERACION, b.COD_EJECUTIVO,
                b.COD_SUB_OPERACION, b.COD_TIPO_OPERACION, b.COD_MODULO, b.COD_MODULO_PRODUCTO,
                b.FEC_VENCIMIENTO, b.FEC_VALOR, b.IND_CATEGORIA_RIESGO, b.COD_ACTI_BCO_CENTRAL, b.COD_PRODUCTO,
                b.MTO_SALDO_ORIGEN, b.MTO_SALDO_MN, b.MTO_SALDO_ME, b.MTO_SALDO_MO, b.MTO_INTERES, b.MTO_PREVISIONES,
                @HABIL,
                CASE WHEN @DIA = @ORIGEN THEN 'ORIGINAL' ELSE 'COPIA_HABIL' END,
                b.FUENTE
            FROM #BASE b
            WHERE b.FECHA_PROCESO = @ORIGEN;

            SET @FILAS += @@ROWCOUNT;

            -- 4.2 Rellenos: llaves del mes sin registro en el día → montos en 0
            INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
            SELECT
                u.ID_OPERACION_CIERRE, @DIA, u.COD_EMPRESA, YEAR(@DIA), MONTH(@DIA), u.COD_SUCURSAL, u.COD_RUBRO,
                u.COD_MONEDA, u.COD_PAPEL, u.PCT_TASA, u.NUM_CUENTA_BT, u.COD_OPERACION, u.COD_EJECUTIVO,
                u.COD_SUB_OPERACION, u.COD_TIPO_OPERACION, u.COD_MODULO, u.COD_MODULO_PRODUCTO,
                u.FEC_VENCIMIENTO, u.FEC_VALOR, u.IND_CATEGORIA_RIESGO, u.COD_ACTI_BCO_CENTRAL, u.COD_PRODUCTO,
                0, 0, 0, 0, 0, 0,
                @HABIL,
                CASE WHEN @DIA < k.PRIMER_DIA THEN 'RELLENO_INICIO_MES'
                     WHEN @DIA > k.ULTIMO_DIA THEN 'RELLENO_FIN_MES'
                     ELSE 'RELLENO_INTERMEDIO' END,
                u.FUENTE
            FROM #KEYS k
            JOIN #ULTIMO u
              ON u.ID_OPERACION_CIERRE = k.ID_OPERACION_CIERRE
             AND u.COD_RUBRO = k.COD_RUBRO
            WHERE NOT EXISTS (
                SELECT 1 FROM #BASE b
                WHERE b.FECHA_PROCESO = @ORIGEN
                  AND b.ID_OPERACION_CIERRE = k.ID_OPERACION_CIERRE
                  AND b.COD_RUBRO = k.COD_RUBRO);

            SET @FILAS += @@ROWCOUNT;

            COMMIT TRANSACTION;          -- fin del lote del día: el registro de transacciones ya se puede liberar

            -- 4.3 En días hábiles se actualizan los atributos vigentes (fuera de la transacción del destino)
            IF @DIA = @ORIGEN
                UPDATE u
                   SET u.COD_EMPRESA = b.COD_EMPRESA, u.COD_SUCURSAL = b.COD_SUCURSAL, u.COD_MONEDA = b.COD_MONEDA,
                       u.COD_PAPEL = b.COD_PAPEL, u.PCT_TASA = b.PCT_TASA, u.NUM_CUENTA_BT = b.NUM_CUENTA_BT,
                       u.COD_OPERACION = b.COD_OPERACION, u.COD_EJECUTIVO = b.COD_EJECUTIVO,
                       u.COD_SUB_OPERACION = b.COD_SUB_OPERACION, u.COD_TIPO_OPERACION = b.COD_TIPO_OPERACION,
                       u.COD_MODULO = b.COD_MODULO, u.COD_MODULO_PRODUCTO = b.COD_MODULO_PRODUCTO,
                       u.FEC_VENCIMIENTO = b.FEC_VENCIMIENTO, u.FEC_VALOR = b.FEC_VALOR,
                       u.IND_CATEGORIA_RIESGO = b.IND_CATEGORIA_RIESGO, u.COD_ACTI_BCO_CENTRAL = b.COD_ACTI_BCO_CENTRAL,
                       u.COD_PRODUCTO = b.COD_PRODUCTO, u.FUENTE = b.FUENTE
                FROM #ULTIMO u
                JOIN #BASE b
                  ON b.ID_OPERACION_CIERRE = u.ID_OPERACION_CIERRE
                 AND b.COD_RUBRO = u.COD_RUBRO
                WHERE b.FECHA_PROCESO = @ORIGEN;

            FETCH NEXT FROM cur_dia INTO @DIA, @ORIGEN, @HABIL;
        END

        CLOSE cur_dia;
        DEALLOCATE cur_dia;

        EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', @LockOwner = 'Session';

        /* ==============================================================================
           Log de fin
           ============================================================================== */
        IF @FILAS = 0
            SET @MSG_ERROR = CONCAT(N'No se insertaron registros en BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO para ',
                                    CONVERT(NVARCHAR(10), @MES_INI, 23), N' a ', CONVERT(NVARCHAR(10), @FECHA_FIN, 23), N'.');

        UPDATE dbo.ctl_log_proceso
           SET estado           = CASE WHEN @MSG_ERROR IS NULL THEN 'TERMINADO' ELSE 'WARNING' END,
               fec_termino      = SYSDATETIME(),
               filas_insertadas = @FILAS,
               msg_error        = @MSG_ERROR
         WHERE id_log = @ID_LOG;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        IF CURSOR_STATUS('local', 'cur_origen') >= 0 CLOSE cur_origen;
        IF CURSOR_STATUS('local', 'cur_origen') > -3 DEALLOCATE cur_origen;
        IF CURSOR_STATUS('local', 'cur_dia') >= 0 CLOSE cur_dia;
        IF CURSOR_STATUS('local', 'cur_dia') > -3 DEALLOCATE cur_dia;

        IF APPLOCK_MODE('public', 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', 'Session') <> 'NoLock'
            EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', @LockOwner = 'Session';

        SET @MSG_ERROR = CONCAT(N'Error ', ERROR_NUMBER(), N' (línea ', ERROR_LINE(), N'): ', ERROR_MESSAGE(),
                                CASE WHEN @DIA IS NOT NULL
                                     THEN CONCAT(N' | Último día en proceso: ', CONVERT(NVARCHAR(10), @DIA, 23),
                                                 N'. Los días anteriores ya quedaron confirmados; vuelve a ejecutar el mes.')
                                     ELSE N'' END);

        UPDATE dbo.ctl_log_proceso
           SET estado = 'ERROR', fec_termino = SYSDATETIME(), filas_insertadas = @FILAS,
               msg_error = LEFT(@MSG_ERROR, 4000)
         WHERE id_log = @ID_LOG;

        THROW;
    END CATCH
END;
GO

/* ------------------------------------------------------------------------------------
   Índices recomendados en las tablas físicas (si no existen)
   ------------------------------------------------------------------------------------
   CREATE INDEX IX_BSC_FECHA   ON dbo.BDS_SALDOS_CIERRE (FECHA_PROCESO);
   CREATE INDEX IX_CAL_COD_FEC ON dbo.BDS_CALENDARIOS (COD_CALENDARIO, FEC_CALENDARIO) INCLUDE (IND_DIA_HABIL);
   CREATE INDEX IX_PPL_FECHA   ON dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (FECHA_PROCESO);

   Ejecución (NO dentro de BEGIN TRAN):
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6 @FECHA_PROCESO = '2026-10-31';
   ------------------------------------------------------------------------------------ */
