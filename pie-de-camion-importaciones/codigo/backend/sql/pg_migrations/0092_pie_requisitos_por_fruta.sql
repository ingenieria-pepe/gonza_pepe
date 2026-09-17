-- 0092 · Requisitos por fruta en Pie de Camión (18-19/08/2026)
--
-- El pie de camión nació enfocado en banana (temp pulpa, corona, quemada…),
-- pero entran exóticos con controles propios. El ING. AGRÓNOMO define por
-- CATEGORÍA de fruta (app/core/categorias.py: "Kiwi", "Palta"…) qué se pide
-- al ingreso: dato numérico / texto libre / elegir opción / foto requerida.
-- El operario responde eso en el form del pie, por cada producto del camión.
--
-- Las respuestas SNAPSHOTEAN la etiqueta y el tipo: si el agrónomo después
-- cambia la config, los pies históricos siguen contando lo que se preguntó
-- ese día (mismo criterio que producto_legacy_snapshot en inventarios).

CREATE TABLE IF NOT EXISTS ext.pie_requisito (
    id BIGSERIAL PRIMARY KEY,
    -- Categoría canónica de app/core/categorias.py ("Banana", "Kiwi", …).
    categoria VARCHAR(40) NOT NULL,
    tipo VARCHAR(10) NOT NULL CHECK (tipo IN ('numero', 'texto', 'opciones', 'foto')),
    etiqueta VARCHAR(200) NOT NULL,
    -- Para tipo=numero: unidad que se muestra al lado ("°Brix", "kg", "mm").
    unidad VARCHAR(20),
    -- Para tipo=opciones: lista JSON de strings (["Verde", "Pintón", "Maduro"]).
    opciones JSONB,
    obligatorio BOOLEAN NOT NULL DEFAULT true,
    orden INT NOT NULL DEFAULT 0,
    activo BOOLEAN NOT NULL DEFAULT true,
    creado_por_usuario_id BIGINT REFERENCES ext.usuarios(id),
    creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_pie_requisito_categoria
    ON ext.pie_requisito (categoria, activo, orden);

CREATE TABLE IF NOT EXISTS ext.pie_requisito_respuesta (
    id BIGSERIAL PRIMARY KEY,
    pie_camion_id BIGINT NOT NULL REFERENCES ext.pie_de_camion(id) ON DELETE CASCADE,
    -- Referencia informativa (la config puede desactivarse/cambiar después).
    requisito_id BIGINT REFERENCES ext.pie_requisito(id),
    -- A qué producto del camión corresponde ("Kiwi Gold") y su categoría.
    producto VARCHAR(100) NOT NULL,
    categoria VARCHAR(40) NOT NULL,
    -- SNAPSHOT de lo que se preguntó.
    tipo VARCHAR(10) NOT NULL,
    etiqueta VARCHAR(200) NOT NULL,
    unidad VARCHAR(20),
    valor_numero DOUBLE PRECISION,
    valor_texto VARCHAR(1000),
    -- Para tipo=foto: cuántas fotos se adjuntaron (viven en el fotos-PDF).
    fotos_n INT NOT NULL DEFAULT 0,
    orden INT NOT NULL DEFAULT 0,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_pie_requisito_respuesta_pie
    ON ext.pie_requisito_respuesta (pie_camion_id, orden);
