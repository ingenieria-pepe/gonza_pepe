-- PG Migration 0042 — PDF del termógrafo (cadena de frío) en el Pie de Camión.
--
-- Los camiones traen un termógrafo USB (Sensitech TempTale) con un PDF del registro
-- de temperatura del viaje. Desde el Historial, en una compu, se enchufa el USB y se
-- adjunta ese PDF al pie. Se GUARDA APARTE (no se toca la planilla base); al DESCARGAR
-- el informe se fusiona planilla + termógrafo en un solo PDF (ver router). Re-subir
-- reemplaza el blob → nunca duplica. Mismo patrón que doc_pdf_* (offload a S3).

ALTER TABLE ext.pie_de_camion
  ADD COLUMN IF NOT EXISTS termografo_pdf_filename   VARCHAR(200) NULL,
  ADD COLUMN IF NOT EXISTS termografo_pdf_blob       BYTEA        NULL,
  ADD COLUMN IF NOT EXISTS termografo_pdf_size_bytes INT          NULL,
  ADD COLUMN IF NOT EXISTS termografo_pdf_s3_key     VARCHAR(300) NULL;
