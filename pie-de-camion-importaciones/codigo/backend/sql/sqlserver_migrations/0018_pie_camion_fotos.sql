-- Migration 0018 — Pie de Camión: fotos del camión + marca por línea.
--
-- (1) Tabla PieDeCamionFoto:
--   Hasta ~15 fotos por camión (panorámicas del estado de la fruta,
--   palets, sellos, etc). Se comprimen en el cliente antes de subir
--   (max 1280px JPEG 75%) → BLOB en DB → embed en el PDF.
--
-- (2) marca por línea (PieDeCamionLinea):
--   Antes había un "Productos / Marcas" arriba (header) DISTINTO de la
--   mercadería abajo. El operario tenía que tipear lo mismo dos veces.
--   Ahora la marca vive en la propia línea de mercadería, junto al
--   cod_art y la cantidad. El front nuevo no escribe más en la tabla
--   PieDeCamionProducto (deprecated; queda por compat con data vieja).

USE AlmarExtensiones;
GO

-- ── (2) marca en PieDeCamionLinea ──────────────────────────────────────
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PieDeCamionLinea')
      AND name = 'marca'
)
BEGIN
    ALTER TABLE dbo.PieDeCamionLinea ADD marca NVARCHAR(100) NULL;
END;
GO

IF OBJECT_ID('dbo.PieDeCamionFoto', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PieDeCamionFoto (
        id INT IDENTITY(1,1) PRIMARY KEY,
        pie_camion_id INT NOT NULL,
        foto_blob VARBINARY(MAX) NOT NULL,
        mime_type NVARCHAR(50) NOT NULL DEFAULT 'image/jpeg',
        size_bytes INT NOT NULL,
        orden INT NOT NULL DEFAULT 0,
        caption NVARCHAR(200) NULL,
        creado_en DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
        CONSTRAINT FK_PieDeCamionFoto_PieDeCamion
            FOREIGN KEY (pie_camion_id) REFERENCES dbo.PieDeCamion(id) ON DELETE CASCADE
    );
    CREATE INDEX IX_PieDeCamionFoto_pie_camion ON dbo.PieDeCamionFoto(pie_camion_id);
END;
GO
