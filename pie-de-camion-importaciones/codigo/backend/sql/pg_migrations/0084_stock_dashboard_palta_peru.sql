-- PG Migration 0084 - Incluir paltas peruanas en las filas por calibre.
--
-- El dashboard define Palta 70 y Palta 84 por calibre, no por origen. Los
-- CodStock peruanos 1.1.2.64 y 1.1.2.65 quedaban sin clasificar y por lo tanto
-- no aparecian en el saldo oficial agrupado.

INSERT INTO ext.stock_dashboard_producto_regla
    (producto_clave, tipo, valor, prioridad)
VALUES
    ('palta_70', 'cod_stock', '1.1.2.64', 20),
    ('palta_84', 'cod_stock', '1.1.2.65', 20)
ON CONFLICT (producto_clave, tipo, valor) DO UPDATE SET
    prioridad = EXCLUDED.prioridad;
