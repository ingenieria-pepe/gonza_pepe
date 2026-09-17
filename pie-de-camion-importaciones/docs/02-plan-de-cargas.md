# Plan de Cargas · Monitor de Camiones · Carpetas de importación

El seguimiento de **cada camión de fruta importada**, desde que se le pide la
carga al productor hasta que se descarga en el depósito. Reemplaza el Excel de
OneDrive donde se trackeaba todo a mano.

Tres pantallas sobre el mismo dataset (la tabla `ext.plan_de_cargas`):

| Pantalla | Para quién | Qué muestra |
|---|---|---|
| **Plan de Cargas** | administración | todas las cargas, editables, con filtros y export a Excel |
| **Monitor de Camiones** | pantalla del depósito (TV) | sólo lo que está por llegar |
| **Carpetas de importación** | administración | el control de carpetas: cuánto se cargó contra cada factura |

---

## 1. Las dos planillas maestras

Hay **dos** Excel de origen, y el sistema los distingue con el campo `fuente`:

| `fuente` | Planilla | Países |
|---|---|---|
| `BR` | *"PROGRAMA DE CARGAS EN BRASIL"* — la histórica | Brasil, Paraguay |
| `OTROS` | *"PROGRAMA DE ARRIBOS"* | Ecuador, Chile, Bolivia, Perú, Colombia, México + ultramar (Italia, Grecia, España, Egipto) |

Tienen **las mismas columnas centrales pero en distinto orden**, y algunas
diferencias reales:

| | `BR` | `OTROS` |
|---|---|---|
| País de origen | se carga a mano (implícito) | **es una columna** (`EC`/`CL`/`BO`/`PE`/`CO`/`MX`/`AR`/`GR`/`EG`/`ES`/`IT`…) |
| Productor | columna propia | no hay — el producto va en la col. 3 |
| Chofer / celular | sí | no |
| Placas | tractor + remolque | una sola columna |

El mapeo columna→campo de cada una está en
`datos/planilla-BR-columnas.csv` y `datos/planilla-OTROS-columnas.csv`, y el
parser en `codigo/backend/app/scripts/import_plan_cargas.py` (`IDX` y `OTROS_IDX`).

### El puente con OneDrive

`codigo/backend/app/modules/plan_cargas/onedrive_sync.py` — es **temporal**,
hasta que la carga sea nativa en el sistema. Reglas:

- **Una sola dirección: Excel → sistema. NUNCA escribe en OneDrive.**
- Cada sync **reemplaza sólo las filas de su fuente** — no pisa a la otra.
- **No borra las cargas referenciadas por un Pie de Camión** (rompería la FK).
- Se compara el **hash sha256** del `.xlsx`: si no cambió, no se toca nada.
- Si la descarga viene vacía o rota, **falla y conserva lo que ya había**.
  Nunca deja la tabla vacía por un error de red.
- Loop de fondo cada **30 s**, del lado del servidor. Eso es lo que permite que
  la TV en modo kiosko (sin login) vea el Monitor al día sin depender de que
  alguien tenga la pantalla abierta.
- Con el puente activo, la edición desde el sistema se bloquea (la fuente de
  verdad es el Excel).

> **Detalle técnico que costó tiempo:** los archivos están migrados a SharePoint,
> así que el endpoint `shares` devuelve 401. Lo que funciona es seguir el link
> con `&download=1`, con cookie jar y User-Agent de navegador.

---

## 2. El ciclo de vida de una carga

```
Solicitado ──► Confirmado ──► [Cargado] ──► [Mar] ──► [Puerto] ──►
                                         Frontera ──► Liberado ──►
                                         Arribado ──► Descargado
                                                       (terminal)

En cualquier momento: ──► Cancelado / Destruida  (terminales)
```

| Status | Planilla | Significado | ¿Sale en el Monitor? |
|---|---|---|---|
| `Solicitado` | ambas | pedida al productor, sin confirmar | no |
| `Confirmado` | ambas | el productor confirmó que va a salir | no |
| `Cargado` | OTROS | cargó en origen | no |
| `Mar` | OTROS | navegando (ultramar) | no |
| `Puerto` | OTROS | llegó a puerto | no |
| `Frontera` | ambas | llegó a la frontera, en trámite | **sí** |
| `Liberado` | ambas | salió de la frontera, en camino al depósito | **sí** |
| `Arribado` | ambas | llegó al depósito, esperando descarga | no |
| `Descargado` | ambas | ya se descargó | no |
| `Cancelado` | ambas | se canceló, no llega | no |
| `Destruida` | OTROS | la carga se destruyó | no |

También en `datos/estados-de-carga.csv`.

**El Monitor muestra sólo `Frontera` y `Liberado`**: los que están por llegar
inmediatamente. `Solicitado`/`Confirmado`/`Mar` son demasiado prematuros para
una pantalla de depósito, y `Arribado`/`Descargado` ya están adentro.

> La validación de estados la hace Pydantic, **no un CHECK en SQL**: aparecen
> estados nuevos seguido y no vale la pena una migración cada vez. El precio es
> que hay que mantener sincronizadas tres listas: el schema del back, el
> importador y el front. Están marcadas con un comentario en las tres.

**El status lo cierra el Pie de Camión:** cuando se guarda un pie que eligió una
carga del Plan, esa carga pasa a `Descargado` automáticamente. Nadie lo tipea.

---

## 3. Los campos de una carga

### Identificación
`carga_semana` (nº de semana), `status`, `factura` (`"001/24"`), `productor`,
`fecha_carga`, `carpeta_import` (`"BRB001"`, `"PYB014"`), `afidi` (pueden venir
varios separados por coma), `pais_origen`, `fuente`.

### Transporte
`transportista`, `exportador`, `placa_camion`, `placa_remolque`, `chofer`,
`celular`.

### Tránsito
`fecha_frontera`, `frontera` (Río Branco, Salto, Chuy, Rivera, Montevideo),
`inspector_mgap`, `fecha_descarga`.

### Mercadería
`productos` (lista JSON de `{descripcion, icono, cod_art}`), `tt`,
`cajas_mic` (según el documento MIC), `cajas_desc` (efectivamente descargadas),
`cant_pallet`, `cant_kilos_caja`, `codigo_viaje` (`"JM001"`, `"PY GM 003"`),
`mic`, `observaciones`.

> **`cod_art` en los productos:** lo setea el picker cuando se carga desde el
> sistema, y permite que el Pie de Camión arme la línea de mercadería directo,
> sin re-buscar el artículo. Los productos que vienen del Excel son texto libre
> y no lo tienen → el Pie cae a buscar por descripción.

---

## 4. Carpetas de importación

El "control de carpetas" del Excel viejo: contra cada **factura** hay una
cantidad comprada, y se va cargando en camiones sucesivos.

`cargado` y `saldo` **no se editan: se calculan en vivo**:

```
cargado = SUMA de cajas_mic de todas las cargas del Plan con la MISMA factura
saldo   = cantidad − cargado
          ... pero 0 si |diferencia| < 20    ← tolerancia heredada del Excel
```

La tolerancia de 20 cajas replica el criterio del Excel original: una diferencia
chica es merma normal, no un saldo pendiente.

Además, la carpeta sirve para **autollenar el formulario**: al escribir una
factura ya conocida se traen carpeta, exportador, frontera, transportista y
AFIDI. El productor **no** se autollena — eso cambia carga por carga.

---

## 5. Monitor de Camiones (la pantalla del depósito)

- Ordenado por estado (`Arribado` → `Solicitado`) y después por fecha estimada
  de descarga (o de frontera si no hay descarga estimada).
- Acceso sin login mediante **token de kiosko** (`?k=`) o IP conocida; si no,
  requiere sesión. Es lo que permite dejar una TV colgada mostrando la pantalla.
- Combinado con el loop de sync de 30 s, la TV se mantiene sola.

---

## 6. Archivos

```
codigo/backend/app/modules/plan_cargas/
  schemas.py         estados, campos, validación
  queries.py         SQL (incluye el cálculo de cargado/saldo)
  router.py          endpoints CRUD + carpetas + export.xlsx + monitor
  onedrive_sync.py   el puente con las planillas maestras

codigo/backend/app/scripts/
  import_plan_cargas.py       parser de las dos planillas + upsert (tiene DRY-RUN)
  import_plan_cargas_csv.py

codigo/frontend/src/modules/plan-cargas/PlanCargasPage.tsx
codigo/frontend/src/modules/monitor-camiones/MonitorCamionesPage.tsx
codigo/frontend/src/shared/api/planCargas.ts
```

El importador tiene **dry-run sin base de datos** (el parseo es stdlib pura):

```bash
# muestra qué cargaría, sin escribir
python -m app.scripts.import_plan_cargas actualizado.csv

# carga sumando
python -m app.scripts.import_plan_cargas actualizado.csv --commit

# reemplaza (sync al master)
python -m app.scripts.import_plan_cargas actualizado.csv --commit --replace
```
