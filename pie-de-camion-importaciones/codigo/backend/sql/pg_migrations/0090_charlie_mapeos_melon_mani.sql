-- PG Migration 0090 - Dos mapeos Charlie que la 0089 dejo sin resolver a
-- proposito (mejor "sin match" visible que un mapeo adivinado). Resueltos por
-- el dueno el 17/08:
--   'Melon Amarillo' de Charlie ES el Melon Valenciano  -> 940104
--   'Mani Super' es el mani de 500 gramos               -> 970102
-- Siguen sin mapear (decision pendiente): 'Kiwi Grande', 'Palta Brasil' y
-- 'Pina' sin calibre.

INSERT INTO ext.inventario_charlie_producto_map
    (charlie_producto, cod_art, descripcion_snapshot)
VALUES
    ('Melón Amarillo', '940104', 'Melon Valenciano Brasil'),
    ('Maní Super',     '970102', 'Maní tostado Malla 500G.')
ON CONFLICT (charlie_producto) DO NOTHING;
