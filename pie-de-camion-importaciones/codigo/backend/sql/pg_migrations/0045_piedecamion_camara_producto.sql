-- PG Migration 0045 — Producto por cámara en el Pie de Camión.
--
-- Cuando la carga se REPARTE en varias cámaras y el camión trae varios productos,
-- hasta ahora no quedaba registrado QUÉ producto fue a QUÉ cámara (la fila solo
-- tenía ubicación + número + cajas). Se agrega cod_art: cada fila de reparto pasa
-- a ser una asignación "N cajas del producto X a la cámara Y".
--
-- NULL = sin desglose por producto: el caso normal de UNA sola cámara (va todo el
-- camión) y los repartos viejos anteriores a esta migración.
ALTER TABLE ext.pie_de_camion_camara
    ADD COLUMN IF NOT EXISTS cod_art VARCHAR(30) NULL;
