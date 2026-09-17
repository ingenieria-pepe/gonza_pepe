"""SQL para PlanDeCargas (CRUD + monitor) — contra PostgreSQL (ext.plan_de_cargas)."""

# Columnas data en orden — usado por INSERT y dump al frontend.
DATA_COLUMNS: list[str] = [
    "carga_semana", "status", "factura", "productor",
    "fecha_carga", "carpeta_import", "afidi",
    "transportista", "exportador", "placa_camion", "placa_remolque",
    "chofer", "celular",
    "fecha_frontera", "frontera", "inspector_mgap", "fecha_descarga",
    "tt", "cajas_mic", "cajas_desc", "cant_pallet", "cant_kilos_caja",
    "codigo_viaje", "mic",
    "observaciones",
    "productos", "pais_origen", "fuente",
]

# SELECT base con joins a Usuarios para mostrar quién creó/actualizó.
_SELECT_BASE = """
SELECT p.id, p.creado_en, p.actualizado_en,
       u_c.nombre AS creado_por_nombre, u_c.username AS creado_por_username,
       u_a.nombre AS actualizado_por_nombre, u_a.username AS actualizado_por_username,
       {cols}
FROM ext.plan_de_cargas p
LEFT JOIN ext.usuarios u_c ON u_c.id = p.creado_por_usuario_id
LEFT JOIN ext.usuarios u_a ON u_a.id = p.actualizado_por_usuario_id
"""


def select_data_cols_sql() -> str:
    return ", ".join(f"p.{c}" for c in DATA_COLUMNS)


def build_insert_sql() -> str:
    cols = DATA_COLUMNS + ["creado_por_usuario_id", "actualizado_por_usuario_id"]
    placeholders = ", ".join(["%s"] * len(cols))
    return f"""
INSERT INTO ext.plan_de_cargas ({", ".join(cols)})
VALUES ({placeholders})
RETURNING id
"""


def build_get_by_id_sql() -> str:
    return _SELECT_BASE.format(cols=select_data_cols_sql()) + " WHERE p.id = %s"


# LIST genérico — los filtros van por params en Python (más legible que SQL dinámico).
# NULLS FIRST replica el orden de SQL Server (NULL primero en ASC).
LIST_SQL = _SELECT_BASE.format(cols=select_data_cols_sql()) + """
WHERE 1=1
  /* filtros se insertan acá */
ORDER BY
    -- pendientes primero (los del monitor),
    -- después por fecha de descarga estimada (más cercanos arriba),
    -- y si no hay fecha de descarga, por fecha frontera.
    CASE WHEN p.status IN ('Solicitado','Confirmado','Cargado','Mar','Puerto','Frontera','Liberado','Arribado')
         THEN 0 ELSE 1 END,
    COALESCE(p.fecha_descarga, p.fecha_frontera) ASC NULLS FIRST,
    p.id DESC
"""


# Monitor de camiones: SÓLO Frontera y Liberado.
# - "Frontera": llegó a frontera, en trámite — la recepción tiene que
#               estar lista para cuando crucen.
# - "Liberado": salió de frontera, ya viene en ruta al depósito.
# Los Solicitados/Confirmados son demasiado prematuros (los planificamos
# pero no aportan a la operación inmediata). Arribado/Descargado ya están
# en el depósito y se manejan desde Pie de Camión.
MONITOR_SQL = _SELECT_BASE.format(cols=select_data_cols_sql()) + """
WHERE p.status IN ('Frontera','Liberado')
ORDER BY
    -- Liberado primero — están más cerca de llegar
    CASE p.status
        WHEN 'Liberado' THEN 0
        WHEN 'Frontera' THEN 1
    END,
    COALESCE(p.fecha_descarga, p.fecha_frontera) ASC NULLS FIRST,
    p.id DESC
"""


def build_update_sql(columns_to_update: list[str]) -> str:
    """PATCH dinámico — sólo updateamos las columnas que vinieron en el body."""
    sets = ", ".join(f"{c} = %s" for c in columns_to_update)
    return f"""
UPDATE ext.plan_de_cargas
SET {sets},
    actualizado_en = now(),
    actualizado_por_usuario_id = %s
WHERE id = %s
"""


DELETE_SQL = "DELETE FROM ext.plan_de_cargas WHERE id = %s"

CANCEL_SQL = """
UPDATE ext.plan_de_cargas
SET status = 'Cancelado',
    actualizado_en = now(),
    actualizado_por_usuario_id = %s
WHERE id = %s
"""

# Control de carpetas con cargado/saldo calculados en vivo (como el Excel viejo):
#   cargado = SUMA de cajas_mic del plan de cargas con la MISMA factura.
#   saldo   = Qtde − cargado, pero 0 si |dif| < 20 (tolerancia del Excel).
# El SELECT se comparte entre el listado y el "traer una" (post-insert/update).
_CARPETAS_SELECT = """
SELECT c.id, c.fecha, c.carpeta, c.factura, c.exportador, c.frontera, c.transportista,
       c.cantidad, COALESCE(p.cargado, 0) AS cargado,
       CASE WHEN c.cantidad IS NULL THEN NULL
            WHEN abs(c.cantidad - COALESCE(p.cargado, 0)) < 20 THEN 0
            ELSE c.cantidad - COALESCE(p.cargado, 0) END AS saldo,
       c.afidi, c.dua
FROM ext.carpeta_import c
LEFT JOIN (
    SELECT btrim(factura) AS f, SUM(cajas_mic) AS cargado
    FROM ext.plan_de_cargas
    WHERE COALESCE(btrim(factura), '') <> ''
    GROUP BY btrim(factura)
) p ON p.f = btrim(c.factura)
"""

CARPETAS_SQL = _CARPETAS_SELECT + "\nORDER BY c.fecha DESC NULLS LAST, c.id DESC\n"
CARPETA_ONE_SQL = _CARPETAS_SELECT + "\nWHERE c.id = %s\n"

# Columnas editables de una carpeta (cargado/saldo se calculan, NO se guardan acá).
CARPETA_COLS: list[str] = [
    "fecha", "factura", "carpeta", "exportador", "frontera",
    "transportista", "cantidad", "afidi", "dua",
]


def build_carpeta_insert_sql() -> str:
    placeholders = ", ".join(["%s"] * len(CARPETA_COLS))
    return (
        f"INSERT INTO ext.carpeta_import ({', '.join(CARPETA_COLS)}) "
        f"VALUES ({placeholders}) RETURNING id"
    )


def build_carpeta_update_sql(cols: list[str]) -> str:
    sets = ", ".join(f"{c} = %s" for c in cols)
    return f"UPDATE ext.carpeta_import SET {sets} WHERE id = %s"


CARPETA_DELETE_SQL = "DELETE FROM ext.carpeta_import WHERE id = %s"

# Datos que se repiten para una misma factura (para autollenar el form): carpeta,
# exportador, frontera, transportista, afidi. NO trae productor (eso cambia por
# carga). Primero la carpeta de importación; si no está, la última carga del plan.
FACTURA_DATOS_CARPETA_SQL = """
SELECT carpeta AS carpeta_import, exportador, frontera, transportista, afidi
FROM ext.carpeta_import
WHERE btrim(factura) = btrim(%s)
ORDER BY fecha DESC NULLS LAST, id DESC
LIMIT 1
"""

FACTURA_DATOS_PLAN_SQL = """
SELECT carpeta_import, exportador, frontera, transportista, afidi
FROM ext.plan_de_cargas
WHERE btrim(factura) = btrim(%s)
ORDER BY creado_en DESC
LIMIT 1
"""

# Facturas conocidas (carpetas + plan) para el combobox del form.
FACTURAS_SQL = """
SELECT btrim(factura) AS factura FROM ext.carpeta_import WHERE COALESCE(btrim(factura), '') <> ''
UNION
SELECT btrim(factura) FROM ext.plan_de_cargas WHERE COALESCE(btrim(factura), '') <> ''
ORDER BY 1
"""
