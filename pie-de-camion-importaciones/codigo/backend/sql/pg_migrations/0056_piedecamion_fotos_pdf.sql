-- Modelo PARTIDO para el informe del pie de camión (igual que el reclamo):
-- el informe pasa a ser datos-PDF (sin fotos) + un fotos-PDF aparte que se
-- fusiona al descargar. Así dejamos de guardar las fotos DOS veces (individuales
-- + embebidas en el informe) y editar puede reemplazar las fotos sin perderlas.
-- Mismas columnas que ext.reclamo (mig 0047); sin filename (va fusionado, no se
-- sirve suelto).
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS fotos_pdf_blob       BYTEA   NULL;
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS fotos_pdf_size_bytes INT     NULL;
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS fotos_pdf_s3_key     VARCHAR NULL;
