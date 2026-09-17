# Modelo de datos

PostgreSQL, schema `ext`. El SQL está en `codigo/backend/sql/`:

- `00_schema_base_pie_y_plan.sql` — las tablas base
- `pg_migrations/` — las migraciones incrementales, en orden numérico
- `sqlserver_migrations/` — la versión original en SQL Server (histórico; el
  módulo nació ahí y después se migró a Postgres)

---

## 1. Mapa

```
                 ext.plan_de_cargas
                 (un camión planificado)
                          │
                          │ plan_carga_id
                          ▼
                 ext.pie_de_camion  ────────────► ext.reclamo
                 (la recepción)      reclamo_id        │
                     │  │  │  │                        ▼
     ┌───────────────┘  │  │  └──────────┐        ext.reclamo_linea
     ▼                  ▼  ▼             ▼
  _linea            _producto        _camara       _foto
  (mercadería)      (prod+marca)   (dónde entró)  (imágenes)
     │
     ▼
  _defecto ──────► ext.defecto_motivo


   ext.pie_requisito ──────► ext.pie_requisito_respuesta
   (config del agrónomo)     (lo que se respondió, snapshoteado)


   Lookups del Plan:  ext.productor · ext.transportista · ext.frontera
                      ext.chofer · ext.carpeta_import
   Etiquetas Zebra:   ext.etiqueta_camion
```

---

## 2. Las tablas

### `ext.plan_de_cargas`
Un camión planificado. Ver [`02-plan-de-cargas.md`](02-plan-de-cargas.md) para el
detalle de campos y estados.

Índices: `status`, `fecha_descarga`, `fecha_frontera` — que es exactamente por
lo que filtra el Monitor y el listado.

### `ext.pie_de_camion`
La cabecera de la recepción. Es una tabla ancha a propósito: las mediciones
(temperatura, peso, calibración, longitud × 3 posiciones × 2 tomas) son un
formulario fijo, no una relación. Ver [`01-pie-de-camion.md`](01-pie-de-camion.md).

Columnas que se fueron agregando y conviene conocer:

| Columna | Migración | Para qué |
|---|---|---|
| `plan_carga_id` | 0019 | link a la carga del Plan |
| `fecha_carga` | 0034 | cuándo se cargó en origen (≠ fecha de descarga) |
| `descargado_en` | 0036 | marca "revisado", al bajar la planilla desde Ingresos |
| `doc_pdf_*` | 0038 | PDF de la documentación A4 escaneada |
| `productor` | 0039 | quién produjo la fruta |
| `termografo_pdf_*` | 0042 | el PDF del termógrafo, fusionado al informe |
| `editado_*` | 0044 | trazabilidad de ediciones |
| `client_ref` | 0058 | **idempotencia** — UUID del celular |
| `fotos_anexo_*` | 0069 | fotos agregadas después de enviar |
| `hay_reclamos` | 0071 | respuesta obligatoria "¿hay reclamos?" |
| `confirmando_en` | 0112 | **reserva** antes de escribir en el ERP contable |
| `pdf_s3_key`, `fotos_pdf_*` | 0033, 0055, 0056 | los PDF viven en S3, no en la base |

> **Los PDF migraron a S3** (mig 0033/0055/0056): al principio se guardaban como
> `VARBINARY(MAX)` en la tabla. Con fotos de camión eso infla la base y los
> backups muy rápido. Ahora la fila guarda la key de S3 y el tamaño.

### `ext.pie_de_camion_linea`
La mercadería: `cod_art`, `deposito`, `cantidad`, `marca`, `hay_reclamos`
(mig 0072). `ON DELETE CASCADE` desde el pie.

### `ext.pie_de_camion_producto`
Los pares producto + marca del camión. Existe por compatibilidad: el modelo
original tenía un solo `producto` en la cabecera (mig 0016 lo abrió a varios).
Los campos viejos siguen ahí y el back cae a ellos si esta tabla está vacía.

### `ext.pie_de_camion_defecto`
Por línea: `motivo_id` (→ `ext.defecto_motivo`), `cantidad`, `notas`, fotos.

### `ext.pie_de_camion_camara` (mig 0040, ampliada en 0045)
A qué cámara de maduración entró la fruta: `ubicacion` (`ZAC`/`CR`), `numero`,
`cantidad` (cajas, `NULL` = todo el camión) y `cod_art` (mig 0045: en un reparto
con varios productos, cada fila es una asignación producto→cámara).

### `ext.pie_de_camion_foto` (mig 0018, 0043)
Las imágenes. `categoria` (slug estable, ej. `fruta_medio_corona`) + `caption`
(el título que va al PDF) + `orden`. La 0043 agregó la categoría; antes eran
sólo una galería sin estructura.

### `ext.pie_requisito` / `ext.pie_requisito_respuesta` (mig 0092)
La configuración del agrónomo y las respuestas. La tabla de respuestas
**duplica** `tipo`, `etiqueta` y `unidad` a propósito: es el snapshot que
protege el histórico de los cambios de configuración.

### `ext.reclamo` / `ext.reclamo_linea`
El reclamo al proveedor. `reclamo.pie_camion_id` va **sin FK**, para evitar el
ciclo con `pie_de_camion.reclamo_id` (mismo criterio que tenía en SQL Server).

### `ext.etiqueta_camion` (mig 0073)
Deja el código de importador asociado al camión (placa + fecha) cuando se
imprimen las etiquetas Zebra, para que el celular no tenga que re-tipearlo.

### Lookups (mig 0023)
`ext.productor` (nombre + iniciales), `ext.transportista`, `ext.frontera`,
`ext.chofer` (nombre + celular), `ext.carpeta_import`. Los datos están en
`datos/*.csv` — ver [`05-datos-de-referencia.md`](05-datos-de-referencia.md).

### Tablas de Venta
`ext.venta_vendedor`, `ext.venta_envio`, `ext.venta_producto_ranking`,
`ext.pedido_agregado`, `ext.pedido_prioridad`, `ext.producto_cambio`,
`ext.producto_escritura_envio` (migraciones 0048, 0050, 0062, 0095, 0114).
Detalladas en [`07-ventas.md`](07-ventas.md) §9.

---

## 3. Convenciones que se repiten

- **Nada se borra: se cancela o se desactiva.** Las cargas se cancelan
  (`status = 'Cancelado'`); los requisitos se desactivan (`activo = false`). El
  `DELETE` real de una carga se rechaza con 409 si tiene un Pie de Camión
  colgando.
- **Todo lleva `creado_en` / `creado_por_usuario_id`** y, donde hay edición,
  `actualizado_*`.
- **Los `ON DELETE CASCADE` van de la cabecera hacia sus hijos** (líneas,
  productos, cámaras, fotos, respuestas). Borrar un pie limpia todo lo suyo.
- **Los enums viven en Pydantic, no en CHECK constraints.** Es a propósito:
  aparecen valores nuevos seguido (estados de carga sobre todo) y no vale una
  migración cada vez.
- **Snapshot > referencia** para lo que se muestra históricamente. Se repite en
  requisitos, y también en otros módulos del ERP.
