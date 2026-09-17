-- Fix Monitor de Entregas: el slot "Reyes" de la grilla capturaba a CUATRO clientes
-- distintos (confirmado con el usuario 15/07/2026: Luciana NO es Reyes; Alvaro y
-- Nacho son dos clientes distintos).
--
-- Clave: el matcheo de la tele es difuso (cliente_match: toda palabra del nombre de
-- grilla debe estar en el nombre BD; iniciales valen) → un slot genérico "Reyes"
-- matchea a CUALQUIER cliente con la palabra Reyes, tenga alias o no. Por eso no
-- alcanza con borrar alias: hay que hacer específico el nombre del slot.
--
--   · Grilla 'Reyes' (Martes 8-9) → 'Alvaro Reyes': solo lo matchea ALVARO EDUARDO
--     REYES (cod 78001, el dueño real del slot). Su alias deja de hacer falta.
--   · Grilla 'N Reyes' (Martes 5-6) → 'Nacho Reyes': igual que su fila de Viernes
--     6-7; matchea directo a Nacho Reyes (cod 2112201) sin alias.
--   · Se borran los TRES alias a 'Reyes' (Alvaro ya matchea directo; los de Luciana
--     cod 2119201 y Nacho eran incorrectos — el de Nacho además lo sacaba de sus
--     propios slots). Luciana queda sin slot: sale con su nombre real en auto-franja.

UPDATE ext.horario_entrega SET nombre = 'Alvaro Reyes' WHERE nombre = 'Reyes';
UPDATE ext.horario_entrega SET nombre = 'Nacho Reyes' WHERE nombre = 'N Reyes';

DELETE FROM ext.cliente_alias
WHERE nombre_bd IN ('ALVARO EDUARDO REYES', 'Nacho Reyes', 'Luciana Simoni Viera De Brito Reyes');
