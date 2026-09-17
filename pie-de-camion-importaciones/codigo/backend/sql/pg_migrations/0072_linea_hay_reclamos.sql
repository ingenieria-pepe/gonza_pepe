-- "¿Hay reclamos?" pasa a preguntarse POR PRODUCTO, no por camión.
-- Con un camión de varias frutas, una sola respuesta era ambigua: no se sabía si
-- "no hay reclamos" hablaba de la banana, del kiwi o de las dos.
-- ext.pie_de_camion.hay_reclamos (mig 0071) queda como el ROLL-UP del pie
-- (= true si alguna línea tiene reclamo), así que todo lo que ya lo consume
-- (informe, listado, reclamo post-hoc) sigue funcionando igual.
ALTER TABLE ext.pie_de_camion_linea
    ADD COLUMN IF NOT EXISTS hay_reclamos boolean;

-- Backfill de lo que ya está cargado:
--  · línea CON defectos            → true  (se reclamó, es un hecho)
--  · pie declarado "sin reclamos"  → false (el operario declaró que TODO vino bien)
--  · el resto                      → NULL  (pie viejo: no se sabe, y el informe
--                                           no declara nada para esas líneas)
UPDATE ext.pie_de_camion_linea l
   SET hay_reclamos = true
 WHERE l.hay_reclamos IS NULL
   AND EXISTS (SELECT 1 FROM ext.pie_de_camion_defecto d WHERE d.pie_camion_linea_id = l.id);

UPDATE ext.pie_de_camion_linea l
   SET hay_reclamos = false
  FROM ext.pie_de_camion p
 WHERE p.id = l.pie_camion_id
   AND l.hay_reclamos IS NULL
   AND p.hay_reclamos IS FALSE;
