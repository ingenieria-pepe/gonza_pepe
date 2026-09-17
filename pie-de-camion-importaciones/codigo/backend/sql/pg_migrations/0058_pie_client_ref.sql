-- PG Migration 0058 — Idempotencia del POST /pie-camion.
-- El celu manda el pie en UN POST gigante (fotos base64). Si el cliente aborta
-- por timeout / el wifi muere DESPUÉS de que el server recibió el body, el pie
-- queda guardado pero el celu cree que falló → "Reintentar" creaba un DUPLICADO
-- (review 22/07). El front ahora genera un client_ref (UUID) que vive en el
-- borrador: si llega dos veces, el create devuelve el pie existente.

ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS client_ref VARCHAR(64) NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pie_de_camion_client_ref
    ON ext.pie_de_camion (client_ref)
    WHERE client_ref IS NOT NULL;
