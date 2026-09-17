"""
Importa el master de Plan de Cargas (CSV exportado del Drive) a ext.plan_de_cargas.

El CSV es "PROGRAMA DE CARGAS EN BRASIL" (separado por ';', con BOM, 3 filas de
título antes del header). Mapea por NOMBRE de columna, parsea fechas dd-mm-yy,
enteros y decimales (coma), limpia placeholders (xx / #N/D / vacío → NULL) y
trunca a los largos de cada VARCHAR.

Uso:
    # DRY-RUN (no escribe): muestra qué cargaría
    python -m app.scripts.import_plan_cargas actualizado.csv

    # Cargar SUMANDO a lo que ya hay (no borra nada):
    python -m app.scripts.import_plan_cargas actualizado.csv --commit

    # Reemplazar (sync al master del Drive). NO borra las cargas referenciadas
    # por un Pie de Camión (romperían la FK pie_de_camion.plan_carga_id); el resto sí:
    python -m app.scripts.import_plan_cargas actualizado.csv --commit --replace

La parte de parseo es stdlib pura → el DRY-RUN corre sin DB ni psycopg2.
La conexión (app.pg) se importa recién al hacer --commit.
"""
import csv
import datetime
import re
import sys

# 'Cargado'/'Puerto'/'Mar'/'Destruida' vienen de la planilla de OTROS países
# (lo de ultramar viaja en barco). Sincronizar con StatusCarga (plan_cargas/schemas.py)
# y con el front (shared/api/planCargas.ts).
VALID_STATUS = {
    "Solicitado", "Confirmado", "Cargado", "Frontera", "Liberado",
    "Puerto", "Mar", "Arribado", "Descargado", "Cancelado", "Destruida",
}
# La planilla OTROS escribe el status a mano ('DESCARGADO', 'descargado'...) →
# normalizamos case-insensitive al valor canónico.
_CANON_STATUS = {s.lower(): s for s in VALID_STATUS}
JUNK = {"", "xx", "#n/d", "s/d", "-", "--", "n/d"}


def _status(v) -> str:
    st = _clean(v)
    if isinstance(st, str):
        return _CANON_STATUS.get(st.strip().lower(), "Solicitado")
    return "Solicitado"

# Mapa índice-de-columna-CSV → campo de la tabla. (19 es una columna vacía; se
# saltea. "productos" no es columna de la tabla todavía — se carga sólo si existe.)
IDX = {
    0: "carga_semana", 1: "status", 2: "factura", 3: "productor", 4: "fecha_carga",
    5: "carpeta_import", 6: "afidi", 7: "transportista", 8: "exportador",
    9: "fecha_frontera", 10: "frontera", 11: "productos", 12: "fecha_descarga",
    13: "tt", 14: "cajas_mic", 15: "cajas_desc", 16: "cant_pallet",
    17: "cant_kilos_caja", 18: "codigo_viaje", 20: "mic", 21: "placa_camion",
    22: "placa_remolque", 23: "chofer", 24: "celular", 25: "observaciones",
}

# Largos de los VARCHAR (para truncar y no romper el INSERT). observaciones es TEXT.
LIMITS = {
    "carga_semana": 20, "status": 30, "factura": 30, "productor": 100,
    "carpeta_import": 40, "afidi": 300, "transportista": 100, "exportador": 150,
    "placa_camion": 30, "placa_remolque": 30, "chofer": 100, "celular": 40,
    "frontera": 50, "codigo_viaje": 40, "mic": 40, "productos": 200,
    "pais_origen": 60, "inspector_mgap": 100,
}

# ── Planilla de OTROS países ("PROGRAMA DE ARRIBOS", hoja Cargas) ──────────
# Mismo espíritu que la de Brasil pero con OTRO orden de columnas: acá el país
# de origen ES una columna (en BR se carga a mano), el producto va en la col 3
# (no hay "Productor"), no hay chofer/celular, y hay una sola columna de placas.
# La col 15 ('Cannt Camiones') no tiene campo en la tabla → se saltea.
OTROS_IDX = {
    0: "carga_semana",      # 'Desc. Sem.#'
    1: "status",            # 'Status List'
    2: "factura",
    3: "productos",         # 'Productos' (texto → lista JSONB de 1)
    4: "fecha_carga",
    5: "carpeta_import",
    6: "pais_origen",       # 'Pais origen' (código: EC/CL/BO/PE/CO/MX/AR/GR/EG/ES/IT…)
    7: "afidi",
    8: "transportista",
    9: "exportador",
    10: "fecha_frontera",
    11: "frontera",
    12: "fecha_descarga",
    13: "tt",
    14: "cajas_mic",        # 'Cajas'
    16: "cajas_desc",       # 'Cajas Descargadas'
    17: "cant_pallet",
    18: "cant_kilos_caja",
    19: "inspector_mgap",   # 'MGAP'
    20: "mic",              # 'MIC / CONTENEDOR'
    21: "codigo_viaje",
    22: "placa_camion",     # 'PLACAS T'
    23: "observaciones",
}

# Orden de columnas para el INSERT (sin id/creado_en/etc → usan defaults).
INSERT_COLS = [
    "carga_semana", "status", "factura", "productor", "fecha_carga",
    "carpeta_import", "afidi", "transportista", "exportador", "placa_camion",
    "placa_remolque", "chofer", "celular", "fecha_frontera", "frontera",
    "inspector_mgap", "fecha_descarga", "tt", "cajas_mic", "cajas_desc",
    "cant_pallet", "cant_kilos_caja", "codigo_viaje", "mic", "observaciones",
]


# Los limpiadores aceptan tanto strings (CSV) como valores YA tipados (openpyxl
# devuelve datetime/int/float al leer el .xlsx). Así el mismo mapeo sirve para el
# import por CSV y para el puente que lee el .xlsx de OneDrive.
def _clean(v):
    if v is None:
        return None
    if isinstance(v, str):
        s = v.strip()
        return None if s.lower() in JUNK else s
    return v  # ya tipado (datetime/int/float) → pasa tal cual


def _date(v) -> datetime.date | None:
    if isinstance(v, datetime.datetime):
        return v.date()
    if isinstance(v, datetime.date):
        return v
    s = _clean(v)
    if not isinstance(s, str) or not s:
        return None
    m = re.match(r"^(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})$", s)
    if not m:
        return None
    d, mo, y = int(m[1]), int(m[2]), int(m[3])
    if y < 100:
        y += 2000
    try:
        return datetime.date(y, mo, d)
    except ValueError:
        return None


def _int(v) -> int | None:
    s = _clean(v)
    if isinstance(s, bool):
        return int(s)
    if isinstance(s, (int, float)):
        return int(s)
    if not isinstance(s, str) or not s:
        return None
    s2 = s.replace(".", "").replace(" ", "")
    return int(s2) if re.match(r"^-?\d+$", s2) else None


def _float(v) -> float | None:
    s = _clean(v)
    if isinstance(s, bool):
        return float(s)
    if isinstance(s, (int, float)):
        return float(s)
    if not isinstance(s, str) or not s:
        return None
    s2 = s.replace(".", "").replace(",", ".").replace(" ", "")
    try:
        return float(s2)
    except ValueError:
        return None


def _txt(field: str, v) -> str | None:
    s = _clean(v)
    if s is None:
        return None
    if not isinstance(s, str):
        s = str(s)
    lim = LIMITS.get(field)
    return s[:lim] if lim else s


def _map_row(cells, idx: dict[int, str]) -> dict:
    """Una fila de datos (lista de celdas, por índice) → record mapeado y limpio.
    `cells` puede ser strings (CSV) o valores tipados (openpyxl)."""
    def g(i):
        return cells[i] if i < len(cells) else None
    rec: dict = {"inspector_mgap": None}
    for i, field in idx.items():
        v = g(i)
        if field in ("fecha_carga", "fecha_frontera", "fecha_descarga"):
            rec[field] = _date(v)
        elif field in ("tt", "cajas_mic", "cajas_desc", "cant_pallet"):
            rec[field] = _int(v)
        elif field == "cant_kilos_caja":
            rec[field] = _float(v)
        elif field == "status":
            rec[field] = _status(v)
        else:
            rec[field] = _txt(field, v)
    p = rec.get("productos")  # UN producto (texto) → lista JSONB de 1
    rec["productos"] = [{"descripcion": p}] if p else []
    return rec


def row_to_record(cells) -> dict:
    """Fila de la planilla de BRASIL (ver IDX)."""
    rec = _map_row(cells, IDX)
    rec["pais_origen"] = None  # en la planilla BR no viene → se carga a mano
    return rec


def fila_valida_otros(cells) -> bool:
    """Filtra la basura al pie de la hoja OTROS (separadores '|', leyendas tipo
    'Si las letras están en color Rojo…', celdas sueltas): una fila es una carga
    REAL si su status crudo es reconocible o si tiene fecha de carga. Sin esto,
    esas filas caían al default 'Solicitado' y aparecían como cargas fantasma
    arriba de todo en el tab (orden NULLS FIRST)."""
    def g(i):
        return cells[i] if i < len(cells) else None
    st = _clean(g(1))
    if isinstance(st, str) and st.strip().lower() in _CANON_STATUS:
        return True
    return _date(g(4)) is not None


def row_to_record_otros(cells) -> dict:
    """Fila de la planilla de OTROS países (ver OTROS_IDX)."""
    rec = _map_row(cells, OTROS_IDX)
    # Campos que esa planilla no tiene:
    rec.setdefault("productor", None)
    rec.setdefault("placa_remolque", None)
    rec.setdefault("chofer", None)
    rec.setdefault("celular", None)
    # País como código en mayúsculas ('Ar' → 'AR').
    if rec.get("pais_origen"):
        rec["pais_origen"] = rec["pais_origen"].upper()
    return rec


def parse_csv(path: str) -> list[dict]:
    """CSV → filas mapeadas y limpias (stdlib pura, sin DB)."""
    with open(path, encoding="utf-8-sig", newline="") as f:
        rows = list(csv.reader(f, delimiter=";"))
    hdr_idx = next(i for i, r in enumerate(rows) if "Status" in r)
    data = [r for r in rows[hdr_idx + 1:] if any(c.strip() for c in r)]
    return [row_to_record(r) for r in data]


def upsert_rows(rows: list[dict], replace: bool, fuente: str = "BR") -> dict:
    """Inserta las filas en ext.plan_de_cargas con la `fuente` dada ('BR'|'OTROS').
    replace=True reemplaza el maestro de ESA fuente (no toca las filas de la otra
    planilla) SIN borrar las cargas referenciadas por un Pie de Camión (romperían
    la FK). Devuelve contadores. Usado por el CLI (--commit) y por el puente de
    OneDrive."""
    if not rows:
        raise ValueError("0 filas: no se toca la tabla (evita borrar todo por un Excel vacío/roto).")
    from app.pg import get_conn  # noqa: PLC0415 — lazy: el dry-run no necesita DB
    import psycopg2.extras  # noqa: PLC0415

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM ext.plan_de_cargas")
            antes = cur.fetchone()[0]
            cur.execute("SELECT count(*) FROM ext.pie_de_camion WHERE plan_carga_id IS NOT NULL")
            refs = cur.fetchone()[0]

            extras = []
            for c in ("productos", "pais_origen", "fuente"):
                cur.execute(
                    "SELECT 1 FROM information_schema.columns WHERE table_schema='ext' "
                    "AND table_name='plan_de_cargas' AND column_name=%s",
                    (c,),
                )
                if cur.fetchone():
                    extras.append(c)
            cols = INSERT_COLS + extras

            # DB sin migrar (0052, columna fuente): SOLO se admite el flujo viejo
            # (BR). Con fuente='OTROS' el DELETE sin scope borraría TODO el espejo
            # de Brasil (ventana real: el CI levanta el back ANTES de pg_migrate y
            # el sync_loop arranca al toque) → mejor fallar este ciclo; el próximo
            # (ya migrado) sincroniza bien.
            if fuente != "BR" and "fuente" not in extras:
                raise ValueError(
                    "ext.plan_de_cargas todavía no tiene la columna 'fuente' "
                    "(migración 0052) — no se puede sincronizar la planilla OTROS."
                )

            borradas = 0
            if replace:
                if "fuente" in extras:
                    cur.execute(
                        "DELETE FROM ext.plan_de_cargas WHERE fuente = %s AND id NOT IN "
                        "(SELECT plan_carga_id FROM ext.pie_de_camion WHERE plan_carga_id IS NOT NULL)",
                        (fuente,),
                    )
                else:  # DB sin migrar → comportamiento viejo (todo es BR)
                    cur.execute(
                        "DELETE FROM ext.plan_de_cargas WHERE id NOT IN "
                        "(SELECT plan_carga_id FROM ext.pie_de_camion WHERE plan_carga_id IS NOT NULL)"
                    )
                borradas = cur.rowcount

            valores = [
                [psycopg2.extras.Json(r[c]) if c == "productos"
                 else fuente if c == "fuente"
                 else r.get(c)
                 for c in cols]
                for r in rows
            ]
            psycopg2.extras.execute_values(
                cur,
                f"INSERT INTO ext.plan_de_cargas ({', '.join(cols)}) VALUES %s",
                valores,
                page_size=500,
            )
        conn.commit()
    return {"antes": antes, "refs": refs, "borradas": borradas, "insertadas": len(rows)}


def main(argv: list[str]) -> int:
    flags = {a for a in argv if a.startswith("--")}
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    rows = parse_csv(path)

    print(f"Filas parseadas: {len(rows)}")
    con_fecha = sum(1 for r in rows if r["fecha_carga"])
    con_prod = sum(1 for r in rows if r.get("productos"))
    print(f"  con fecha_carga: {con_fecha} | con productos: {con_prod}")
    print("Muestra (últimas 2):")
    for r in rows[-2:]:
        print("  ", {k: v for k, v in r.items() if v not in (None, "")})

    if "--commit" not in flags:
        print("\nDRY-RUN — no se escribió nada. Agregá --commit para cargar.")
        return 0

    res = upsert_rows(rows, replace="--replace" in flags)
    print(f"Antes: {res['antes']} filas ({res['refs']} referenciadas por Pie de Camión).")
    if "--replace" in flags:
        print(f"REEMPLAZO: borradas {res['borradas']} (se conservaron las {res['refs']} referenciadas).")
    else:
        print("APPEND: se suman sin borrar (pasá --replace para reemplazar).")
    print(f"OK — insertadas {res['insertadas']} filas en ext.plan_de_cargas.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
