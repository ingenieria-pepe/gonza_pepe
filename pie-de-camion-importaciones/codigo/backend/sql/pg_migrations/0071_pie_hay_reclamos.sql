-- Pie de camión: la pregunta OBLIGATORIA "¿Hay reclamos para esta fruta?"
-- (pedido del dueño 05/08/2026).
--
-- Antes, un pie sin defectos era ambiguo: no se sabía si la fruta vino bien o
-- si al operario se le pasó revisarla. Ahora la respuesta queda registrada.
--
-- NULLABLE a propósito: los pies históricos quedan en NULL = "no se preguntó".
-- Poner NOT NULL rompería los cientos ya cargados y mentiría sobre ellos.
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS hay_reclamos boolean;

-- Backfill de lo que SÍ se puede afirmar: si el pie generó un reclamo, hubo
-- reclamos. Al revés no vale (sin reclamo no implica que lo hayan revisado).
UPDATE ext.pie_de_camion SET hay_reclamos = true
WHERE hay_reclamos IS NULL AND reclamo_id IS NOT NULL;
