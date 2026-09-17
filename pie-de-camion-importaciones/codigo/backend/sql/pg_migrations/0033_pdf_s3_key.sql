-- PG Migration 0033 — PDFs en S3 (en vez de blob en Postgres).
--
-- Los PDF de pie de camión y de reclamos se guardaban como blob en la DB
-- (pdf_blob) — con las fotos embebidas, inflan Postgres. Ahora se suben a S3 y
-- guardamos sólo la KEY. Aditivo + compatible: si pdf_s3_key está seteada se
-- sirve desde S3; si es NULL, se sirve el blob (fallback / registros viejos hasta
-- el backfill). No se borra pdf_blob todavía (se libera al subir a S3 / backfill).

ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS pdf_s3_key VARCHAR NULL;
ALTER TABLE ext.reclamo        ADD COLUMN IF NOT EXISTS pdf_s3_key VARCHAR NULL;
