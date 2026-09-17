-- PG Migration 0074 - Mapeo fijo de productos Charlie a CodArticulo Macrosoft.
--
-- Charlie identifica la banana con etiquetas propias ("Ecuador Pepe",
-- "Paraguay Primera", etc.). Inventarios ciclicos persiste CodArticulo, por lo
-- que la comparacion debe resolver esas etiquetas mediante datos explicitos y
-- nunca por similitud de texto.
--
-- Varias etiquetas Charlie pueden converger al mismo CodArticulo. Esto es
-- intencional: Macrosoft no tiene articulos diferentes para Ecuador Pepe/Bagno
-- ni para el Paraguay generico. La comparacion debe sumar primero el snapshot
-- Charlie agrupado por cod_art y luego contrastarlo con el conteo Aloha.
--
-- No hay FK a legacy.articulos: legacy.* es un espejo read-only que se refresca
-- desde Macrosoft. descripcion_snapshot conserva evidencia del catalogo usado
-- al definir el match.

CREATE TABLE IF NOT EXISTS ext.inventario_charlie_producto_map (
    charlie_producto VARCHAR(80) PRIMARY KEY,
    cod_art VARCHAR(30) NOT NULL,
    descripcion_snapshot VARCHAR(200) NOT NULL,
    activo BOOLEAN NOT NULL DEFAULT true,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_por_usuario_id INT NULL,

    CONSTRAINT ck_inventario_charlie_producto_no_vacio
        CHECK (BTRIM(charlie_producto) <> ''),
    CONSTRAINT ck_inventario_charlie_cod_art_no_vacio
        CHECK (BTRIM(cod_art) <> ''),
    CONSTRAINT fk_inventario_charlie_actualizado_por
        FOREIGN KEY (actualizado_por_usuario_id) REFERENCES ext.usuarios(id)
);

-- No es UNIQUE: varios nombres externos pueden representar el mismo articulo.
CREATE INDEX IF NOT EXISTS ix_inventario_charlie_producto_cod_art
    ON ext.inventario_charlie_producto_map (cod_art)
    WHERE activo;

INSERT INTO ext.inventario_charlie_producto_map
    (charlie_producto, cod_art, descripcion_snapshot)
VALUES
    ('Brasil',            '010101', 'Banana Brasil (super)'),
    -- Codigo inactivo en el catalogo actual, necesario para historico/Charlie.
    ('Brasil OK',         '010103', 'Banana Brasil Ok'),
    ('Brasil Fibra',      '010102', 'Banana Brasil Fibra'),
    ('Ecuador',           '010701', 'Banana Ecuador (Super)'),
    ('Ecuador Bonita',    '010702', 'Banana Ecuador Bonita'),
    -- Macrosoft no distingue Pepe/Bagno con un CodArticulo propio.
    ('Ecuador Pepe',      '010701', 'Banana Ecuador (Super)'),
    ('Ecuador Bagno',     '010701', 'Banana Ecuador (Super)'),
    -- El nombre generico converge a Primera; Segunda conserva codigo propio.
    ('Paraguay',          '010401', 'Banana Paraguay Primera'),
    ('Paraguay Primera',  '010401', 'Banana Paraguay Primera'),
    ('Paraguay Segunda',  '010402', 'Banana Paraguay Segunda'),
    -- Charlie no separa Tuly/Suprema/DFC: todas pertenecen al codigo base.
    ('Bolivia',           '010703', 'Banana Bolivia Tuly')
ON CONFLICT (charlie_producto) DO NOTHING;
