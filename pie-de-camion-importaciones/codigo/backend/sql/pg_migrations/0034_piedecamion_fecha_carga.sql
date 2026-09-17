-- PG Migration 0034 — Fecha de carga en Pie de camión.
--
-- El pie de camión ya tenía `fecha` (= fecha de DESCARGA / recepción). Ahora
-- guardamos también la fecha en que se CARGÓ el camión en origen. Nullable
-- (registros viejos quedan sin ella → el PDF muestra "—").

ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS fecha_carga DATE NULL;
