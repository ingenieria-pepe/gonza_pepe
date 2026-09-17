-- Migration 0019 — Linkear PieDeCamion ↔ PlanDeCargas.
--
-- Antes: el operario llenaba a mano todos los datos del camión en el form
-- (chofer, transportista, exportador, placas, AFIDI, etc.) aunque esos
-- datos ya estaban en el Plan de Cargas.
-- Ahora: en el form se puede elegir una carga del plan y los campos que
-- coinciden se auto-completan. Cuando se guarda el pie de camión, se
-- marca la carga como Descargado.

USE AlmarExtensiones;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PieDeCamion')
      AND name = 'plan_carga_id'
)
BEGIN
    ALTER TABLE dbo.PieDeCamion
        ADD plan_carga_id INT NULL
            CONSTRAINT FK_PieDeCamion_PlanDeCargas
            REFERENCES dbo.PlanDeCargas(id);
    -- Índice para el join inverso (¿qué pie-camión cargó esta carga del plan?)
    CREATE INDEX IX_PieDeCamion_plan_carga ON dbo.PieDeCamion(plan_carga_id);
END;
GO
