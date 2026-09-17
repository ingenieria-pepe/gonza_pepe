-- PG Migration 0022 — Plan de Cargas: producto (con ícono) + país de origen.
--
-- 'productos'        = qué lleva la carga (Banana, Palta…). Se elige con el
--                      picker de categorías (SVG, como Pie de Camión); el import
--                      del master del Drive lo carga como texto libre.
-- 'productos_icono'  = nombre del SVG de /categorias/<icono>.svg (lo setea el
--                      picker; el import lo deja NULL → la fila muestra el texto).
-- 'pais_origen'      = país de origen de la carga (Brasil, Paraguay…).
ALTER TABLE ext.plan_de_cargas ADD COLUMN IF NOT EXISTS productos VARCHAR(200) NULL;
ALTER TABLE ext.plan_de_cargas ADD COLUMN IF NOT EXISTS productos_icono VARCHAR(60) NULL;
ALTER TABLE ext.plan_de_cargas ADD COLUMN IF NOT EXISTS pais_origen VARCHAR(60) NULL;
