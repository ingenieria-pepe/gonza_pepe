# Lo que necesito de la API — Aloha (ERP Almar) → dashboard poronga

**Para:** el desarrollador del ERP en Uruguay
**De:** Gonzalo (Almar) · escrito el 04/09/2026
**Qué es:** el sistema de análisis de compras/mercado de banana (lo llamamos
"poronga") hoy trabaja con exports manuales. Cuando exista la API para pasar los
datos en tiempo real, este documento dice **qué necesita, en qué forma, y las
trampas ya detectadas** para que la integración entre limpia.

---

## 0. Cómo consume los datos el lado de Almar (importa para el diseño)

- El consumidor es un **script de PowerShell en una PC Windows**, disparado por
  tarea programada **viernes 19:00 y miércoles 12:00** (y va a mudarse a un
  servidor siempre prendido). **No es un backend que escuche webhooks** — es un
  cliente que **sale a buscar (pull)** en cada corrida.
- Por eso la API tiene que ser **read-only, pollable, con token**. Nada de push
  hacia Almar; ya lo intentamos y la PC no siempre está prendida.
- Todo el sistema consume **JSON**. Un endpoint por entidad, JSON plano, es lo
  ideal. Si es CSV, ver la trampa de la coma decimal (§4).
- **Incremental si se puede:** un parámetro `?actualizado_desde=<fecha>` para no
  bajar todo el histórico cada vez. Si no, un dump completo también sirve al
  principio.
- **Cloudflare:** el propio código del ERP ya tiene documentado que el Cloudflare
  de `camcontador2` devuelve **403 (error 1010, browser integrity check)** a los
  user-agents de librerías. Si la API queda detrás de CF, hay que **permitir el
  cliente de Almar** (por token, o allowlist de UA). Lo digo porque ya nos frenó
  con otra fuente (Tridge) y perdimos 6 semanas de datos por eso.

---

## 1. Prioridad de endpoints (por valor para el negocio)

| # | Entidad | Por qué es lo que más sirve |
|---|---|---|
| **1** | **Maduración: historial de color por cámara** | Es el **resultado** que hoy no está en ningún lado. Cierra el modelo de vida verde. Ver §2. |
| **2** | **Pie de camión + cámaras** | Las mediciones de calidad al recibir, y a qué cámara entró cada lote. |
| **3** | **Plan de cargas** | Días de tránsito (TT) y cajas MIC vs descargadas = merma de viaje. |
| **4** | **Ventas por artículo, fecha y color** | La demanda real (en cajas, no en frecuencia de pedidos). |
| **5** | **Defectos / reclamos** | Calidad medida por su consecuencia comercial. |

---

## 2. ⭐ El endpoint clave: historial de color por cámara

Es el que no tengo de ninguna forma y el que hace que todo lo demás valga.

**El caso de uso:** cruzar *"este lote entró con esta temperatura de pulpa y este
calibre"* (pie de camión) contra *"tardó X días en llegar a Color 4"* (maduración).
Con eso, y una zafra de datos, se predice cuánto aguanta un lote **antes** de
decidir si va a cámara o se vende ya. Hoy eso se decide a ojo.

Por cada **cámara** (ZAC 1-30, Coronel Raíz 1-12), necesito:

- `ubicacion` (`ZAC` | `CR`) y `numero`
- `pie_de_camion_id` que la cargó (para atar con las mediciones de origen)
- **cada cambio de color con su timestamp**: `[{fecha_hora, color, cajas}]`
  (color en la escala que usen, 1=verde … 7=maduro)
- el conteo de cajas en cada punto (conteo cíclico o carga)

Si el dashboard de maduración (`editarsensores.somospepe.com` / ZAC Dashboard) ya
guarda esto, es cuestión de exponerlo. **Es la pieza que faltaba.**

---

## 3. Campos por entidad (nombres tal cual el esquema `ext`)

### `pie_de_camion` (cabecera de recepción)
Identificación: `id`, `fecha` (descarga), `fecha_carga` (origen), `hora_inicio`,
`hora_fin`, `chofer_nombre`, `placa_camion`, `exportador`, `empresa_transporte`,
`numero_afidi`, `codigo_importador_camion`, `productor`, `plan_carga_id`,
`total_cajas`, `estado`.

Mediciones (¡las que más sirven!) — vienen en 3 posiciones del camión
(puerta/medio/atrás) a propósito, para ver si el frío llegó parejo:
- `temp_pulpa_{puerta,medio,atras}_{1,2}` (2 tomas por posición)
- `peso_caja_{puerta,medio,atras}_{1,2}`
- `calibracion_{puerta,medio,atras}` — ⚠️ ver trampa §4
- `longitud_{puerta,medio,atras}` + `longitud_unidad` — ⚠️ ver trampa §4
- `corona`, `quemada`, `rameada` (Regular/Buena/Muy buena)
- `palet_rating`, `cajas_rating`, `flejes_rating` (1-5)
- ⭐ **`corte_color` (1-5) — CAMPO NUEVO A AGREGAR AL ERP.** Es la lectura del
  corte transversal del dedo (almidón/verdor de la pulpa), el único dato de
  calidad que hoy el ERP **no** captura y el que predice la vida verde. Escala:
  1=pálida/angular (sobremadura, no viaja) … 4=punto ideal para flete 5-7 días …
  5=muy verde. Mientras no exista en el ERP, Almar lo lleva a mano en
  `fuentes\calidad_lotes.xlsx`; cuando el ERP lo agregue, esa planilla se retira.

### `pie_de_camion_camara`
`ubicacion`, `numero`, `cantidad` (cajas; NULL = todo el camión), `cod_art`.

### `pie_de_camion_linea` (la mercadería)
`cod_art`, `descripcion`, `cantidad`, `marca`, `hay_reclamos`.

### `plan_de_cargas`
`carga_semana`, `status`, `factura`, `productor`, `pais_origen`, `fecha_carga`,
`carpeta_import`, `transportista`, `exportador`, `fecha_frontera`, `frontera`,
`fecha_descarga`, **`tt`** (días de tránsito), **`cajas_mic`** (declaradas),
**`cajas_desc`** (descargadas), `cant_pallet`, `cant_kilos_caja`, `codigo_viaje`.
> La diferencia `cajas_mic − cajas_desc` es **merma de tránsito**, un indicador de
> calidad que no tenía. Interesa que venga la resta o los dos campos.

### Ventas (por artículo)
Por línea de venta: `cod_art`, `descripcion`, `origen`, `color`, `cantidad`
(cajas), `fecha`, `cliente_cod`, `precio`. Reglas del dato que el ERP ya aplica
(respetarlas o la suma miente): venta = `TipDoc 'V'` **con** `Afecta = 1`;
anuladas afuera; `cantidad = CantidadHaber − CantidadDebe`; **Moneda 1 sola**
(no mezclar pesos y dólares en una suma).

### `catalogo-productos` (lookup)
`cod_art` → `descripcion` + `origen`. Es la **llave para cruzar todo** (aduana ↔
pie de camión ↔ cámara ↔ venta con el mismo código). Que venga completo.

---

## 4. ⚠️ Trampas ya detectadas — resolver en la API, no del lado de Almar

Todas éstas me costaron tiempo esta semana. Mejor que las resuelva la API una vez:

1. **`longitud_unidad` puede ser `cm` o `pulgadas`.** Si la API no normaliza,
   promediar longitudes mezcladas da cualquier cosa. **Pido: normalizar todo a cm**,
   o mandar la unidad explícita por registro.

2. **`calibracion` es un entero sin unidad declarada.** ¿Es mm, o treintaidosavos
   de pulgada? Necesito saberlo para compararlo contra el Codex (calibre ≥ 27 mm).
   **Pido: declarar la unidad.**

3. **Decimales con coma (cultura es-UY).** Si algún export sale en CSV, los números
   vienen `14,5` con coma. Al leerlos en formato internacional, la coma se
   interpreta como separador de miles y **`90.159,99` se convierte en 9.015.999**
   (×100). **Pido: JSON con punto decimal**, o si es CSV, declarar el formato.

4. **`pie_de_camion_producto` está deprecado** — la marca ahora va por línea
   (`pie_de_camion_linea.marca`). Que la API mande la línea, no la tabla vieja.

5. **Depósito de ingreso siempre `B`.** De 836 líneas reales, las 836 en `B`. No
   hace falta mandarlo por línea; si viene, ignorar variaciones.

6. **Fechas: distinguir `fecha_carga` (origen) de `fecha` (descarga).** Son
   distintas y la diferencia entre las dos es parte del tránsito. No colapsarlas.

---

## 5. Formato de entrega ideal (resumen)

- **JSON, read-only, con token.** Punto decimal, fechas ISO `yyyy-mm-dd`.
- Un endpoint por entidad de §3, más el de maduración de §2.
- Parámetro `?actualizado_desde=` para incremental.
- Que el token/UA del cliente de Almar pase el Cloudflare (§0).
- No hace falta tiempo real al segundo: con que esté fresco a la hora de la
  corrida (vie 19h / mié 12h) alcanza. Un cache de unas horas está perfecto.

---

## 6. Qué se destraba cuando esto exista

- **Se elimina el tipeo manual.** Hoy hay una planilla (`calidad_lotes.xlsx`) que
  se llenaría a mano; con la API queda obsoleta — los datos ya están en el ERP.
- **Se cierra el modelo de vida verde** (input de pie de camión + output de color
  por cámara).
- **Se separa "vino mal de origen" de "se arruinó en el viaje"** cruzando corte +
  TT + temp de pulpa, sin tocar a los productores brasileños.
- El dashboard de mercado, la proyección y el de calidad pasan a actualizarse
  solos con datos reales, igual que ya lo hacen hoy con Cepea y aduana.
