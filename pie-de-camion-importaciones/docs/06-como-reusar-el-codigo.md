# Cómo reusar el código

**Esto es un extracto, no un proyecto que arranca solo.** Los módulos dependen
del resto del ERP (autenticación, permisos, conexión a base, generación de PDF
compartida, S3). Sirve como referencia de diseño y como fuente para copiar
piezas.

---

## 1. Qué hay

```
codigo/backend/
  app/modules/piedecamion/
    router.py        endpoints + toda la lógica del create/editar/confirmar
    schemas.py       el contrato completo del formulario (Pydantic)
    queries.py       el SQL
    pdf.py           el generador del informe (ReportLab)
    webhook.py       el aviso a los dashboards de maduración
    publico.py       el QR de la etiqueta
  app/modules/plan_cargas/
    router.py · schemas.py · queries.py · onedrive_sync.py
  app/modules/venta/
    router.py · schemas.py · queries.py
    stock_colores.py              ← el disponible por color de banana
  app/modules/informes/
    ventas_articulos.py · router_ventas_articulos.py · excel.py
  app/core/categorias.py          categorías de fruta + íconos
  app/backfill_pie_split.py       migración de PDF viejos (histórico)
  app/scripts/import_plan_cargas*.py

  sql/00_schema_base_pie_y_plan.sql
  sql/pg_migrations/              31 migraciones incrementales (PostgreSQL)
  sql/sqlserver_migrations/       7 migraciones originales (SQL Server)

  tests/                          24 archivos de test

codigo/frontend/
  src/modules/piedecamion/
    PieDeCamionPage.tsx           el formulario (grande)
    fotoCategorias.ts             ← el checklist de fotos, fuente de verdad
    components/                   picker de carga, fotos, requisitos, anexos
  src/modules/plan-cargas/PlanCargasPage.tsx
  src/modules/monitor-camiones/MonitorCamionesPage.tsx
  src/modules/venta/              NuevoPedidoPage · PedidosPage · VendedoresPage
  src/modules/ventasart/          el informe de ventas por artículo
  src/shared/api/piecamion.ts · planCargas.ts   los tipos del contrato con el back
  src/shared/origen.ts                          extracción del origen de la descripción
  src/shared/venta/precios.ts                   el escalonado −10% / +20%
```

---

## 2. Stack

**Backend** — Python 3.11+, FastAPI, PostgreSQL (`psycopg2`) + SQL Server
(`pymssql`, sólo para escribir el ingreso en el ERP contable).

Dependencias que usan estos módulos en concreto:

```
fastapi · uvicorn · pydantic · psycopg2-binary · pymssql
reportlab      informe PDF
pypdf          fusionar el termógrafo al informe
Pillow         procesar las fotos
openpyxl       leer los .xlsx maestros y exportar
httpx          el webhook de maduración
boto3          los PDF en S3
qrcode         el QR de la etiqueta
```

**Frontend** — React 18 + TypeScript + Vite + Tailwind, `@tanstack/react-query`,
`react-router-dom`, `jsqr` (escaneo de QR desde la cámara). Tests con Vitest +
Testing Library.

---

## 3. Piezas que se pueden llevar sueltas

Estas no dependen de casi nada y valen por sí solas:

| Archivo | Qué te llevás | Dependencias |
|---|---|---|
| `frontend/src/modules/piedecamion/fotoCategorias.ts` | el checklist de fotos completo, con orden canónico | ninguna |
| `frontend/src/shared/origen.ts` | extraer el origen de una descripción de producto | ninguna (+ su test) |
| `backend/app/core/categorias.py` | 44 categorías de fruta con sus sinónimos | sólo stdlib |
| `backend/app/scripts/import_plan_cargas.py` | parser de las dos planillas maestras | stdlib para el parseo (el dry-run corre **sin base**) |
| `backend/app/modules/piedecamion/pdf.py` | la planilla digital en PDF | `reportlab` |
| `frontend/src/shared/venta/precios.ts` | el escalonado de precio con paradas y límites | ninguna (+ su test) |
| `backend/app/modules/venta/stock_colores.py` | el disponible por color de banana anclado al conteo | la base (pero el método se lee solo) |
| `backend/sql/*` | el esquema entero | PostgreSQL |

---

## 4. Configuración que usan estos módulos

Variables de entorno (sin valores; poner los propios):

```dotenv
# Puente con las planillas maestras. Vacío = apagado.
PLAN_CARGAS_SYNC_URL=            # planilla BR (Brasil/Paraguay)
PLAN_CARGAS_OTROS_SYNC_URL=      # planilla OTROS (demás países)

# Webhook de maduración (una URL por ubicación). Sin token = apagado.
# ...ver app/config.py del proyecto original

# Escritura del ingreso en el ERP contable
INGRESOS_A_MACROSOFT_HABILITADO=false
CFE_MSSQL_...=                   # sin esto, el confirmar rechaza con 403
```

> **La guarda del ambiente es deliberada.** Si no hay ERP real conectado, el
> `confirmar` devuelve **403** en vez de escribir. Nunca hay que dejar que un
> ambiente de prueba escriba en el espejo: es la única forma de que un servidor
> de testing no invente movimientos de stock.

---

## 5. Tests

`codigo/backend/tests/` — 24 archivos (11 del pie/plan, 13 de venta). Los de
integración necesitan la base y los fixtures del proyecto original; los
unitarios (`test_piedecamion_pdfs`, `test_piedecamion_webhook_bes`,
`test_venta_*` de cálculo, `test_stock_venta_pasante`) son más autónomos.

Se corren con `pytest` desde la raíz del backend.

El front tiene tests de DOM junto a los componentes (`*.dom.test.tsx`) y de
lógica pura (`fotoCategorias.test.ts`, `origen.test.ts`); estos últimos corren
con `vitest` sin nada más.

---

## 6. Cómo leer el código

Casi todas las decisiones raras están explicadas **en el propio código**, con un
comentario que dice *por qué* y muchas veces con fecha y con el número que lo
motivó ("836 de 836 líneas están en B", "el melón del 3/09 costó cuatro
conteos"). Si algo parece innecesariamente complicado, buscá el comentario antes
de simplificarlo — suele haber un incidente atrás.

Orden sugerido de lectura:

1. `piedecamion/schemas.py` — es el contrato completo del formulario y se lee
   como una descripción del proceso
2. `frontend/src/modules/piedecamion/fotoCategorias.ts` — corto y explica el
   checklist entero
3. `plan_cargas/schemas.py` — los estados y su significado
4. `plan_cargas/onedrive_sync.py` — corto, y muestra cómo se hace un puente
   read-only con un Excel sin romper nada
5. `venta/stock_colores.py` — corto y es el mejor ejemplo de cómo se razona un
   número que el ERP no puede dar
6. `piedecamion/router.py` — el más largo; entrar directo a
   `_create_pie_camion_impl` y a `confirmar_ingreso`
7. `venta/router.py` — entrar por `crear_pedido` y `stock_disponible`
