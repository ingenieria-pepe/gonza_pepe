-- Migration 0020 — Renombrar columnas de placas en PlanDeCargas para que
-- coincidan con la planilla física del Pie de Camión:
--   placas_tractor  → placa_camion   ("N° Placa Camión" en la planilla)
--   placas_remolque → placa_remolque
--
-- En el CSV original la columna "PLACAS T" es la del cabezal/tractor = la
-- "N° Placa Camión" de la planilla. "PLACAS R" es el remolque.

USE AlmarExtensiones;
GO

IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PlanDeCargas') AND name = 'placas_tractor'
)
BEGIN
    EXEC sp_rename 'dbo.PlanDeCargas.placas_tractor', 'placa_camion', 'COLUMN';
END;
GO

IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PlanDeCargas') AND name = 'placas_remolque'
)
BEGIN
    EXEC sp_rename 'dbo.PlanDeCargas.placas_remolque', 'placa_remolque', 'COLUMN';
END;
GO
