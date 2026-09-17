-- Arreglo del offload a S3 + fotos a S3.
--
-- BUG: s3.offload_pdf sube el PDF a S3 y hace `SET <blob> = NULL` para liberar
-- el blob de Postgres. Pero `pie_de_camion.pdf_blob` y `reclamo.pdf_blob` eran
-- NOT NULL → ese UPDATE explotaba (NotNullViolation) y el error se tragaba
-- (except: pass). Resultado: el archivo subía a S3 PERO el blob nunca se liberaba
-- y el s3_key quedaba sin marcar → PDF duplicado (S3 + blob en la DB, ~112 MB de
-- informes + ~7 MB de reclamos al pedo). doc_pdf_blob / termografo_pdf_blob ya
-- eran nullable, por eso ESOS sí habían migrado bien.
-- Al hacerlas nullable, el offload (y el backfill) liberan el blob.
ALTER TABLE ext.pie_de_camion ALTER COLUMN pdf_blob DROP NOT NULL;
ALTER TABLE ext.reclamo         ALTER COLUMN pdf_blob DROP NOT NULL;

-- Fotos del pie de camión a S3: nunca se habían conectado (la tabla no tenía
-- columna s3_key y el blob era NOT NULL → imposible de offloadear). ~88 MB.
ALTER TABLE ext.pie_de_camion_foto ADD COLUMN IF NOT EXISTS foto_s3_key VARCHAR(300);
ALTER TABLE ext.pie_de_camion_foto ALTER COLUMN foto_blob DROP NOT NULL;
