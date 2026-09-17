-- Migration 0014 — Pie de Camión.
-- Reemplazo digital de la planilla "Control De Mercadería A Pie Camión" que
-- hoy se llena a mano y se encarpeta. El PDF generado se guarda en pdf_blob
-- para reemplazar el papel.

USE AlmarExtensiones;
GO

IF OBJECT_ID('dbo.PieDeCamion', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PieDeCamion (
        id INT IDENTITY(1,1) PRIMARY KEY,
        fecha DATE NOT NULL,
        hora_inicio NVARCHAR(5) NULL,        -- "HH:MM"
        hora_fin NVARCHAR(5) NULL,

        chofer_nombre NVARCHAR(100) NOT NULL,
        placa_camion NVARCHAR(20) NOT NULL,

        producto NVARCHAR(100) NULL,
        marca NVARCHAR(100) NULL,

        exportador NVARCHAR(150) NULL,
        empresa_transporte NVARCHAR(150) NULL,
        numero_afidi NVARCHAR(50) NULL,

        intervenido_agronomia BIT NOT NULL DEFAULT 0,
        inspector_agronomo NVARCHAR(100) NULL,

        -- Condiciones generales (1-5 + comentario)
        palet_rating TINYINT NULL,
        palet_comentario NVARCHAR(200) NULL,
        cajas_rating TINYINT NULL,
        cajas_comentario NVARCHAR(200) NULL,
        flejes_rating TINYINT NULL,
        flejes_comentario NVARCHAR(200) NULL,

        -- Mediciones (Puerta / Medio / Atrás, 2 valores cada uno para temp y peso)
        temp_pulpa_puerta_1 DECIMAL(5,2) NULL,
        temp_pulpa_puerta_2 DECIMAL(5,2) NULL,
        temp_pulpa_medio_1 DECIMAL(5,2) NULL,
        temp_pulpa_medio_2 DECIMAL(5,2) NULL,
        temp_pulpa_atras_1 DECIMAL(5,2) NULL,
        temp_pulpa_atras_2 DECIMAL(5,2) NULL,

        peso_caja_puerta_1 DECIMAL(5,2) NULL,
        peso_caja_puerta_2 DECIMAL(5,2) NULL,
        peso_caja_medio_1 DECIMAL(5,2) NULL,
        peso_caja_medio_2 DECIMAL(5,2) NULL,
        peso_caja_atras_1 DECIMAL(5,2) NULL,
        peso_caja_atras_2 DECIMAL(5,2) NULL,

        calibracion_puerta INT NULL,
        calibracion_medio INT NULL,
        calibracion_atras INT NULL,

        longitud_puerta DECIMAL(5,2) NULL,
        longitud_medio DECIMAL(5,2) NULL,
        longitud_atras DECIMAL(5,2) NULL,

        -- Regular / Buena / Muy buena
        corona NVARCHAR(20) NULL,
        quemada NVARCHAR(20) NULL,
        rameada NVARCHAR(20) NULL,

        descarga_autorizada_por NVARCHAR(100) NULL,
        inspeccion_realizada_por NVARCHAR(100) NULL,

        total_cajas INT NULL,
        observaciones NVARCHAR(500) NULL,

        pdf_filename NVARCHAR(200) NOT NULL,
        pdf_blob VARBINARY(MAX) NOT NULL,
        pdf_size_bytes INT NOT NULL,

        creado_por_usuario_id INT NOT NULL,
        creado_en DATETIME2 NOT NULL DEFAULT SYSDATETIME(),

        CONSTRAINT FK_PieDeCamion_Usuario
            FOREIGN KEY (creado_por_usuario_id) REFERENCES dbo.Usuarios(id)
    );
    CREATE INDEX IX_PieDeCamion_fecha ON dbo.PieDeCamion(fecha DESC);
END;
GO

-- Permiso nuevo. Admin lo recibe por es_admin=1 automáticamente.
-- (Si no había roles seedeados nuevos, no hace falta nada acá — el permiso
-- vive en app/core/permissions.py)
