-- Módulo PRODUCTOS Y PRECIOS (2/09/2026). Aloha pasa a editar el maestro de
-- artículos y las listas de precios de Macrosoft, que hasta hoy sólo leía.
--
-- Por qué hace falta tabla propia si Macrosoft ya tiene CambiosDePrecios:
--   1. Macrosoft guarda SÓLO el usuario (char 20) y la fecha (sin hora). Acá
--      queda quién de Aloha, con hora, y desde qué pantalla.
--   2. CambiosDePrecios es la auditoría del PRECIO. El maestro de artículos NO
--      tiene ninguna: Macrosoft pisa Articulos sin dejar rastro. Si alguien
--      renombra un producto —y con eso le cambia el ícono y la categoría en
--      toda la app— hoy no habría forma de saber quién fue.
--   3. El espejo es una VENTANA: legacy.cambiosdeprecios se refresca completo
--      cada 120 s y lo viejo puede desaparecer. Como ERP guardamos todo.
CREATE TABLE IF NOT EXISTS ext.producto_cambio (
    id            SERIAL PRIMARY KEY,
    cod_art       VARCHAR(20) NOT NULL,
    -- 'precio' = una lista de precios; 'articulo' = campos del maestro;
    -- 'alta' = artículo nuevo.
    tipo          VARCHAR(12) NOT NULL CHECK (tipo IN ('precio', 'articulo', 'alta')),
    -- Sólo para tipo='precio'.
    lista         SMALLINT NULL,
    moneda        INTEGER NULL,
    valor_anterior NUMERIC(12,4) NULL,
    valor_nuevo    NUMERIC(12,4) NULL,
    -- Para tipo='articulo': {campo: [antes, despues]}. Sólo lo que cambió.
    campos        JSONB NULL,
    usuario_id    INTEGER REFERENCES ext.usuarios(id),
    creado_en     TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- ¿La escritura llegó a Macrosoft o quedó sólo acá (gate apagado)?
    escribio_macrosoft BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS ix_producto_cambio_art  ON ext.producto_cambio (cod_art, creado_en DESC);
CREATE INDEX IF NOT EXISTS ix_producto_cambio_fecha ON ext.producto_cambio (creado_en DESC);

-- Idempotencia, mismo mecanismo que ext.escritura_stock_envio (mig 0113): el
-- cliente manda su `ref` y el reintento no crea un segundo CambiosDePrecios.
-- Sin esto, un timeout + un click de más deja DOS filas de historial con el
-- mismo precio y el `precio_anterior` de la segunda ya pisado — o sea, el
-- historial mintiendo sobre de cuánto fue el salto.
CREATE TABLE IF NOT EXISTS ext.producto_escritura_envio (
    ref         UUID PRIMARY KEY,
    tipo        VARCHAR(12) NOT NULL,
    cod_art     VARCHAR(20) NOT NULL,
    usuario_id  INTEGER REFERENCES ext.usuarios(id),
    cambio_id   INTEGER NULL REFERENCES ext.producto_cambio(id),
    creado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);
