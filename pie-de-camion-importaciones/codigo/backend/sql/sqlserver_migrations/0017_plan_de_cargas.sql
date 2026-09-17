-- Migration 0017 — Tabla PlanDeCargas
-- Reemplaza el Excel del OneDrive donde se trackea cada carga de fruta
-- que viene de BR/PY. Cada fila = un camión planificado/llegado.
--
-- Fuente del modelo: CSV exportado del Excel actual (Plan-CargasBR-2024-2026).
-- Status posibles: Solicitado | Confirmado | Frontera | Arribado | Descargado | Cancelado.
-- El "monitor de camiones" muestra todo lo que NO está Descargado ni Cancelado.

USE AlmarExtensiones;
GO

IF OBJECT_ID('dbo.PlanDeCargas', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PlanDeCargas (
        id INT IDENTITY(1,1) PRIMARY KEY,

        -- Identificación de la carga
        carga_semana NVARCHAR(20) NULL,            -- número de semana ("2", "8", etc.)
        status NVARCHAR(30) NOT NULL DEFAULT 'Solicitado',
        factura NVARCHAR(30) NULL,                 -- "001/24", "021//24"
        productor NVARCHAR(100) NULL,              -- "Valdemar", "Fischer", "Varios"
        fecha_carga DATE NULL,
        carpeta_import NVARCHAR(40) NULL,          -- "BRB001", "PYB014"
        afidi NVARCHAR(300) NULL,                  -- pueden venir varios separados por coma

        -- Transporte
        transportista NVARCHAR(100) NULL,
        exportador NVARCHAR(150) NULL,
        placas_tractor NVARCHAR(30) NULL,
        placas_remolque NVARCHAR(30) NULL,
        chofer NVARCHAR(100) NULL,
        celular NVARCHAR(40) NULL,

        -- Tránsito (frontera + descarga)
        fecha_frontera DATE NULL,
        frontera NVARCHAR(50) NULL,                -- "Rio Branco", "Salto", "Chuy"
        inspector_mgap NVARCHAR(100) NULL,
        fecha_descarga DATE NULL,

        -- Mercadería
        tt INT NULL,                               -- TT en el Excel (no doc todavía)
        cajas_mic INT NULL,                        -- cajas según documento MIC
        cajas_desc INT NULL,                       -- cajas efectivamente descargadas
        cant_pallet INT NULL,
        cant_kilos_caja FLOAT NULL,
        codigo_viaje NVARCHAR(40) NULL,            -- "JM001", "PY GM 003"
        mic NVARCHAR(40) NULL,

        observaciones NVARCHAR(MAX) NULL,

        -- Auditoría
        creado_en DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
        actualizado_en DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
        creado_por_usuario_id INT NULL,
        actualizado_por_usuario_id INT NULL,

        CONSTRAINT FK_PlanDeCargas_CreadoPor
            FOREIGN KEY (creado_por_usuario_id) REFERENCES dbo.Usuarios(id),
        CONSTRAINT FK_PlanDeCargas_ActualizadoPor
            FOREIGN KEY (actualizado_por_usuario_id) REFERENCES dbo.Usuarios(id),
    );

    -- Índices para queries habituales:
    -- 1) Monitor: WHERE status NOT IN (...descargado, cancelado)
    CREATE INDEX IX_PlanDeCargas_status ON dbo.PlanDeCargas(status);
    -- 2) Listas ordenadas por fecha estimada de descarga
    CREATE INDEX IX_PlanDeCargas_fecha_descarga ON dbo.PlanDeCargas(fecha_descarga);
    CREATE INDEX IX_PlanDeCargas_fecha_frontera ON dbo.PlanDeCargas(fecha_frontera);
END;
GO

-- Permisos nuevos asociados (los reconocemos en app/core/permissions.py).
-- Los inserts de RolPermisos los hace el seed/admin manualmente; acá sólo
-- nos aseguramos que la migration sea idempotente.
GO
