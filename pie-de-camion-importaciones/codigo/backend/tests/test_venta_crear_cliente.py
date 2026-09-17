"""Alta de cliente (26/08): el mínimo real de Macrosoft.

Código autogenerado ref=MAX+2 → cod=ref*100+1; nace Activo (quirk: el estado
vive en Localidad), C/lista 2/UYU. El INSERT a Macrosoft se mockea (patrón de
venta); el dual-write al espejo corre contra PG real.
"""
import pytest
from fastapi import HTTPException

from app.config import settings
from app.modules.venta import router as vr
from app.modules.venta.schemas import ClienteCreate
from tests import factories
from tests.integration.helpers_expedicion import usuario_db


class _FakeMssqlCursor:
    """Registra los execute; MAX devuelve 2372901 (el real de prod al 26/08)."""

    def __init__(self):
        self.ejecutados = []
        self._ultimo = None

    def execute(self, sql, params=()):
        self.ejecutados.append((sql, params))
        self._ultimo = sql

    def fetchone(self):
        if "MAX(CodCliente)" in self._ultimo:
            return {"max_cod": 2372901}
        return None  # EXISTS: no colisión


@pytest.fixture
def mssql(monkeypatch):
    fake = _FakeMssqlCursor()

    class _Ctx:
        def __enter__(self):
            return fake

        def __exit__(self, *a):
            return False

    monkeypatch.setattr(vr, "get_venta_cursor", lambda: _Ctx())
    monkeypatch.setattr(settings, "venta_mssql_host", "mssql-fake-test")
    return fake


def test_alta_minima_codigo_y_convenciones(pg_tx, mssql):
    out = vr.crear_cliente(ClienteCreate(nombre="VERDULERIA DON JOSE"))
    # ref = 23729+2 = 23731 → cod = 2373101 (patrón <ref>01 medido en las 3.834)
    assert out.cod == 2373101

    insert = next(e for e in mssql.ejecutados if "INSERT INTO Clientes" in e[0])
    assert "'Activo'" in insert[0]            # el ESTADO vive en Localidad (quirk)
    assert "'C', 1, 2, 'A'" in insert[0]      # cliente común: C / flia 1 / lista 2
    cod, ref, nombre, fantasia, ruc, dire, tel = insert[1]
    assert (cod, ref, nombre) == (2373101, 23731, "VERDULERIA DON JOSE")
    assert fantasia == "VERDULERIA DON JOSE"  # sin fantasía → repite el nombre
    assert ruc is None and dire is None and tel is None

    # Dual-write: el picker lo ve al instante en el espejo.
    with pg_tx.cursor() as cur:
        cur.execute("SELECT BTRIM(nombre), BTRIM(localidad) FROM legacy.clientes "
                    "WHERE codcliente = %s", (out.cod,))
        assert cur.fetchone() == ("VERDULERIA DON JOSE", "Activo")


def test_alta_con_rut_y_datos(pg_tx, mssql):
    out = vr.crear_cliente(ClienteCreate(
        nombre="ABRIL SAS", ruc="220917250017", nombre_fantasia="LO DE ABRIL",
        direccion="Cno. Repetto 1234", telefono="091234567",
    ))
    insert = next(e for e in mssql.ejecutados if "INSERT INTO Clientes" in e[0])
    assert insert[1][3:] == ("LO DE ABRIL", "220917250017", "Cno. Repetto 1234", "091234567")
    assert out.nombre == "ABRIL SAS"


def test_sin_macrosoft_real_403(pg_tx, monkeypatch):
    monkeypatch.setattr(settings, "venta_mssql_host", None)
    with pytest.raises(HTTPException) as e:
        vr.crear_cliente(ClienteCreate(nombre="NO DEBERIA ENTRAR"))
    assert e.value.status_code == 403


def test_colision_de_codigo_409(pg_tx, mssql, monkeypatch):
    monkeypatch.setattr(
        _FakeMssqlCursor, "fetchone",
        lambda self: {"max_cod": 2372901} if "MAX" in self._ultimo else {"x": 1},
    )
    with pytest.raises(HTTPException) as e:
        vr.crear_cliente(ClienteCreate(nombre="CHOQUE"))
    assert e.value.status_code == 409
