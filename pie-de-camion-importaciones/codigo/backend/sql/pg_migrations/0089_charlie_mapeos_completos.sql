-- PG Migration 0089 - Mapeos Charlie -> CodArticulo para TODO lo que Charlie
-- cuenta hoy (17/08: sonda a camcontador2.Conteo — solo banana estaba mapeada).
--
-- Charlie separa Calibre (Palta 48/60, Pina 5-9, Ciruela 45-60) y canal
-- (Presentacion='Super') justo donde Macrosoft tiene ARTICULOS distintos. El
-- ingestor compone la etiqueta ("Palta Brasil 60", "Curcuma Super") y este
-- mapa sigue siendo etiqueta->articulo (regla mig 0074: nunca por similitud;
-- la descripcion es el snapshot del catalogo que respalda cada decision).
--
-- Codigos representativos alineados con ext.stock_dashboard_producto donde
-- existe la fila (mig 0083). Deliberadamente SIN mapear (quedan "sin match"
-- visibles hasta que un humano decida en el ABM de Configuracion):
--   'Melon Amarillo'  -> Macrosoft no tiene articulo "amarillo" (el dashboard
--                        tiene Melon Valenciano 940104: confirmar si es lo mismo)
--   'Kiwi Grande'     -> "Grande" no es un calibre Macrosoft (18-20? 23-27?)
--   'Palta Brasil' / 'Pina' sin calibre -> mejor visible que sumar calibres
--   'Mani Super'      -> no hay articulo de mani canal super en el catalogo

INSERT INTO ext.inventario_charlie_producto_map
    (charlie_producto, cod_art, descripcion_snapshot)
VALUES
    ('Arándano',        '890501', 'Arandanos Perú'),
    ('Choclo',           '030100', 'Choclo Importado x 2'),
    ('Coco',             '750101', 'Coco Brasil'),
    ('Cúrcuma',          '090904', 'Cúrcuma Brasil'),
    ('Cúrcuma Super',    '090905', 'Cúrcuma Br  5k  (Súper)'),
    ('Jengibre',         '090901', 'Jengibre Brasil'),
    ('Jengibre Super',   '090902', 'Jengibre (Super)'),
    ('Kiwi',             '0802231', 'Kiwi Chile Calibre 23 al 27 Cat 1'),
    ('Lima',             '150101', 'Lima Brasil'),
    ('Mango',            '900103', 'Mango Tomy Brasil'),
    ('Maní',             '970101', 'Maní tostado'),
    ('Papaya Formosa',   '250101', 'Papaya Formosa Brasil'),
    ('Plátano',          '760704', 'Platano Ecuador 22 Kilos'),
    ('Uva Blanca',       '270101', 'Uva Blanca s/s Brasil x 8kg'),
    ('Uva Negra',        '270102', 'Uva Negra s/s Brasil x 8 kg'),
    ('Uva Rosada',       '270103', 'Uva Rosada s/s  Brasil x 8 kg'),
    -- Ciruela: Macrosoft NO separa calibre -> todos los calibres de Charlie
    -- convergen al mismo articulo (igual que Ecuador Pepe/Bagno en la 0074).
    ('Ciruela',          '961401', 'Ciruela España'),
    ('Ciruela 45',       '961401', 'Ciruela España'),
    ('Ciruela 50',       '961401', 'Ciruela España'),
    ('Ciruela 55',       '961401', 'Ciruela España'),
    ('Ciruela 60',       '961401', 'Ciruela España'),
    -- Palta y Pina: calibre Charlie -> articulo por calibre.
    ('Palta Brasil 48',  '600107', 'Palta Brasil Cal. 48 X 10 Kg'),
    ('Palta Brasil 50',  '600106', 'Palta Brasil Cal. 50 X 14 Kg'),
    ('Palta Brasil 60',  '600101', 'Palta Brasil Cal. 60'),
    ('Palta Brasil 70',  '600103', 'Palta Brasil Cal. 70'),
    ('Palta Brasil 84',  '600104', 'Palta Brasil Cal. 84'),
    ('Piña 5',           '120705', 'Piña Ecuador Calibre 5'),
    ('Piña 6',           '120706', 'Piña Ecuador Calibre 6'),
    ('Piña 7',           '120707', 'Piña Ecuador  Calibre 7'),
    ('Piña 8',           '120708', 'Piña Ecuador Calibre 8'),
    ('Piña 9',           '120709', 'Piña Ecuador Calibre 9')
ON CONFLICT (charlie_producto) DO NOTHING;
