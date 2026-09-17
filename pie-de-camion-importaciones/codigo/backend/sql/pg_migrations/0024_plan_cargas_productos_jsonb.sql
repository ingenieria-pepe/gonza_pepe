-- PG Migration 0024 — Plan de Cargas: productos pasa de UNO a VARIOS.
--
-- Antes: productos VARCHAR(200) + productos_icono VARCHAR(60) (un solo producto).
-- Ahora: productos JSONB = lista de {descripcion, icono} (un camión puede traer
-- varios). Migramos el único producto existente a un array de un elemento.
-- Todo en una transacción (el runner envuelve el archivo) → atómico.

ALTER TABLE ext.plan_de_cargas ADD COLUMN IF NOT EXISTS productos_jsonb jsonb NOT NULL DEFAULT '[]'::jsonb;

UPDATE ext.plan_de_cargas
SET productos_jsonb = jsonb_build_array(
        jsonb_build_object('descripcion', btrim(productos), 'icono', productos_icono)
    )
WHERE productos IS NOT NULL AND btrim(productos) <> '';

ALTER TABLE ext.plan_de_cargas DROP COLUMN productos;
ALTER TABLE ext.plan_de_cargas DROP COLUMN productos_icono;
ALTER TABLE ext.plan_de_cargas RENAME COLUMN productos_jsonb TO productos;
