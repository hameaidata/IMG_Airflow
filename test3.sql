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

   MEMORIA (antes: 3 CTE WITH RECURSIVE)
   -------------------------------------------------------------------------------------
   - No hay recursión: los días salen de #CAL (como máximo 31 filas + el día semilla).
   - Se procesa UN DÍA POR VUELTA: cada sentencia trabaja con un día de datos, así que la
     memoria que pide SQL Server (memory grant) no crece con el tamaño del mes.
   - Los datos intermedios viven en #temporales (tempdb, en disco), no en RAM.
   - La deduplicación con ROW_NUMBER se hace por día (ordenamientos chicos).

   CAMBIOS RESPECTO A LA VERSIÓN SINGLESTORE
   -------------------------------------------------------------------------------------
   [C01] DELETE del destino por rango de fechas del mes. Antes era MONTH()=V_MES AND
         FECHA<=V_FECHA_PROCESO, que BORRABA EL MISMO MES DE TODOS LOS AÑOS ANTERIORES.
   [C02] ANIO / MES se calculan desde la fecha del día generado. Antes, en las copias,
         venían de la fecha de origen (mes anterior) y en los rellenos quedaban en NULL.
   [C03] TIPO_ORIGEN de los rellenos: RELLENO_INICIO_MES / _INTERMEDIO / _FIN_MES (antes NULL).
   [C04] IND_DIA_HABIL de los rellenos se toma del calendario (antes 'S' fijo, también en
         fines de semana).
   [C05] Duplicados en BDS_SALDOS_CIERRE por (llave, rubro, fecha): se toma la carga más
         reciente (FECHA_CARGA, BATCH_ID). Antes el GROUP BY final elegía una fila al azar.
   [C06] Se eliminan pasos que no hacían nada: TEMP_BASE_COMPLETA_POR_MES (filtro sin efecto),
         el split MISMO_DIA / ANTERIORES contra BDS_OPERACIONES (EXISTS + NOT EXISTS = todo),
         V_FECHA_INICIO_MES (no se usaba) y los ALTER TABLE DROP COLUMN.
   [C07] Solo se generan rellenos del mes en proceso. Antes también se generaban los del
         mes anterior y después se descartaban.
   [C08] #temporales (sin choque entre sesiones), TRY/CATCH, transacción y sp_getapplock.
   [C09] En SQL Server, CONCAT trata NULL como ''. Antes, si un componente de la llave era
         NULL, la llave completa quedaba NULL y esas operaciones se mezclaban entre sí.

   PUNTOS A VALIDAR (busca  -- VALIDAR)
   -------------------------------------------------------------------------------------
   V1. Si @FECHA_PROCESO llega NULL se usa el día anterior. Confirma que sea el comportamiento esperado.
   V2. Criterio de deduplicación [C05].
   V3. Formato de la llave ID_OPERACION_CIERRE (largo VARCHAR(200); en campos numéricos,
       CONCAT puede incluir decimales, p. ej. '1.00').
   V4. Si algún consumidor filtra por TIPO_ORIGEN IS NULL, ajústalo a [C03].
   ===================================================================================== */

CREATE OR ALTER PROCEDURE dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6
    @FECHA_PROCESO DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

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

        /* ==============================================================================
           1. FECHAS Y CALENDARIO (reemplaza PARAMETROS_TABLA y CALENDARIO_GLOBAL)
           ============================================================================== */
        SELECT @FECHA_SEMILLA = MAX(C.FEC_CALENDARIO)
        FROM dbo.BDS_CALENDARIOS C
        WHERE C.COD_CALENDARIO = 1
          AND C.IND_DIA_HABIL  = 'S'
          AND C.FEC_CALENDARIO <= EOMONTH(@FECHA_PROCESO, -1);

        IF @FECHA_SEMILLA IS NULL
            THROW 50010, 'No se encontró día hábil anterior al mes en BDS_CALENDARIOS (COD_CALENDARIO = 1).', 1;

        -- Un día por fila: semilla + días del mes hasta @FECHA_FIN (como máximo 31 filas).
        -- FECHA_ORIGEN = último día hábil <= fecha (de ese día se copian los saldos).
        SELECT
            CAST(C.FEC_CALENDARIO AS DATE) AS FECHA_PROCESO,
            C.IND_DIA_HABIL,
            CAST(MAX(CASE WHEN C.IND_DIA_HABIL = 'S' THEN C.FEC_CALENDARIO END)
                 OVER (ORDER BY C.FEC_CALENDARIO ROWS UNBOUNDED PRECEDING) AS DATE) AS FECHA_ORIGEN
        INTO #CAL
        FROM dbo.BDS_CALENDARIOS C
        WHERE C.COD_CALENDARIO = 1
          AND C.FEC_CALENDARIO BETWEEN @FECHA_SEMILLA AND @FECHA_FIN;

        CREATE UNIQUE CLUSTERED INDEX IX_CAL ON #CAL (FECHA_PROCESO);

        -- Por cada día de origen: primer y último día del mes que lo usan
        SELECT FECHA_ORIGEN, MIN(FECHA_PROCESO) AS DIA_MIN, MAX(FECHA_PROCESO) AS DIA_MAX
        INTO #ORIGENES
        FROM #CAL
        WHERE FECHA_PROCESO >= @MES_INI
        GROUP BY FECHA_ORIGEN;

        CREATE UNIQUE CLUSTERED INDEX IX_ORIGENES ON #ORIGENES (FECHA_ORIGEN);

        /* ==============================================================================
           2. #BASE: saldos de los días de origen, deduplicados (carga día por día)
              (reemplaza TEMP_BASE_INICIAL / TEMP_BASE_COMPLETA_POR_MES / BASE_TABLA_RANGO_FECHA)
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

        CREATE UNIQUE CLUSTERED INDEX IX_BASE ON #BASE (FECHA_PROCESO, ID_OPERACION_CIERRE, COD_RUBRO);

        DECLARE cur_origen CURSOR LOCAL FAST_FORWARD FOR
            SELECT FECHA_ORIGEN FROM #ORIGENES ORDER BY FECHA_ORIGEN;

        OPEN cur_origen;
        FETCH NEXT FROM cur_origen INTO @ORIGEN;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            INSERT INTO #BASE (
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

        /* ==============================================================================
           3. #KEYS: (operación, rubro) presentes en el mes, con su primer y último día
              (reemplaza DATAHUB_NULL_INICIO_MES / _INTERMEDIO / _FIN_MES)
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

        /* #ULTIMO: atributos vigentes de cada llave para los rellenos.
           Arranca con los del primer registro del mes (relleno de inicio) y se actualiza
           cada día hábil con el registro ORIGINAL (relleno intermedio y de fin de mes). */
        SELECT TOP (0)
            ID_OPERACION_CIERRE, COD_RUBRO,
            COD_EMPRESA, COD_SUCURSAL, COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT,
            COD_OPERACION, COD_EJECUTIVO, COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO,
            COD_MODULO_PRODUCTO, FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO,
            COD_ACTI_BCO_CENTRAL, COD_PRODUCTO, FUENTE
        INTO #ULTIMO
        FROM #BASE;

        CREATE UNIQUE CLUSTERED INDEX IX_ULTIMO ON #ULTIMO (ID_OPERACION_CIERRE, COD_RUBRO);

        INSERT INTO #ULTIMO
        SELECT
            b.ID_OPERACION_CIERRE, b.COD_RUBRO,
            b.COD_EMPRESA, b.COD_SUCURSAL, b.COD_MONEDA, b.COD_PAPEL, b.PCT_TASA, b.NUM_CUENTA_BT,
            b.COD_OPERACION, b.COD_EJECUTIVO, b.COD_SUB_OPERACION, b.COD_TIPO_OPERACION, b.COD_MODULO,
            b.COD_MODULO_PRODUCTO, b.FEC_VENCIMIENTO, b.FEC_VALOR, b.IND_CATEGORIA_RIESGO,
            b.COD_ACTI_BCO_CENTRAL, b.COD_PRODUCTO, b.FUENTE
        FROM #KEYS k
        JOIN #CAL c   ON c.FECHA_PROCESO = k.PRIMER_DIA
        JOIN #BASE b  ON b.FECHA_PROCESO = c.FECHA_ORIGEN
                     AND b.ID_OPERACION_CIERRE = k.ID_OPERACION_CIERRE
                     AND b.COD_RUBRO = k.COD_RUBRO;

        /* ==============================================================================
           4. SERIE DENSA DEL MES, UN DÍA POR VUELTA → #RESULT
           ============================================================================== */
        SELECT TOP (0) * INTO #RESULT FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO;   -- mismos tipos que el destino

        DECLARE cur_dia CURSOR LOCAL FAST_FORWARD FOR
            SELECT FECHA_PROCESO, FECHA_ORIGEN, IND_DIA_HABIL
            FROM #CAL
            WHERE FECHA_PROCESO >= @MES_INI
            ORDER BY FECHA_PROCESO;

        OPEN cur_dia;
        FETCH NEXT FROM cur_dia INTO @DIA, @ORIGEN, @HABIL;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- 4.1 Registros del día (ORIGINAL) o copia del último día hábil (COPIA_HABIL)
            INSERT INTO #RESULT (
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

            -- 4.2 Rellenos: llaves del mes sin registro en el día → montos en 0
            INSERT INTO #RESULT (
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
                @HABIL,                                                  -- [C04]
                CASE WHEN @DIA < k.PRIMER_DIA THEN 'RELLENO_INICIO_MES'  -- [C03]
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

            -- 4.3 En días hábiles se actualizan los atributos vigentes
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

        /* ==============================================================================
           5. CARGA AL DESTINO (DELETE + INSERT atómicos)  [C01] [C08]
           ============================================================================== */
        BEGIN TRANSACTION;

        EXEC @LOCK_RESULT = sp_getapplock
             @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', @LockMode = 'Exclusive',
             @LockOwner = 'Transaction', @LockTimeout = 0;

        IF @LOCK_RESULT < 0
            THROW 50011, 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6 ya se está ejecutando en otra sesión.', 1;

        DELETE FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
        WHERE FECHA_PROCESO >= @MES_INI
          AND FECHA_PROCESO <  DATEADD(DAY, 1, @FECHA_FIN);

        INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
            ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
            COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
            COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
            FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
            MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
            IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
        SELECT
            ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
            COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
            COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
            FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
            MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
            IND_DIA_HABIL, TIPO_ORIGEN, FUENTE
        FROM #RESULT;

        SET @FILAS = @@ROWCOUNT;

        COMMIT TRANSACTION;

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
        IF CURSOR_STATUS('local', 'cur_origen') >= 0 BEGIN CLOSE cur_origen; END
        IF CURSOR_STATUS('local', 'cur_origen') > -3 DEALLOCATE cur_origen;
        IF CURSOR_STATUS('local', 'cur_dia') >= 0 BEGIN CLOSE cur_dia; END
        IF CURSOR_STATUS('local', 'cur_dia') > -3 DEALLOCATE cur_dia;

        SET @MSG_ERROR = CONCAT(N'Error ', ERROR_NUMBER(), N' (línea ', ERROR_LINE(), N'): ', ERROR_MESSAGE());

        UPDATE dbo.ctl_log_proceso
           SET estado = 'ERROR', fec_termino = SYSDATETIME(), msg_error = LEFT(@MSG_ERROR, 4000)
         WHERE id_log = @ID_LOG;

        THROW;
    END CATCH
END;
GO

/* ------------------------------------------------------------------------------------
   Índices recomendados en las tablas físicas (si no existen)
   ------------------------------------------------------------------------------------
   CREATE INDEX IX_BSC_FECHA      ON dbo.BDS_SALDOS_CIERRE (FECHA_PROCESO);
   CREATE INDEX IX_CAL_COD_FEC    ON dbo.BDS_CALENDARIOS (COD_CALENDARIO, FEC_CALENDARIO) INCLUDE (IND_DIA_HABIL);
   CREATE INDEX IX_PPL_FECHA      ON dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (FECHA_PROCESO);

   Ejecución:
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6 @FECHA_PROCESO = '2026-10-31';
   ------------------------------------------------------------------------------------ */
