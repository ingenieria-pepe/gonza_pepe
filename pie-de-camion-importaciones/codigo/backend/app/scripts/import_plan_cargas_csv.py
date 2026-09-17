"""
Importa el CSV del Excel de OneDrive (Plan de Cargas BR/PY) a ext.plan_de_cargas.

Uso:
    # Append (idempotente por factura+carpeta+fecha — salta duplicados):
    docker compose exec -T back python -m app.scripts.import_plan_cargas_csv /ruta/plan.csv

    # Reemplazar TODO el plan por el contenido del CSV (lo que pidió el user
    # para arrancar a usar sólo la app y dejar el Excel):
    docker compose exec -T back python -m app.scripts.import_plan_cargas_csv /ruta/plan.csv --reemplazar

Cómo funciona:
    - Lee el CSV en utf-8-sig (export nuevo) con fallback a cp1252 (export viejo
      de Windows). Separador `;`.
    - Sólo toma filas cuyo Status (col 1) sea uno de los válidos — eso saltea
      las 3 filas de encabezado y las filas vacías/separadoras automáticamente.
    - Mapea columnas del CSV → columnas DB (ver CSV_TO_DB).
    - --reemplazar: NULLea pie_de_camion.plan_carga_id (para no romper FKs),
      borra todo ext.plan_de_cargas y bulk-inserta el CSV. Sin flag: append con
      dedup por (factura, carpeta_import, fecha_carga).
"""
import csv
import sys
from datetime import datetime
from pathlib import Path

import psycopg2.extras

from app.pg import fetch_one, get_cursor


# Mapping CSV index → nombre de columna DB
CSV_TO_DB: dict[int, str] = {
    0: "carga_semana",
    1: "status",
    2: "factura",
    3: "productor",
    4: "fecha_carga",
    5: "carpeta_import",
    6: "afidi",
    7: "transportista",
    8: "exportador",
    9: "fecha_frontera",
    10: "frontera",
    11: "inspector_mgap",
    12: "fecha_descarga",
    13: "tt",
    14: "cajas_mic",
    15: "cajas_desc",
    16: "cant_pallet",
    17: "cant_kilos_caja",
    18: "codigo_viaje",
    20: "mic",
    21: "placa_camion",
    22: "placa_remolque",
    23: "chofer",
    24: "celular",
    25: "observaciones",
}

VALID_STATUS = {
    "Solicitado", "Confirmado", "Frontera", "Liberado", "Arribado",
    "Descargado", "Cancelado",
}

DATE_COLS = {"fecha_carga", "fecha_frontera", "fecha_descarga"}
INT_COLS = {"tt", "cajas_mic", "cajas_desc", "cant_pallet"}
FLOAT_COLS = {"cant_kilos_caja"}

# Largo máximo por columna (= el VARCHAR del schema). El Excel a veces mete
# valores más largos de lo que la columna admite (ej. varias placas/facturas
# juntas) — truncamos para no romper el INSERT. observaciones es TEXT → sin tope.
MAXLEN = {
    "carga_semana": 20, "status": 30, "factura": 30, "productor": 100,
    "carpeta_import": 40, "afidi": 300, "transportista": 100, "exportador": 150,
    "placa_camion": 30, "placa_remolque": 30, "chofer": 100, "celular": 40,
    "frontera": 50, "inspector_mgap": 100, "codigo_viaje": 40, "mic": 40,
}

DB_COLS = list(CSV_TO_DB.values())


def _parse_date(s: str) -> str | None:
    """CSV usa DD-MM-YY. Devolvemos ISO YYYY-MM-DD (string), o None."""
    s = (s or "").strip()
    if not s or s in {"#N/D", "0", "xx"}:
        return None
    for fmt in ("%d-%m-%y", "%d/%m/%y", "%d-%m-%Y", "%d/%m/%Y"):
        try:
            return datetime.strptime(s, fmt).date().isoformat()
        except ValueError:
            continue
    return None


def _parse_int(s: str) -> int | None:
    s = (s or "").strip()
    if not s or s in {"#N/D", "xx"}:
        return None
    s = s.replace(".", "").replace(",", "")
    try:
        return int(s)
    except ValueError:
        return None


def _parse_float(s: str) -> float | None:
    s = (s or "").strip()
    if not s or s in {"#N/D", "xx"}:
        return None
    s = s.replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None


def _clean_str(s: str | None) -> str | None:
    if not s:
        return None
    s = s.strip()
    if not s or s in {"#N/D", "0"}:
        return None
    return s


def _row_to_db(row: list[str]) -> dict | None:
    """Convierte una fila CSV a dict listo para INSERT. None si la fila no tiene
    un Status válido (eso descarta encabezados y filas vacías)."""
    if len(row) < 2 or row[1].strip() not in VALID_STATUS:
        return None

    out: dict = {}
    for csv_idx, db_col in CSV_TO_DB.items():
        raw = row[csv_idx] if csv_idx < len(row) else ""
        if db_col in DATE_COLS:
            out[db_col] = _parse_date(raw)
        elif db_col in INT_COLS:
            out[db_col] = _parse_int(raw)
        elif db_col in FLOAT_COLS:
            out[db_col] = _parse_float(raw)
        else:
            v = _clean_str(raw)
            limit = MAXLEN.get(db_col)
            out[db_col] = v[:limit] if (v and limit) else v
    return out


def _read_rows(path: Path) -> list[dict]:
    for encoding in ("utf-8-sig", "cp1252"):
        try:
            with path.open(encoding=encoding) as f:
                raw = list(csv.reader(f, delimiter=";"))
            break
        except UnicodeDecodeError:
            continue
    else:
        raise RuntimeError("No pude decodificar el CSV (probé utf-8-sig y cp1252)")

    out = []
    for r in raw:
        d = _row_to_db(r)
        if d is not None:
            out.append(d)
    return out


EXISTS_SQL = """
SELECT id FROM ext.plan_de_cargas
WHERE COALESCE(factura,'') = %s
  AND COALESCE(carpeta_import,'') = %s
  AND (fecha_carga = %s OR (fecha_carga IS NULL AND %s IS NULL))
LIMIT 1
"""


def _append(rows: list[dict]) -> tuple[int, int]:
    cols = ", ".join(DB_COLS)
    placeholders = ", ".join(["%s"] * len(DB_COLS))
    insert_sql = f"INSERT INTO ext.plan_de_cargas ({cols}) VALUES ({placeholders})"
    inserted = skipped = 0
    with get_cursor() as cur:
        for data in rows:
            if fetch_one(EXISTS_SQL, (
                data.get("factura") or "",
                data.get("carpeta_import") or "",
                data.get("fecha_carga"),
                data.get("fecha_carga"),
            )):
                skipped += 1
                continue
            cur.execute(insert_sql, tuple(data.get(c) for c in DB_COLS))
            inserted += 1
    return inserted, skipped


def _reemplazar(rows: list[dict]) -> int:
    cols = ", ".join(DB_COLS)
    insert_sql = f"INSERT INTO ext.plan_de_cargas ({cols}) VALUES %s"
    values = [tuple(d.get(c) for c in DB_COLS) for d in rows]
    with get_cursor() as cur:
        # NULLear FKs de pie_de_camion para poder borrar las cargas viejas.
        cur.execute("UPDATE ext.pie_de_camion SET plan_carga_id = NULL WHERE plan_carga_id IS NOT NULL")
        nulled = cur.rowcount
        cur.execute("DELETE FROM ext.plan_de_cargas")
        deleted = cur.rowcount
        psycopg2.extras.execute_values(cur, insert_sql, values, page_size=500)
    print(f"  Pies de camión des-linkeados (plan_carga_id → NULL): {nulled}")
    print(f"  Cargas viejas borradas: {deleted}")
    return len(values)


def main() -> int:
    args = sys.argv[1:]
    reemplazar = "--reemplazar" in args
    paths = [a for a in args if not a.startswith("--")]
    if not paths:
        print("Uso: python -m app.scripts.import_plan_cargas_csv <ruta.csv> [--reemplazar]", file=sys.stderr)
        return 1
    path = Path(paths[0])
    if not path.exists():
        print(f"No encuentro el archivo: {path}", file=sys.stderr)
        return 1

    rows = _read_rows(path)
    print(f"Filas con status válido detectadas: {len(rows)}")
    if not rows:
        print("Nada para importar.", file=sys.stderr)
        return 1

    if reemplazar:
        n = _reemplazar(rows)
        print(f"✓ Reemplazo completo: {n} cargas en ext.plan_de_cargas.")
    else:
        inserted, skipped = _append(rows)
        print(f"✓ Insertadas:    {inserted}")
        print(f"  Saltadas (ya existían): {skipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
