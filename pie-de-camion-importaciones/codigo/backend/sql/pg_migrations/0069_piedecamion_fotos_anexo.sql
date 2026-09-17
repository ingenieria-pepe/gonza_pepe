-- Agregar fotos a un pie de camión YA ENVIADO (pedido del 04/08/2026).
--
-- Las fotos viven en un PDF aparte (mig 0056) que se fusiona al descargar, así
-- que "agregar" = anexarle páginas a ese PDF. No se pueden borrar ni reordenar
-- las anteriores: ya no existen como imágenes sueltas, solo dentro del PDF.
--
-- Estas columnas son la auditoría del anexo (cuántas veces, la última cuándo y
-- de quién). El detalle por tanda queda escrito en el propio PDF, en el título
-- que separa cada anexo.
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS fotos_anexos_n  INT NOT NULL DEFAULT 0;
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS fotos_anexo_en  TIMESTAMPTZ NULL;
ALTER TABLE ext.pie_de_camion ADD COLUMN IF NOT EXISTS fotos_anexo_por INT NULL;
