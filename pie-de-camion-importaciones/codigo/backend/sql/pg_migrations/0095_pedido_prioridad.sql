-- Pedidos PRIORITARIOS (24/08): el vendedor marca un pedido que tiene que
-- salir YA. La marca viaja por toda la cadena: asignación (arriba de todo,
-- con glow), armador (aviso en el celu) y la tele de entregas (alarma).
-- Molde de 0006_pedido_conflicto: PK (documento, nro_fact) contra el espejo.
CREATE TABLE IF NOT EXISTS ext.pedido_prioridad (
    documento      CHAR(4)   NOT NULL DEFAULT '30  ',
    nro_fact       INT       NOT NULL,
    activo         BOOLEAN   NOT NULL DEFAULT TRUE,
    marcado_por    INT       NULL REFERENCES ext.usuarios(id),
    marcado_en     TIMESTAMP NOT NULL DEFAULT now(),
    desmarcado_por INT       NULL REFERENCES ext.usuarios(id),
    desmarcado_en  TIMESTAMP NULL,
    PRIMARY KEY (documento, nro_fact)
);
