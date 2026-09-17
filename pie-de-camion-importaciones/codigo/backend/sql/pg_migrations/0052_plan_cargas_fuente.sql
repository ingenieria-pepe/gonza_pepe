-- PG Migration 0052 — Plan de Cargas: segunda planilla (camiones de OTROS países).
--
-- Además del Excel de Brasil/PY, ahora se espeja el "PROGRAMA DE ARRIBOS" de los
-- demás orígenes (Ecuador, Chile, Bolivia, Perú, Colombia, México, y ultramar:
-- Italia, Grecia, España, Egipto...). Ambas planillas viven en la MISMA tabla,
-- distinguidas por `fuente`:
--   'BR'    = planilla Brasil/Paraguay (la histórica)
--   'OTROS' = planilla de otros países
-- El sync de cada planilla REEMPLAZA solo sus propias filas (scoped por fuente),
-- así una no pisa a la otra. Las filas existentes son todas de la planilla BR.
--
-- La planilla OTROS trae estados extra: 'Mar' y 'Puerto' (lo de ultramar viene en
-- barco), 'Cargado' y 'Destruida'. No hay CHECK de status (la validación es
-- Pydantic, ver plan_cargas/schemas.py) → no hace falta DDL para eso.

ALTER TABLE ext.plan_de_cargas
    ADD COLUMN IF NOT EXISTS fuente VARCHAR(10) NOT NULL DEFAULT 'BR';

CREATE INDEX IF NOT EXISTS ix_plan_de_cargas_fuente ON ext.plan_de_cargas(fuente);
