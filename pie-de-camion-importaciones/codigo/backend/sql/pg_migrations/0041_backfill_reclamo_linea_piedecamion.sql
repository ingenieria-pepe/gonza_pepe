-- PG Migration 0041 — Backfill de líneas de reclamo para reclamos de Pie de Camión.
--
-- El flujo de Pie de Camión creaba el ext.reclamo (header + PDF) pero NUNCA
-- insertaba las ext.reclamo_linea (a diferencia del módulo de stock). Por eso el
-- Dashboard (que suma reclamo_linea.cantidad_defectuosa) mostraba "0 cajas / —"
-- para esos reclamos. El fix del código ya inserta las líneas de acá en adelante;
-- esta migración reconstruye las de los reclamos VIEJOS a partir de los defectos
-- que sí quedaron guardados en ext.pie_de_camion_defecto (+ la línea del pie para
-- el cod_art/descripción). Idempotente: sólo reclamos de pie SIN líneas.

INSERT INTO ext.reclamo_linea
    (reclamo_id, cod_art, descripcion, cantidad_defectuosa, motivo_id, notas, cantidad_fotos)
SELECT r.id,
       BTRIM(l.cod_art),
       BTRIM(l.descripcion),
       df.cantidad,
       df.motivo_id,
       df.notas,
       COALESCE(df.cantidad_fotos, 0)
FROM ext.reclamo r
JOIN ext.pie_de_camion_linea l    ON l.pie_camion_id = r.pie_camion_id
JOIN ext.pie_de_camion_defecto df ON df.pie_camion_linea_id = l.id
WHERE r.pie_camion_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ext.reclamo_linea rl WHERE rl.reclamo_id = r.id);
