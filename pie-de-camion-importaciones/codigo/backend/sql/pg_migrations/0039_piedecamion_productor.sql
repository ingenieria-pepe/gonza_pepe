-- PG Migration 0039 — Productor en el Pie de Camión.
--
-- El "Productor" (columna Productor del Plan de Cargas del Excel: Fischer, Corupá,
-- Paraguay MS, etc.) ahora es un CAMPO PROPIO del pie. Antes se metía escondido como
-- la marca por defecto de las líneas de mercadería; ahora tiene su lugar: se
-- pre-carga del Plan al elegir la carga, sale en el informe PDF y en la etiqueta Zebra.

ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS productor VARCHAR(200) NULL;
