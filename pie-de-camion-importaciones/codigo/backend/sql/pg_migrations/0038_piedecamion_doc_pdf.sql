-- PG Migration 0038 — PDF de DOCUMENTACIÓN escaneada del Pie de Camión.
--
-- El operario, al final del pie, escanea unos papeles A4 (con el celu, recorte
-- automático). Se arma un PDF APARTE de la planilla y se sube junto al pie; en
-- Ingresos se pueden bajar los dos. Mismo patrón que el PDF de la planilla
-- (pdf_blob + pdf_s3_key) pero en columnas propias y NULLABLE (no todo pie trae
-- documentación).

ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS doc_pdf_filename   VARCHAR(200) NULL;
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS doc_pdf_blob       BYTEA        NULL;
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS doc_pdf_size_bytes INT          NULL;
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS doc_pdf_s3_key     VARCHAR      NULL;
