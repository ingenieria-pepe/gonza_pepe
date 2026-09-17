-- Edición del pie de camión (desde Ingresos, mientras está 'pendiente'). Marca de
-- auditoría: quién lo editó por última vez y cuándo. NULL = nunca se editó.
ALTER TABLE ext.pie_de_camion
    ADD COLUMN IF NOT EXISTS editado_en             TIMESTAMP NULL,
    ADD COLUMN IF NOT EXISTS editado_por_usuario_id INT       NULL;
