# API

FastAPI. Todos los paths son relativos a la raíz de la API (en producción,
detrás de un nginx que proxya `/api/*`).

---

## `/pie-camion`

**Puerta de lectura del módulo:** basta *cualquiera* de estos permisos —
`pie_camion`, `recepcion`, `stock`, `consulta`, `pie_requisitos_config`. La
escritura está restringida aparte, endpoint por endpoint.

| Método | Path | Qué hace |
|---|---|---|
| `GET` | `/pie-camion` | listado (filtrable por `estado`) |
| `GET` | `/pie-camion/{id}` | detalle completo: cabecera + líneas + defectos + requisitos |
| `POST` | `/pie-camion` | **crear un pie** — el POST gordo, con todo adentro |
| `PUT` | `/pie-camion/{id}` | editar |
| `POST` | `/pie-camion/{id}/fotos` | anexar fotos a un pie ya enviado |
| `POST` | `/pie-camion/{id}/marcar-descargado` | marca "revisado" |
| `POST` | `/pie-camion/{id}/confirmar` | **escribe el ingreso de stock en el ERP contable** |
| `GET` | `/pie-camion/{id}/pdf` | el informe (con el termógrafo fusionado) |
| `POST` `DELETE` `GET` | `/pie-camion/{id}/termografo-pdf` | subir / borrar / bajar el termógrafo |
| `GET` | `/pie-camion/{id}/documentacion-pdf` | los A4 escaneados |
| `POST` | `/pie-camion/{id}/reclamo` | crear el reclamo al proveedor |
| `PUT` | `/pie-camion/{id}/reclamo` | rehacer el reclamo |
| `GET` | `/pie-camion/por-codigo?cod=` | buscar por `codigo_importador_camion` |
| `GET` | `/pie-camion/etiqueta-qr?cod=` | el SVG del QR de la etiqueta |
| `POST` | `/pie-camion/etiqueta-impresa` | registrar una impresión Zebra |
| `GET` | `/pie-camion/etiqueta-camion?placa=&fecha=` | el código asociado a ese camión |
| `GET` | `/pie-camion/requisitos` | config del agrónomo (todas las frutas) |
| `GET` | `/pie-camion/requisitos/aplicables?cods=` | los requisitos de las frutas presentes en esa mercadería |
| `PUT` | `/pie-camion/requisitos/{categoria}` | ABM del agrónomo (permiso `pie_requisitos_config`) |

### El `POST /pie-camion` en detalle

Es **un solo request con todo**: datos, líneas, defectos, cámaras, requisitos,
fotos categorizadas, galería libre y documentación escaneada. Está pensado así
porque se llena offline en el celular y se manda de una.

Las imágenes viajan como **data URI o base64 puro** dentro del JSON. El cliente
las comprime a ~300 KB; el back descarta las que superan 2 MB por seguridad.
No hay tope de cantidad.

**Mandá `client_ref`** (un UUID generado por el cliente y guardado en el
borrador). Si el mismo pie llega dos veces, el back devuelve el existente en vez
de duplicar el camión. Sin señal estable en el depósito, esto no es opcional.

Efectos del create, además de guardar:

1. genera el informe PDF, el PDF de fotos y el de documentación → S3
2. pasa la carga del Plan a `Descargado`
3. dispara el webhook de maduración (tarea de fondo, best-effort)

### `POST /pie-camion/{id}/confirmar`

El único endpoint que **escribe en el ERP contable**. Requiere el permiso
`ingreso_macrosoft`, que se otorga a mano — `stock` y `pie_camion` no alcanzan.

Guardas, en orden:

1. la funcionalidad tiene que estar habilitada por configuración
   (`ingresos_a_macrosoft_habilitado`); si no → **409**
2. tiene que haber un ERP real conectado; en un ambiente de prueba → **403**
   (jamás escribir en el espejo)
3. el pie tiene que estar `pendiente` → si no, **400**
4. tiene que tener líneas → si no, **400**
5. todas las líneas en **un solo depósito** → si no, **400**
6. el depósito tiene que tener documento de ingreso (`B`→ZAC 402, `C`→CR 181)
7. **reserva la fila** antes de escribir en la otra base (protección contra
   doble click / doble pestaña / reintento del navegador)

La fecha del movimiento es **siempre hoy**, no la del pie.

---

## `/plan-cargas`

Permiso `plan_cargas` para el CRUD.

| Método | Path | Qué hace |
|---|---|---|
| `GET` | `/plan-cargas` | listado; filtros por `fuente` (`BR` \| `OTROS`), estado, búsqueda |
| `GET` | `/plan-cargas/{id}` | una carga |
| `POST` | `/plan-cargas` | crear |
| `PATCH` | `/plan-cargas/{id}` | editar (sólo los campos enviados) |
| `DELETE` | `/plan-cargas/{id}` | cancelar; **409** si tiene un Pie de Camión colgando |
| `GET` | `/plan-cargas/export.xlsx` | export a Excel |
| `GET` | `/plan-cargas/sync/estado` | estado del puente con OneDrive, por fuente |
| `POST` | `/plan-cargas/sync?force=` | forzar la bajada |
| `GET` | `/plan-cargas/carpetas` | carpetas de importación, con `cargado`/`saldo` calculados |
| `POST` `PATCH` `DELETE` | `/plan-cargas/carpetas[/{id}]` | ABM de carpetas |
| `GET` | `/plan-cargas/facturas` | facturas conocidas |
| `GET` | `/plan-cargas/factura-datos?factura=` | autollenado: carpeta, exportador, frontera, transportista, AFIDI |

> Con el puente de OneDrive activo, la edición se bloquea: la fuente de verdad
> es el Excel maestro.

---

## `/monitor-camiones`

| Método | Path | Qué hace |
|---|---|---|
| `GET` | `/monitor-camiones` | sólo `Frontera` y `Liberado`, ordenados para la TV |

Acceso: **token de kiosko** (`?k=…`) o IP conocida → sin login. Si no, requiere
sesión. Es lo que permite dejar una pantalla colgada en el depósito.

---

## `/venta` y `/ventas-articulos`

Están documentados aparte, en [`07-ventas.md`](07-ventas.md) §8.

---

## Permisos que aparecen

| Permiso | Alcance |
|---|---|
| `pie_camion` | crear y operar pies |
| `recepcion` | el equipo que firma "descarga autorizada" / "inspección realizada" |
| `stock` | la pantalla de Ingresos: lee pies pendientes, baja PDF |
| `consulta` | buscador universal — su pestaña de QR lee el pie por código |
| `pie_requisitos_config` | el ABM del ingeniero agrónomo |
| `ingreso_macrosoft` | **escribir el ingreso en el ERP contable** (se da a mano) |
| `plan_cargas` | CRUD del Plan y de las carpetas |
| `monitor_camiones` | ver el Monitor estando logueado |
| `venta` | el tomador de pedidos |
| `informe_ventas` / `administracion` | el informe de ventas completo, con Excel |
| `caja` | el informe de ventas en vista acotada |
