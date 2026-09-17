-- El confirmar de un pie escribe en DOS bases sin transacción común: primero
-- Macrosoft (el documento 402/181), después Postgres (el estado del pie). Entre
-- una y otra hay una ventana, y ahí caben dos accidentes que meten el MISMO
-- camión dos veces en el stock:
--
--   1. Dos clicks / dos pestañas / un reintento del navegador: los dos pasan la
--      validación de estado='pendiente' y los DOS escriben en Macrosoft.
--   2. Macrosoft commitea y Postgres falla: el documento ya existe pero el pie
--      vuelve a quedar 'pendiente' y el botón se re-habilita.
--
-- La reserva cierra las dos. Se marca ACÁ antes de tocar Macrosoft: reservado
-- sin ingresar es visible y no rompe nada; ingresado sin marcar, sí. Es el mismo
-- patrón que ya usan el ajuste de viajes y el envío de pedidos del tomador.
ALTER TABLE ext.pie_de_camion
    -- Cuándo alguien empezó a confirmarlo. NULL = nadie lo está confirmando.
    -- Con esto puesto y estado='pendiente', el pie quedó a mitad de camino:
    -- hay que mirar en Macrosoft si el documento se creó antes de reintentar.
    ADD COLUMN IF NOT EXISTS confirmando_en TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS confirmando_por_usuario_id INTEGER REFERENCES ext.usuarios(id);

