-- Fotos del pie de camión organizadas por categoría (temperatura container,
-- ticket peaje, puerta/matrícula, temperaturas pulpa adelante/medio/atrás,
-- estado del pallet, balanza, estado de la fruta por posición, etc.).
-- `categoria` = slug estable (fuente de verdad en el front); `caption` (ya existía)
-- = etiqueta humana para el título en el informe PDF. NULL = foto sin categoría
-- (galería libre "Otras fotos" / registros viejos).
ALTER TABLE ext.pie_de_camion_foto
    ADD COLUMN IF NOT EXISTS categoria VARCHAR(40) NULL;
