/* =====================================================================================
   PROCEDIMIENTO : dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6        (versión 3)
   MOTOR         : SQL Server 2016 SP1+
   DESCRIPCIÓN   : Arma la serie DIARIA y DENSA de saldos por (operación, rubro) del mes,
                   desde el día 1 hasta @FECHA_PROCESO, en BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO.
                     - Día hábil     -> saldo del día                      (TIPO_ORIGEN = ORIGINAL)
                     - Día no hábil  -> copia del último día hábil         (TIPO_ORIGEN = COPIA_HABIL)
                     - Días sin dato -> fila con montos en 0, con los atributos del registro
                                        anterior (o del primero, si es inicio de mes)
                                        (TIPO_ORIGEN = RELLENO_INICIO_MES / RELLENO_INTERMEDIO / RELLENO_FIN_MES)

   VERSIÓN 3: TEMPDB CASI SIN USO (error 9002 en el registro de transacciones de tempdb)
   -------------------------------------------------------------------------------------
   [M1] Sin recursión: los días salen de #CAL (como máximo 31 filas + la semilla).
   [M2] Los saldos ya NO se copian a tempdb. Se leen de BDS_SALDOS_CIERRE y se escriben
        directo en el destino, en transacciones cortas por día y por lote.
   [M3] En tempdb solo quedan #CAL y #KEYS (una fila por operación/rubro),
        todas creadas con SELECT INTO (mínimamente registrado). No hay UPDATE masivos en tempdb.
   [M4] @N_LOTES (por defecto 1) parte cada día en N lotes por NUM_CUENTA_BT, cada uno con su
        propio COMMIT. Si el registro de transacciones sigue llenándose, sube a 4, 8, 16...
   [M5] Se rechaza la ejecución dentro de una transacción abierta y se fuerza
        IMPLICIT_TRANSACTIONS OFF.
   [M6] Ya no aparece la advertencia "Valor nulo eliminado por una operación de agregado".

   FASES
   -------------------------------------------------------------------------------------
   A. Por día (y lote): DELETE del día + INSERT de los registros ORIGINAL / COPIA_HABIL.
   B. #KEYS = (operación, rubro) presentes en el mes, con su primer y último día.
   C. Por día (y lote): INSERT de los rellenos en 0 que falten, con los atributos del
      registro anterior de la misma llave (o del primero, si es inicio de mes),
      leídos desde el destino.
   Si falla a mitad: volver a ejecutar el mes (el proceso es idempotente; la fase A borra cada día).

   CAMBIOS DE LÓGICA RESPECTO A LA VERSIÓN SINGLESTORE
   -------------------------------------------------------------------------------------
   [C01] DELETE por rango de fechas (antes borraba el mismo mes de todos los años anteriores).
   [C02] ANIO / MES desde la fecha generada.   [C03] TIPO_ORIGEN de los rellenos.
   [C04] IND_DIA_HABIL del calendario.         [C05] Duplicados: se toma la carga más reciente.
   [C06] Se eliminan pasos que no hacían nada. [C07] Solo se generan rellenos del mes en proceso.
   [C09] CONCAT trata NULL como ''.

   ÍNDICES NECESARIOS EN EL DESTINO (créalos antes de la primera ejecución)
   -------------------------------------------------------------------------------------
   CREATE INDEX IX_PPL_FECHA_LLAVE ON dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
          (FECHA_PROCESO, ID_OPERACION_CIERRE, COD_RUBRO);
   CREATE INDEX IX_PPL_LLAVE_FECHA ON dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
          (ID_OPERACION_CIERRE, COD_RUBRO, FECHA_PROCESO);
   CREATE INDEX IX_BSC_FECHA       ON dbo.BDS_SALDOS_CIERRE (FECHA_PROCESO);

   PUNTOS A VALIDAR (busca  -- VALIDAR)
   -------------------------------------------------------------------------------------
   V1. Si @FECHA_PROCESO llega NULL se usa el día anterior.   V2. Criterio de deduplicación.
   V3. Formato y largo de la llave (VARCHAR(200)).           V4. Consumidores de TIPO_ORIGEN.
   ===================================================================================== */

CREATE OR ALTER PROCEDURE dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6
    @FECHA_PROCESO DATE = NULL,
    @N_LOTES       INT  = 1           -- [M4] lotes por día (1, 4, 8, 16...)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET IMPLICIT_TRANSACTIONS OFF;

    IF @@TRANCOUNT > 0
        THROW 50012, 'Este SP no debe ejecutarse dentro de una transacción abierta (confirma por día y por lote).', 1;

    IF @FECHA_PROCESO IS NULL                                        -- VALIDAR (V1)
        SET @FECHA_PROCESO = DATEADD(DAY, -1, CAST(SYSDATETIME() AS DATE));

    IF @N_LOTES IS NULL OR @N_LOTES < 1 SET @N_LOTES = 1;

    DECLARE
        @MES_INI        DATE = DATEFROMPARTS(YEAR(@FECHA_PROCESO), MONTH(@FECHA_PROCESO), 1),
        @FECHA_FIN      DATE = @FECHA_PROCESO,
        @FIN_EXCL       DATE = DATEADD(DAY, 1, @FECHA_PROCESO),
        @FECHA_SEMILLA  DATE,
        @DIA            DATE,
        @DIA_SIG        DATE,
        @ORIGEN         DATE,
        @ORIGEN_SIG     DATE,
        @HABIL          CHAR(1),
        @LOTE           INT,
        @FASE           VARCHAR(10) = 'INICIO',
        @FILAS          BIGINT = 0,
        @MSG_ERROR      NVARCHAR(4000) = NULL,
        @ID_LOG         BIGINT,
        @LOCK_RESULT    INT;

    INSERT INTO dbo.ctl_log_proceso (nom_proceso, tabla_origen, tabla_destino, fec_inicio, estado)
    VALUES (N'DATAHUB_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO', N'BDS_SALDOS_CIERRE',
            N'BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO', SYSDATETIME(), 'EJECUTANDO');
    SET @ID_LOG = SCOPE_IDENTITY();

    BEGIN TRY

        EXEC @LOCK_RESULT = sp_getapplock
             @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', @LockMode = 'Exclusive',
             @LockOwner = 'Session', @LockTimeout = 0;

        IF @LOCK_RESULT < 0
            THROW 50011, 'El SP ya se está ejecutando en otra sesión.', 1;

        /* ==============================================================================
           CALENDARIO
           ============================================================================== */
        SELECT @FECHA_SEMILLA = MAX(C.FEC_CALENDARIO)
        FROM dbo.BDS_CALENDARIOS C
        WHERE C.COD_CALENDARIO = 1
          AND C.IND_DIA_HABIL  = 'S'
          AND C.FEC_CALENDARIO <= EOMONTH(@FECHA_PROCESO, -1);

        IF @FECHA_SEMILLA IS NULL
            THROW 50010, 'No se encontró día hábil anterior al mes en BDS_CALENDARIOS (COD_CALENDARIO = 1).', 1;

        -- [M6] ELSE con fecha mínima en vez de NULL: misma salida, sin la advertencia
        SELECT
            CAST(C.FEC_CALENDARIO AS DATE) AS FECHA_PROCESO,
            C.IND_DIA_HABIL,
            CAST(MAX(CASE WHEN C.IND_DIA_HABIL = 'S' THEN C.FEC_CALENDARIO ELSE '19000101' END)
                 OVER (ORDER BY C.FEC_CALENDARIO ROWS UNBOUNDED PRECEDING) AS DATE) AS FECHA_ORIGEN
        INTO #CAL
        FROM dbo.BDS_CALENDARIOS C
        WHERE C.COD_CALENDARIO = 1
          AND C.FEC_CALENDARIO BETWEEN @FECHA_SEMILLA AND @FECHA_FIN;

        /* ==============================================================================
           FASE A: ORIGINAL / COPIA_HABIL → destino (por día y por lote)
           ============================================================================== */
        SET @FASE = 'A';

        DECLARE cur_dia CURSOR LOCAL STATIC READ_ONLY FOR
            SELECT FECHA_PROCESO, FECHA_ORIGEN, IND_DIA_HABIL
            FROM #CAL
            WHERE FECHA_PROCESO >= @MES_INI
            ORDER BY FECHA_PROCESO;

        OPEN cur_dia;
        FETCH NEXT FROM cur_dia INTO @DIA, @ORIGEN, @HABIL;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @DIA_SIG    = DATEADD(DAY, 1, @DIA);
            SET @ORIGEN_SIG = DATEADD(DAY, 1, @ORIGEN);

            -- Limpieza del día en su propia transacción corta
            DELETE FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
            WHERE FECHA_PROCESO >= @DIA AND FECHA_PROCESO < @DIA_SIG;

            SET @LOTE = 0;
            WHILE @LOTE < @N_LOTES
            BEGIN
                INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                    ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                    COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                    COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                    FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                    MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                    IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
                SELECT
                    x.ID_OPERACION_CIERRE, @DIA, x.COD_EMPRESA, YEAR(@DIA), MONTH(@DIA), x.COD_SUCURSAL, x.COD_RUBRO,
                    x.COD_MONEDA, x.COD_PAPEL, x.PCT_TASA, x.NUM_CUENTA_BT, x.COD_OPERACION, x.COD_EJECUTIVO,
                    x.COD_SUB_OPERACION, x.COD_TIPO_OPERACION, x.COD_MODULO, x.COD_MODULO_PRODUCTO,
                    x.FEC_VENCIMIENTO, x.FEC_VALOR, x.IND_CATEGORIA_RIESGO, x.COD_ACTI_BCO_CENTRAL, x.COD_PRODUCTO,
                    x.MTO_SALDO_ORIGEN, x.MTO_SALDO_MN, x.MTO_SALDO_ME, x.MTO_SALDO_MO, x.MTO_INTERES, x.MTO_PREVISIONES,
                    @HABIL,
                    CASE WHEN @DIA = @ORIGEN THEN 'ORIGINAL' ELSE 'COPIA_HABIL' END,
                    x.FUENTE
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
                                    AS VARCHAR(200)) AS ID_OPERACION_CIERRE      -- VALIDAR (V3)
                    ) k
                    WHERE s.FECHA_PROCESO >= @ORIGEN
                      AND s.FECHA_PROCESO <  @ORIGEN_SIG
                      -- Lote por cuenta: todas las filas de una misma llave caen en el mismo lote
                      AND (CHECKSUM(s.NUM_CUENTA_BT) & 2147483647) % @N_LOTES = @LOTE
                ) x
                WHERE x.RN = 1;

                SET @FILAS += @@ROWCOUNT;
                SET @LOTE  += 1;
            END

            FETCH NEXT FROM cur_dia INTO @DIA, @ORIGEN, @HABIL;
        END

        CLOSE cur_dia;

        /* ==============================================================================
           FASE B: llaves del mes con su primer y último día (SELECT INTO, una fila por llave)
           ============================================================================== */
        SET @FASE = 'B';

        SELECT
            ID_OPERACION_CIERRE,
            COD_RUBRO,
            CAST(MIN(FECHA_PROCESO) AS DATE) AS PRIMER_DIA,
            CAST(MAX(FECHA_PROCESO) AS DATE) AS ULTIMO_DIA
        INTO #KEYS
        FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO
        WHERE FECHA_PROCESO >= @MES_INI
          AND FECHA_PROCESO <  @FIN_EXCL
        GROUP BY ID_OPERACION_CIERRE, COD_RUBRO;

        CREATE UNIQUE CLUSTERED INDEX IX_KEYS ON #KEYS (ID_OPERACION_CIERRE, COD_RUBRO);

        /* ==============================================================================
           FASE C: rellenos en 0 → destino (por día y por lote)
           ============================================================================== */
        SET @FASE = 'C';

        OPEN cur_dia;
        FETCH NEXT FROM cur_dia INTO @DIA, @ORIGEN, @HABIL;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @DIA_SIG = DATEADD(DAY, 1, @DIA);
            SET @LOTE = 0;

            WHILE @LOTE < @N_LOTES
            BEGIN
                INSERT INTO dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO (
                    ID_OPERACION_CIERRE, FECHA_PROCESO, COD_EMPRESA, ANIO, MES, COD_SUCURSAL, COD_RUBRO,
                    COD_MONEDA, COD_PAPEL, PCT_TASA, NUM_CUENTA_BT, COD_OPERACION, COD_EJECUTIVO,
                    COD_SUB_OPERACION, COD_TIPO_OPERACION, COD_MODULO, COD_MODULO_PRODUCTO,
                    FEC_VENCIMIENTO, FEC_VALOR, IND_CATEGORIA_RIESGO, COD_ACTI_BCO_CENTRAL, COD_PRODUCTO,
                    MTO_SALDO_ORIGEN, MTO_SALDO_MN, MTO_SALDO_ME, MTO_SALDO_MO, MTO_INTERES, MTO_PREVISIONES,
                    IND_DIA_HABIL, TIPO_ORIGEN, FUENTE)
                SELECT
                    k.ID_OPERACION_CIERRE, @DIA, a.COD_EMPRESA, YEAR(@DIA), MONTH(@DIA), a.COD_SUCURSAL, k.COD_RUBRO,
                    a.COD_MONEDA, a.COD_PAPEL, a.PCT_TASA, a.NUM_CUENTA_BT, a.COD_OPERACION, a.COD_EJECUTIVO,
                    a.COD_SUB_OPERACION, a.COD_TIPO_OPERACION, a.COD_MODULO, a.COD_MODULO_PRODUCTO,
                    a.FEC_VENCIMIENTO, a.FEC_VALOR, a.IND_CATEGORIA_RIESGO, a.COD_ACTI_BCO_CENTRAL, a.COD_PRODUCTO,
                    0, 0, 0, 0, 0, 0,
                    @HABIL,
                    CASE WHEN @DIA < k.PRIMER_DIA THEN 'RELLENO_INICIO_MES'
                         WHEN @DIA > k.ULTIMO_DIA THEN 'RELLENO_FIN_MES'
                         ELSE 'RELLENO_INTERMEDIO' END,
                    a.FUENTE
                FROM #KEYS k
                CROSS APPLY (
                    -- Atributos: el primer registro (si el día está antes del primero) o el
                    -- registro anterior más cercano de la misma llave dentro del mes
                    SELECT TOP (1)
                        p.COD_EMPRESA, p.COD_SUCURSAL, p.COD_MONEDA, p.COD_PAPEL, p.PCT_TASA, p.NUM_CUENTA_BT,
                        p.COD_OPERACION, p.COD_EJECUTIVO, p.COD_SUB_OPERACION, p.COD_TIPO_OPERACION, p.COD_MODULO,
                        p.COD_MODULO_PRODUCTO, p.FEC_VENCIMIENTO, p.FEC_VALOR, p.IND_CATEGORIA_RIESGO,
                        p.COD_ACTI_BCO_CENTRAL, p.COD_PRODUCTO, p.FUENTE
                    FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO p
                    WHERE p.ID_OPERACION_CIERRE = k.ID_OPERACION_CIERRE
                      AND p.COD_RUBRO = k.COD_RUBRO
                      AND (   (@DIA < k.PRIMER_DIA AND p.FECHA_PROCESO = k.PRIMER_DIA)
                           OR (@DIA > k.PRIMER_DIA AND p.FECHA_PROCESO >= @MES_INI AND p.FECHA_PROCESO < @DIA))
                    ORDER BY p.FECHA_PROCESO DESC
                ) a
                WHERE (CHECKSUM(k.ID_OPERACION_CIERRE) & 2147483647) % @N_LOTES = @LOTE
                  AND NOT EXISTS (
                        SELECT 1
                        FROM dbo.BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_LIMPIO d
                        WHERE d.FECHA_PROCESO >= @DIA AND d.FECHA_PROCESO < @DIA_SIG
                          AND d.ID_OPERACION_CIERRE = k.ID_OPERACION_CIERRE
                          AND d.COD_RUBRO = k.COD_RUBRO);

                SET @FILAS += @@ROWCOUNT;
                SET @LOTE  += 1;
            END

            FETCH NEXT FROM cur_dia INTO @DIA, @ORIGEN, @HABIL;
        END

        CLOSE cur_dia;
        DEALLOCATE cur_dia;

        EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', @LockOwner = 'Session';

        /* ==============================================================================
           Log de fin
           ============================================================================== */
        IF @FILAS = 0
            SET @MSG_ERROR = CONCAT(N'No se insertaron registros para ',
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

        IF CURSOR_STATUS('local', 'cur_dia') >= 0 CLOSE cur_dia;
        IF CURSOR_STATUS('local', 'cur_dia') > -3 DEALLOCATE cur_dia;

        IF APPLOCK_MODE('public', 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', 'Session') <> 'NoLock'
            EXEC sp_releaseapplock @Resource = 'SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6', @LockOwner = 'Session';

        SET @MSG_ERROR = CONCAT(N'Error ', ERROR_NUMBER(), N' (línea ', ERROR_LINE(), N'): ', ERROR_MESSAGE(),
                                N' | Fase ', @FASE,
                                CASE WHEN @DIA IS NOT NULL
                                     THEN CONCAT(N', día ', CONVERT(NVARCHAR(10), @DIA, 23), N', lote ', @LOTE)
                                     ELSE N'' END,
                                N'. Vuelve a ejecutar el mes.');

        UPDATE dbo.ctl_log_proceso
           SET estado = 'ERROR', fec_termino = SYSDATETIME(), filas_insertadas = @FILAS,
               msg_error = LEFT(@MSG_ERROR, 4000)
         WHERE id_log = @ID_LOG;

        THROW;
    END CATCH
END;
GO

/* ------------------------------------------------------------------------------------
   Ejecución (fuera de cualquier BEGIN TRAN):
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6 @FECHA_PROCESO = '2026-10-31';
   EXEC dbo.SP_BDS_SALDOS_OPERATIVOS_PRE_PROMEDIO_H6 @FECHA_PROCESO = '2026-10-31', @N_LOTES = 8;
   ------------------------------------------------------------------------------------ */
