# Pie de Camión

El reemplazo digital de la planilla de papel **"Control De Mercadería A Pie
Camión"**, la que se llenaba a mano y se encarpetaba. Se completa desde el
celular, parado al lado del camión, mientras se descarga.

Es el punto donde la fruta importada **entra al sistema**: acá se decide si la
mercadería está bien, se deja constancia con fotos, y de acá salen el ingreso de
stock y el reclamo al proveedor.

---

## 1. El flujo completo

```
1. ELEGIR LA CARGA      El operario abre el módulo y elige del Plan de Cargas
                        el camión que está descargando (o carga los datos a
                        mano si no está en el Plan).
                        → se pre-cargan productor, exportador, chofer, placa,
                          transportista, AFIDI, productos.

2. LLENAR EL PIE        Datos del camión + mediciones + fotos + requisitos de
                        cada fruta + la mercadería (líneas) + defectos.

3. ENVIAR               El back:
                        · genera el informe PDF (planilla digital)
                        · genera un PDF aparte con las fotos
                        · genera un PDF aparte con la documentación escaneada
                        · marca la carga del Plan como "Descargado"
                        · avisa por webhook a los dashboards de maduración

4. ¿HAY RECLAMOS?       Si se cargaron defectos → se arma el RECLAMO al
                        proveedor, con su propio PDF de fotos.

5. CONFIRMAR INGRESO    El back-office confirma y recién ahí se escribe el
                        ingreso de stock en el ERP contable (Macrosoft).
                        Es un permiso aparte (`ingreso_macrosoft`).
```

Los estados de un pie son tres: **pendiente** (cargado, sin ingresar),
**ingresado** (ya escribió el stock) y **anulado**.

---

## 2. Qué se carga en el formulario

### Identificación del camión

| Campo | Nota |
|---|---|
| `fecha` | fecha de **descarga** (recepción) |
| `fecha_carga` | fecha en que se cargó el camión **en origen** |
| `hora_inicio` / `hora_fin` | duración de la descarga |
| `chofer_nombre`, `placa_camion` | |
| `empresa_transporte` | |
| `exportador` | |
| `productor` | quién produjo la fruta — viene del Plan de Cargas |
| `numero_afidi` | el documento sanitario |
| `codigo_importador_camion` | ej. `FH-044` = iniciales del productor + nº de camión |
| `plan_carga_id` | link a la carga del Plan (si se eligió de ahí) |

> **`codigo_importador_camion`** es la llave con la que después se encuentra un
> camión. `FH` sale de las iniciales del productor Fischer (ver
> `datos/productores.csv`); `044` es el número correlativo de camión. Se imprime
> en etiquetas Zebra que se pegan a los pallets, con un QR que codifica sólo el
> código (texto plano, sin URL: si un externo lo escanea no llega a nada).

### Condiciones generales — 1 a 5 + comentario

`palet_rating`, `cajas_rating`, `flejes_rating`. Es la impresión general del
estado del embalaje.

### Mediciones — siempre en tres posiciones del camión

Se mide en **Puerta / Medio / Atrás** para detectar si el frío llegó parejo:

| Medición | Campos | Por qué tres puntos |
|---|---|---|
| Temperatura de pulpa | `temp_pulpa_{puerta,medio,atras}_{1,2}` | dos tomas por posición; si la de atrás viene alta, el equipo de frío no dio |
| Peso de la caja | `peso_caja_{puerta,medio,atras}_{1,2}` | verifica que el peso declarado se cumpla en todo el camión |
| Calibración | `calibracion_{puerta,medio,atras}` | |
| Longitud | `longitud_{puerta,medio,atras}` + `longitud_unidad` (`cm` \| `pulgadas`) | |

### Calificaciones de banana

`corona`, `quemada`, `rameada` → **Regular / Buena / Muy buena**.

Son los defectos clásicos de la banana. Nacieron con el módulo, cuando sólo
entraba banana; para las otras frutas está el sistema de requisitos (abajo).

### Requisitos por fruta — configurables por el ingeniero agrónomo

El pie nació enfocado en banana, pero también entran exóticos con controles
propios. El agrónomo define **por categoría de fruta** qué se pide al ingreso:

- `numero` — un valor con unidad (`°Brix`, `kg`, `mm`)
- `texto` — texto libre
- `opciones` — elegir de una lista (`["Verde", "Pintón", "Maduro"]`)
- `foto` — foto obligatoria

Las categorías salen de `codigo/backend/app/core/categorias.py` (ver
`datos/categorias-de-fruta.csv`): Banana, Kiwi, Palta, Papaya, Coco, Piña, Mango…

**Los requisitos se responden por fruta, no por línea.** Un camión con dos
variedades de kiwi contesta *una* vez los checks de Kiwi.

> **Detalle importante:** las respuestas **snapshotean** la etiqueta, el tipo y
> la unidad. Si el agrónomo mañana cambia la configuración, los pies históricos
> siguen mostrando lo que efectivamente se preguntó ese día. Sin esto, cambiar
> un requisito reescribiría la historia.

### Firmas

`descarga_autorizada_por` e `inspeccion_realizada_por`.

### La mercadería (líneas)

Una línea por producto: `cod_art`, `cantidad` (cajas), `marca`
(ej. *"PY de Primera"*, *"Fischer"*) y **`hay_reclamos`** (obligatoria).

> **Por qué `hay_reclamos` va por línea y no por camión:** con un camión de
> varias frutas, una sola respuesta era ambigua. Y por qué es obligatoria: un
> pie sin defectos era ambiguo — no se sabía si la fruta vino bien o si se
> pasaron de revisarla.

El **depósito** ya no se pregunta: la mercadería de un camión siempre entra por
el mismo (`B`). De 836 líneas de ingreso reales en el ERP, las 836 están en `B`
— incluso la fruta que después va a Coronel Raíz. Preguntarlo era ruido, y el
formulario venía con `A` por default y había que corregirlo camión por camión.

### Defectos

Por línea: `motivo_id` + `cantidad` + `notas` + fotos. Es lo que después arma el
reclamo al proveedor.

### Cámaras de maduración

A qué cámara entró la fruta. Normalmente **una** (toda la carga), pero se puede
repartir indicando cajas y producto por cámara.

| Ubicación | Cámaras |
|---|---|
| `ZAC` | 30 |
| `CR` (Coronel Raíz) | 12 |

> Coronel Raíz además tiene 13 **contenedores** que hoy el sistema no modela. Si
> alguna vez la fruta entra a un contenedor, hay que agregar `tipo_unidad` al
> modelo y al webhook.

---

## 3. Las fotos — el corazón del reclamo

Las fotos son lo que sostiene un reclamo al proveedor, así que el checklist es
fijo y está ordenado. La lista completa, en orden, está en
**`datos/fotos-obligatorias-pie-de-camion.csv`**. Resumen:

| # | Sección | Qué se fotografía |
|---|---|---|
| 1 | Temperatura container | el display del equipo de frío |
| 2 | Ticket del peaje | el ticket |
| 3 | Puerta del camión | con la matrícula visible |
| 4–6 | Temperaturas pulpa | el termómetro, en Adelante / Medio / Atrás |
| 7 | Estado del pallet | incluyendo el **sello de fumigación** |
| 8 | Balanza | que se vea clara la mercadería **y** el peso |
| 9–20 | Estado de la fruta | en cada posición (Adelante/Medio/Atrás): caja abierta, corona, calibre, longitud |
| 21 | Código en la caja | el código de producto — **una sola vez**, no por posición |

Además hay una galería libre ("Otras fotos") y el escaneo de documentación A4
(el celular endereza y recorta cada página, y el back arma un PDF aparte).

**Fuente única de verdad:** `codigo/frontend/src/modules/piedecamion/fotoCategorias.ts`.
Ese archivo define a la vez qué slots muestra el formulario, en qué orden, y con
qué título aparece cada foto en el informe PDF. Tocar ahí cambia las dos cosas.

**Fotos después del envío:** un pie ya enviado admite anexar fotos
(`POST /{id}/fotos`). Se **agregan al final** del PDF de fotos; las anteriores
no se tocan. Sirve para lo que se descubre al día siguiente.

**Termógrafo:** se sube aparte como PDF y queda fusionado dentro del informe.

---

## 4. Los PDF que salen

| PDF | Contenido |
|---|---|
| **Informe** (`/{id}/pdf`) | la planilla digital: todos los datos, mediciones, líneas, defectos, requisitos + el termógrafo fusionado |
| **Fotos** | todas las fotos agrupadas por categoría, en el orden canónico, con su título |
| **Documentación** (`/{id}/documentacion-pdf`) | los A4 escaneados con el celular |
| **Reclamo** | las fotos de los defectos, aparte, para mandarle al proveedor |

El informe **no busca ser lindo**: replica la densidad de información de la
planilla de papel original, porque es un comprobante operativo que se imprime y
se archiva. Se genera con ReportLab
(`codigo/backend/app/modules/piedecamion/pdf.py`).

---

## 5. Detalles de robustez que valen la pena copiar

Estas soluciones costaron incidentes reales:

- **Idempotencia (`client_ref`).** El celular genera un UUID que vive en el
  borrador. Si el mismo pie llega dos veces (reintento después de un timeout con
  el body ya procesado, cosa que pasa con señal mala en el depósito), el back
  devuelve el pie existente en vez de duplicar el camión.

- **Reserva antes de confirmar (`confirmando_en`).** El ingreso de stock escribe
  en **otra base** (el ERP contable), sin transacción común. Chequear el estado
  y después escribir no alcanza: entre el `SELECT` y la escritura entran dos
  clicks, dos pestañas o el reintento del navegador, y los dos crean su
  documento. Por eso primero se reserva la fila; si algo queda reservado y sin
  cerrar, la pantalla manda a revisar en el ERP en vez de ofrecer un reintento
  que podría duplicar el ingreso.

- **La fecha del ingreso es HOY, siempre.** Antes salía del campo `fecha` del
  pie y eso la volvía tipeable: un pie se cargó con la fecha *planificada* de la
  carpeta y el ingreso quedó imputado tres días atrás — el stock total daba
  bien, pero el movimiento caía en un período ya cerrado y ensuciaba la
  conciliación. Los camiones se ingresan al descargarlos, nunca días después.

- **Un ingreso es de UN depósito.** Si las líneas quedaron repartidas, el back
  rechaza la confirmación en vez de partir el documento.

- **El borrador vive en el celular.** Se llena a pie de camión, sin señal
  garantizada; el envío es un solo POST con todo (fotos comprimidas a ~300 KB
  cada una).

---

## 6. Integración con maduración (webhook saliente)

Cuando se registra un pie, Aloha le avisa a los dashboards de maduración de ZAC
y Coronel Raíz **qué entró a qué cámara**, para que lo auto-carguen en lugar de
tipearlo a mano.

- Rutea **por ubicación**: sólo le pega a la URL de las ubicaciones que
  aparecen en las cámaras de ese pie.
- El endpoint del otro lado es **idempotente por `pie_de_camion.id`**.
- Es **best-effort / fire-and-forget**: se dispara como tarea de fondo después
  de responder, y cualquier error se loguea sin romper nunca la carga del pie.
  Sin token configurado, la integración está apagada.
- Manda el país deducido del texto (`"Banana Brasil"` → `BRASIL`) y la familia
  limpia (`"Banana Brasil (super) Color 4"` → `"Banana Brasil"`).

Código: `codigo/backend/app/modules/piedecamion/webhook.py`.
