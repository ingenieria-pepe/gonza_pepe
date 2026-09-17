# Insight para Aloha (ERP de Almar) — lo que el pie de camión ya sabe y no usa

**De:** el Claude del dashboard de compras de Almar (`C:\Users\Usuario\Desktop\poronga\`, PC de Gonzalo).
**Para:** el Claude que trabaja sobre Aloha Uruguay.
**Fecha:** 09/09/2026. Escrito para leerse de corrido sin abrir nada más; las rutas de archivos están al final por si querés verificar.

## 1. El caso que disparó esto

Camión de **Cassio Hauck** (Santa Catarina), pie de camión **#202**, código importador **CK103**, 1.009 cajas.

| Dato | Valor |
|---|---|
| Fecha de carga | 04/09/2026 |
| Fecha de descarga | 09/09/2026 03:32 |
| Tránsito | 5 días (la mediana de Cassio es 3, p90 de Brasil 6) |
| Camión | furgón cerrado sin equipo de frío, transportista Chabat, frontera Rio Branco |
| Pulpa puerta | 12,8 / 11,7 °C |
| Pulpa medio | 17,7 / 17,5 °C |
| Pulpa atrás | 13,6 / 13,5 °C |
| Calibre | 27 / 30 / 29 mm (la caja declara mín. 31 mm; Codex exige 27) |
| Largo | 24 / 23 / 26 cm |
| Peso bruto por caja | 23,8 a 26,4 kg, promedio 24,9 (la caja declara 26) |
| Corona / quemada / rameada | Buena / Regular / Buena |
| Reclamo | 19 cajas sobremaduras (1,9 %) y "fruta quemada por frío" |
| Cámara de ingreso | ZAC 6 |

Clima real en la ruta durante el viaje (Open-Meteo, mínimas diarias):

| Día | Luiz Alves SC | Rio Branco | Montevideo |
|---|---|---|---|
| 04/09 | 14,7 | 8,2 | 8,7 |
| 05/09 | 13,7 | 4,6 | 7,2 |
| 06/09 | 11,0 | 3,5 | 6,3 (máx 8,5) |
| 07/09 | 10,1 | 1,5 | 1,6 |
| 08/09 | 12,2 | 7,0 | 4,9 |

Un día antes de cargar, Gonzalo recibió por WhatsApp tres fotos de dedos cortados a lo largo en el bananal: dos verde-duro sanos y **uno ya adelantado** (franja ámbar en el eje central, almidón convirtiéndose en azúcar). Sin ver el camión, se anticipó que ese lote llegaría con fruta virando. Llegó con 19 cajas maduras.

## 2. El insight

**El pie de camión ya captura todos los datos que hacen falta para diagnosticar frío y anticipar maduración, pero los guarda como números sueltos. Con cuatro reglas encima se vuelve un sistema de alerta, sin agregar ni un campo nuevo.**

1. **El gradiente térmico es la firma del camión sin frío.** Seis tomas de pulpa en tres posiciones no son "una temperatura": son una curva. Puerta y atrás a 12-13 °C con el medio a 17,5 °C dice que los extremos se enfriaron por debajo del umbral de daño (13-14 °C para Cavendish) mientras el centro, aislado por las cajas, siguió madurando. Un camión con frío da las seis tomas parejas. Regla: `max(6 tomas) − min(6 tomas) > 4 °C` → marcar "gradiente" y muestrear la fruta de los extremos para el reclamo, no del medio.

2. **El riesgo de frío se conoce antes de que el camión llegue.** El Plan de Cargas tiene fecha de carga, frontera y transportista; el tránsito esperado sale de la mediana histórica por productor y frontera; las mínimas de la ruta salen gratis de Open-Meteo (`api.open-meteo.com/v1/forecast` con `daily=temperature_2m_min` y `forecast_days`). Regla: si el tránsito esperado cruza dos o más noches con mínima menor a 8 °C y el camión no tiene equipo, avisar al cargar, no al descargar. En este caso el aviso habría salido el 04/09 a la mañana.

3. **El corte en origen predice las cajas maduras.** Una foto del dedo cortado al medio, tomada por el productor el día de la carga, con un puntaje simple de 1 a 5 (1 pálida y angular, 4 firme y pareja, 5 muy verde), anticipa cuánta fruta va a llegar virando. Hoy ese dato viaja por WhatsApp y muere ahí. Es un ítem más del checklist de fotos del Plan de Cargas, en el estado Confirmado o Cargado.

4. **La caja declara lo que hay que verificar.** La etiqueta dice diámetro mínimo 31 mm y bruto 26 kg; el operario midió 27-30 mm y 24,9 kg. Esos dos valores declarados son constantes por exportador y producto, y el pie de camión ya mide calibre y peso. Regla: comparar automáticamente contra lo declarado y precargar el reclamo con la diferencia.

Y el dato que falta, que sólo Aloha puede dar:

5. **Vida verde = días entre la descarga y el momento en que el lote empieza a virar solo.** Es la variable que cierra todo el circuito: permite decir qué productor, qué tránsito y qué temperatura de llegada aguantan más. El módulo de ventas ya sabe cuándo cada lote pasa de Color 1 a Color 3 o 4 en cámara. Guardar esa fecha por lote (o inferirla del primer movimiento a color 3+) convierte cada camión en una observación. Del lado del dashboard esto se está anotando a mano en una planilla (`calidad_lotes.xlsx`, columna `fecha_rompio`) y hacen falta 15 lotes para modelar; con Aloha saldría solo.

## 3. Dónde encaja en el modelo de Aloha (según el paquete de traspaso)

- Campos que ya existen en pie de camión: `temp_pulpa_{puerta,medio,atras}_{1,2}`, `calibracion_{puerta,medio,atras}`, `longitud_{puerta,medio,atras}`, pesos de cajas, `corona/quemada/rameada`, `hay_reclamos` por línea, fotos obligatorias por posición.
- Estados del Plan de Cargas: Solicitado → Confirmado → Frontera → Liberado → Arribado → Descargado. Las reglas 2 y 3 viven entre Confirmado y Frontera; la 1 y la 4 en Descargado; la 5 en cámara y ventas.
- Datos de referencia útiles: productores con iniciales, transportistas, fronteras, categorías de fruta, checklist de fotos.

Propuesta mínima, en orden de valor por esfuerzo:

1. Campo calculado `gradiente_pulpa` y bandera `riesgo_frio_llegada` en el pie de camión (regla 1). Cero cambios de pantalla.
2. Tabla `declarado_por_exportador` (diámetro mínimo, bruto, neto) y comparación automática al guardar (regla 4).
3. Ítem "corte en origen" en el checklist de fotos con puntaje 1-5 (regla 3).
4. Job diario que cruza cargas en tránsito con mínimas de Open-Meteo por ruta (regla 2).
5. `fecha_rompio` por lote inferida de cámara o ventas (regla 5).

## 4. Qué NO conviene copiar del dashboard

- Los umbrales de yodo y Brix son orientativos, no confirmados por fuente primaria. El de temperatura (13-14 °C) sí está confirmado.
- La deduplicación de datos de aduana, los alias de productores y demás son problemas del dashboard, no del ERP.

## 5. Material de respaldo en la PC de Gonzalo

- Reporte completo del camión: `poronga\fuentes\calidad_fotos\2026-09-08_cassio\CK103_pie_de_camion_202_2026-09-09.pdf` (texto extraíble con `pdftotext`; las 39 fotos van como JPEG en ASCII85).
- Fotos del corte en origen (08/09) y de la evidencia de frío en recepción, misma carpeta.
- Planilla de calidad por lote: `poronga\fuentes\calidad_lotes.xlsx` (hoja `lotes`, 17 columnas con comentarios en el encabezado) y su panel `poronga\index_calidad.html`.
- Guía de corte transversal y umbrales con trazabilidad: `poronga\guia_corte\guia_corte_transversal_banana.html` y `fuentes_y_notas.txt`.
- Plan de Cargas parseado (camiones, tránsito por productor y frontera, en camino, programados): `poronga\fuentes\plan_cargas.json`.
- Extracto del ERP que usé para ubicar los campos: `poronga\pie-de-camion-importaciones\docs\01-pie-de-camion.md`.
