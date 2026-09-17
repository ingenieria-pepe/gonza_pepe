-- Migration 0016 — Mejoras al Pie de Camión:
-- - Soportar múltiples productos+marca por camión (tabla nueva)
-- - Campo "código importador-camión" (FH-044, etc.) — eventualmente leerá un barcode
-- - Unidad de medición de longitud (cm o pulgadas)

USE AlmarExtensiones;
GO

-- Campos nuevos en PieDeCamion
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PieDeCamion')
      AND name = 'codigo_importador_camion'
)
BEGIN
    ALTER TABLE dbo.PieDeCamion ADD codigo_importador_camion NVARCHAR(30) NULL;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PieDeCamion')
      AND name = 'longitud_unidad'
)
BEGIN
    -- 'cm' o 'pulgadas'. Default 'cm' (lo usual).
    ALTER TABLE dbo.PieDeCamion ADD longitud_unidad NVARCHAR(10) NOT NULL DEFAULT 'cm';
END;
GO

-- Tabla de productos+marca asociados a cada pie de camión
-- (los campos producto/marca en PieDeCamion quedan deprecated; los conservamos
-- para no romper data vieja, pero el front nuevo escribe en esta tabla).
IF OBJECT_ID('dbo.PieDeCamionProducto', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PieDeCamionProducto (
        id INT IDENTITY(1,1) PRIMARY KEY,
        pie_camion_id INT NOT NULL,
        producto NVARCHAR(100) NOT NULL,
        marca NVARCHAR(100) NULL,
        orden INT NOT NULL DEFAULT 0,
        CONSTRAINT FK_PieDeCamionProducto_PieDeCamion
            FOREIGN KEY (pie_camion_id) REFERENCES dbo.PieDeCamion(id) ON DELETE CASCADE
    );
    CREATE INDEX IX_PieDeCamionProducto_pie ON dbo.PieDeCamionProducto(pie_camion_id);
END;
GO
