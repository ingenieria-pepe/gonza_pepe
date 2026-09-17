-- PG Migration 0036 — Marca "descargado/revisado" en el Pie de camión.
--
-- En Ingresos → Pendientes, el que registra baja el PDF del pie (botón "Planilla")
-- para revisarlo antes de confirmar. Marcamos `descargado_en` al bajarlo, así ven
-- cuáles ya revisaron y no los repiten. Compartido (los celus son un pool común).

ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS descargado_en TIMESTAMP NULL;
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS descargado_por_usuario_id INT NULL
    REFERENCES ext.usuarios(id);
