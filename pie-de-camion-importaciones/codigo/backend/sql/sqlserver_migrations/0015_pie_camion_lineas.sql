-- Migration 0015 — Re-arquitectura: PieDeCamion ahora carga los ítems +
-- defectos. Ingresos pasa a ser el step de "confirmar" un pie de camión
-- pendiente para crear el movimiento real en Macrosoft (Cabezal/Lineas).

USE AlmarExtensiones;
GO

-- Estado + tracking de confirmación en PieDeCamion
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PieDeCamion') AND name = 'estado')
BEGIN
    ALTER TABLE dbo.PieDeCamion ADD
        estado NVARCHAR(20) NOT NULL DEFAULT 'pendiente',
        ingreso_documento NVARCHAR(10) NULL,
        ingreso_nro_fact INT NULL,
        confirmado_por_usuario_id INT NULL,
        confirmado_en DATETIME2 NULL,
        reclamo_id INT NULL;
END;
GO

-- FKs (en bloque aparte porque no se pueden agregar en el mismo ALTER)
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_PieDeCamion_Confirmado')
BEGIN
    ALTER TABLE dbo.PieDeCamion ADD CONSTRAINT FK_PieDeCamion_Confirmado
        FOREIGN KEY (confirmado_por_usuario_id) REFERENCES dbo.Usuarios(id);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_PieDeCamion_Reclamo')
BEGIN
    ALTER TABLE dbo.PieDeCamion ADD CONSTRAINT FK_PieDeCamion_Reclamo
        FOREIGN KEY (reclamo_id) REFERENCES dbo.Reclamo(id);
END;
GO

-- Líneas (productos recibidos)
IF OBJECT_ID('dbo.PieDeCamionLinea', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PieDeCamionLinea (
        id INT IDENTITY(1,1) PRIMARY KEY,
        pie_camion_id INT NOT NULL,
        cod_art NVARCHAR(30) NOT NULL,
        descripcion NVARCHAR(200) NOT NULL,
        deposito NVARCHAR(4) NOT NULL,
        cantidad DECIMAL(10,3) NOT NULL,
        orden INT NOT NULL DEFAULT 0,
        CONSTRAINT FK_PieDeCamionLinea_PieDeCamion
            FOREIGN KEY (pie_camion_id) REFERENCES dbo.PieDeCamion(id) ON DELETE CASCADE
    );
    CREATE INDEX IX_PieDeCamionLinea_pie ON dbo.PieDeCamionLinea(pie_camion_id);
END;
GO

-- Defectos por línea
IF OBJECT_ID('dbo.PieDeCamionDefecto', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PieDeCamionDefecto (
        id INT IDENTITY(1,1) PRIMARY KEY,
        pie_camion_linea_id INT NOT NULL,
        motivo_id INT NOT NULL,
        cantidad DECIMAL(10,3) NOT NULL,
        notas NVARCHAR(500) NULL,
        cantidad_fotos INT NOT NULL DEFAULT 0,
        CONSTRAINT FK_PieDeCamionDefecto_Linea
            FOREIGN KEY (pie_camion_linea_id) REFERENCES dbo.PieDeCamionLinea(id) ON DELETE CASCADE,
        CONSTRAINT FK_PieDeCamionDefecto_Motivo
            FOREIGN KEY (motivo_id) REFERENCES dbo.DefectoMotivo(id)
    );
END;
GO

-- Reclamo: ahora puede venir asociado a un PieDeCamion (sin ingreso aún)
-- o a un Ingreso directo (legacy). Documento/NroFact pasan a nullable.
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Reclamo') AND name = 'pie_camion_id')
BEGIN
    ALTER TABLE dbo.Reclamo ADD pie_camion_id INT NULL;
END;
GO

-- Alterar NULL en columnas existentes (idempotente)
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.Reclamo')
             AND name = 'documento' AND is_nullable = 0)
BEGIN
    ALTER TABLE dbo.Reclamo ALTER COLUMN documento NVARCHAR(10) NULL;
END;
GO

IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.Reclamo')
             AND name = 'nro_fact' AND is_nullable = 0)
BEGIN
    ALTER TABLE dbo.Reclamo ALTER COLUMN nro_fact INT NULL;
END;
GO
