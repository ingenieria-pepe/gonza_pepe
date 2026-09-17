"""Guardas de upsert_rows del Plan de Cargas (app/scripts/import_plan_cargas.py).

Reglas R095 y R096: el puente OneDrive REEMPLAZA el maestro de su fuente en
cada sync — las guardas son lo único que separa "Excel roto" de "tabla vacía":

- R095: con 0 filas LANZA sin tocar la tabla, y el DELETE del replace es
  scoped por `fuente` (OTROS no pisa a BR) y nunca borra cargas referenciadas
  por un Pie de Camión (FK).
- R096: con fuente≠'BR' y una DB sin la columna `fuente` (ventana de CI: back
  arriba antes de pg_migrate) LANZA — el DELETE sin scope habría vaciado el
  espejo de Brasil entero.
"""
from datetime import date

import pytest

from app.scripts.import_plan_cargas import upsert_rows
from tests import factories
from tests.integration.helpers_expedicion import usuario_db


def _fila(**overrides) -> dict:
    """Record mínimo con la forma que devuelve row_to_record*: los campos que
    upsert_rows lee con .get() pueden faltar; productos va como lista JSONB."""
    base = {"status": "Confirmado", "factura": "FAC-TEST", "productor": "PROD X",
            "fecha_carga": date(2026, 8, 10), "productos": [], "pais_origen": None}
    base.update(overrides)
    return base


def _sembrar_plan(conn, fuente: str, factura: str) -> dict:
    return factories.insertar(conn, "ext.plan_de_cargas",
                              status="Solicitado", factura=factura, fuente=fuente)


def _facturas(conn) -> set[tuple[str, str]]:
    with conn.cursor() as cur:
        cur.execute("SELECT fuente, factura FROM ext.plan_de_cargas")
        return {(f, fac) for f, fac in cur.fetchall()}


def test_cero_filas_lanza_sin_tocar_la_tabla(pg_tx):
    """Regla R095: un Excel vacío/roto parsea 0 filas → ValueError ANTES de
    borrar nada (si no, cada glitch de OneDrive vaciaría el plan)."""
    _sembrar_plan(pg_tx, "BR", "BR-1")

    with pytest.raises(ValueError, match="0 filas"):
        upsert_rows([], replace=True, fuente="BR")

    assert _facturas(pg_tx) == {("BR", "BR-1")}


def test_replace_borra_scoped_por_fuente_y_respeta_la_fk_del_pie(pg_tx):
    """Regla R095: replace de OTROS borra SOLO las filas OTROS sin referencia —
    el maestro de BR queda intacto y la carga OTROS referenciada por un Pie de
    Camión sobrevive (borrarla rompería la FK y el pie perdería su carga)."""
    _sembrar_plan(pg_tx, "BR", "BR-1")
    _sembrar_plan(pg_tx, "OTROS", "OT-VIEJA")
    referenciada = _sembrar_plan(pg_tx, "OTROS", "OT-REF")
    u = usuario_db(pg_tx)
    factories.insertar(
        pg_tx, "ext.pie_de_camion",
        fecha=date(2026, 8, 10), chofer_nombre="CHOFER TEST",
        placa_camion="TEST123", pdf_filename="pie.pdf", pdf_size_bytes=1,
        creado_por_usuario_id=u["id"], plan_carga_id=referenciada["id"],
    )

    res = upsert_rows([_fila(factura="OT-NUEVA-1"), _fila(factura="OT-NUEVA-2")],
                      replace=True, fuente="OTROS")

    assert res["borradas"] == 1          # solo OT-VIEJA
    assert res["insertadas"] == 2
    assert _facturas(pg_tx) == {
        ("BR", "BR-1"),                  # la otra planilla no se toca
        ("OTROS", "OT-REF"),             # referenciada por el pie: sobrevive
        ("OTROS", "OT-NUEVA-1"),
        ("OTROS", "OT-NUEVA-2"),
    }


def test_otros_sin_columna_fuente_lanza_y_no_borra(pg_tx):
    """Regla R096: si la DB todavía no tiene la columna `fuente` (mig 0052 sin
    correr — la ventana CI back-antes-de-migrate), sincronizar la planilla
    OTROS LANZA en vez de caer al DELETE sin scope que vaciaría el espejo de
    Brasil. El próximo ciclo (ya migrado) sincroniza bien."""
    _sembrar_plan(pg_tx, "BR", "BR-1")
    # Simular la DB pre-0052 DENTRO de la transacción del test (DDL en PG es
    # transaccional: el rollback del fixture lo deshace).
    with pg_tx.cursor() as cur:
        cur.execute("ALTER TABLE ext.plan_de_cargas RENAME COLUMN fuente TO fuente_bak")

    with pytest.raises(ValueError, match="fuente"):
        upsert_rows([_fila(factura="OT-X")], replace=True, fuente="OTROS")

    with pg_tx.cursor() as cur:
        cur.execute("SELECT count(*) FROM ext.plan_de_cargas")
        assert cur.fetchone()[0] == 1    # BR-1 sigue ahí, nada borrado
