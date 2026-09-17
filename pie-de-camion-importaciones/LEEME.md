# Pie de Camión · Importaciones · Ventas — paquete de traspaso

Extracto del ERP de Almar (**Aloha**) con el **circuito completo de la fruta que
viene de afuera**: cómo se planifica la carga en origen, cómo se la sigue hasta
la frontera, cómo se la recibe y controla cuando el camión llega al depósito, y
cómo se vende del otro lado.

```
   ORIGEN (Brasil / Paraguay / Ecuador / Bolivia / …)
        │
        ▼
   ┌──────────────────┐   planilla maestra en OneDrive → espejo en Aloha
   │  PLAN DE CARGAS  │   Solicitado → Confirmado → Frontera → Liberado → Arribado
   └────────┬─────────┘
            │  el camión llega al depósito y alguien lo agarra del Plan
            ▼
   ┌──────────────────┐   control de calidad a pie de camión, con el celular
   │  PIE DE CAMIÓN   │   temperaturas, pesos, calibre, fotos, defectos
   └────────┬─────────┘
            ├──► marca la carga del Plan como "Descargado"
            ├──► genera el informe PDF (reemplaza la planilla de papel)
            ├──► si hay problemas → RECLAMO al proveedor (con fotos)
            ├──► avisa a los dashboards de maduración (qué entró a qué cámara)
            └──► confirma el ingreso de stock al ERP contable (Macrosoft)
                          │
                          │   entra Color 1 (verde) · madura en cámara
                          ▼
   ┌──────────────────┐   el vendedor arma el pedido en la tablet
   │      VENTA       │   y va directo a la cola de caja
   └──────────────────┘   sale Color 4 / 5 (madura)
```

## Por dónde empezar

| Si querés… | Leé |
|---|---|
| Entender el control de calidad del camión | [`docs/01-pie-de-camion.md`](docs/01-pie-de-camion.md) |
| Entender el seguimiento de la carga desde origen | [`docs/02-plan-de-cargas.md`](docs/02-plan-de-cargas.md) |
| Las tablas y los campos | [`docs/03-modelo-de-datos.md`](docs/03-modelo-de-datos.md) |
| Los endpoints de la API | [`docs/04-api.md`](docs/04-api.md) |
| Las listas de proveedores, fronteras, etc. | [`docs/05-datos-de-referencia.md`](docs/05-datos-de-referencia.md) |
| Levantar o reusar el código | [`docs/06-como-reusar-el-codigo.md`](docs/06-como-reusar-el-codigo.md) |
| **Cómo se vende** (tomador, precios, stock por color) | [`docs/07-ventas.md`](docs/07-ventas.md) |

Si sólo vas a leer una cosa técnica, que sea **`docs/07-ventas.md` §4** — el
disponible por color de banana. Es el problema más específico del negocio y la
solución no es la obvia.

## Qué hay en cada carpeta

```
docs/      Los 7 documentos de arriba. Escritos para leerlos de corrido,
           sin necesidad de abrir el código.
datos/     Tablas de referencia en CSV (separador ';', UTF-8 con BOM → abren
           bien en Excel en español): productores, transportistas, fronteras,
           estados de una carga, checklist de fotos, categorías de fruta,
           catálogo de productos con origen, ranking de ventas, mapeo de
           columnas de las planillas maestras.
codigo/    El código real, tal cual está en producción.
           backend/   Python · FastAPI · PostgreSQL (+ SQL Server para el ERP contable)
           frontend/  TypeScript · React
```

## Qué SÍ trae y qué NO — datos reales

Esto es un extracto de un **sistema**, no un volcado de la base. Conviene tenerlo
claro antes de sentarse a comparar números:

| | ¿Está? | Qué hay exactamente |
|---|---|---|
| **Proveedores** | ✅ **sí** | los 57 productores con sus iniciales y los 27 transportistas, tal cual se usan |
| **Fronteras y rutas** | ✅ sí | las 5 fronteras y el ciclo completo de estados de una carga |
| **Catálogo de fruta** | ✅ sí | 51 artículos con código, descripción y país de origen |
| **Qué se vende más** | ✅ sí | los 99 códigos más pedidos, por frecuencia de pedido |
| **Reglas de precio** | ✅ sí | el escalonado y los márgenes del vendedor (−10% / +20%) |
| **Clientes** | ❌ **no** | no hay ninguna lista de clientes. Sólo aparecen 3 nombres sueltos como configuración operativa y una razón social citada en un comentario |
| **Precios reales** | ❌ no | las listas de precios viven en el ERP; acá está la mecánica, no los valores |
| **Facturación / volúmenes** | ❌ no | ni importes, ni kilos, ni cajas por carga, ni márgenes reales |
| **Costos de compra** | ❌ no | nada de lo que se le paga a cada productor |
| **Histórico de cargas** | ❌ no | la tabla del Plan de Cargas va vacía: sólo el esquema |

En una frase: **trae el método y las listas de referencia, no las cifras.** Sirve
para comparar *cómo se trabaja* — qué se controla al recibir un camión, qué
productos y orígenes se manejan, cómo se decide un precio — pero no para
comparar facturación contra nadie.

Si hace falta lo otro (volúmenes, precios, clientes), sale del ERP con una
consulta, no de este paquete.

## Aclaraciones

- **Es un extracto, no un proyecto que arranca solo.** Los módulos dependen del
  resto del ERP (auth, permisos, conexión a base). Sirve como referencia de
  diseño y como fuente para copiar piezas, no como `docker compose up`.
- **No hay credenciales ni bases de datos de clientes.** Sólo esquema, código y
  tablas de referencia.
- **Sí hay información comercial interna**, que va porque es justamente lo que
  sirve: los nombres de productores y transportistas, el ranking de qué se vende
  más, y las reglas de margen del vendedor (−10% / +20%). Si preferís mandar el
  paquete sin eso, ver la nota al final.
- Las decisiones raras están explicadas en comentarios dentro del propio código
  — casi siempre hay un "por qué" con fecha y con el número que lo motivó. Vale
  la pena leerlos.

## Si querés sacar lo comercial antes de mandarlo

Borrá estos y listo:

```
datos/productores.csv
datos/transportistas.csv
datos/ranking-ventas-por-articulo.csv
docs/05-datos-de-referencia.md   (secciones 1, 2 y 10)
docs/07-ventas.md                (sección 2: el escalonado de precios)
codigo/backend/sql/pg_migrations/0023_plan_lookups.sql
codigo/backend/sql/pg_migrations/0050_venta_ranking.sql
codigo/frontend/src/shared/venta/precios.ts
```

El catálogo de productos (`datos/catalogo-productos.csv`) se puede dejar: dice
qué fruta y de qué origen se maneja, que es información de mercado, no un secreto
comercial.
