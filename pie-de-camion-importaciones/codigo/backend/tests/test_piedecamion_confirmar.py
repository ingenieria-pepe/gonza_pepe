"""POST /pie-camion/{id}/confirmar: gates de ingresos a Macrosoft, permiso
propio, documento DERIVADO del depósito (B→402, C→181, nunca 400 — ese es la
pata ZAC de los viajes CR→ZAC), precio de la Lista de Costo, numeración
NroDoc (contador oficial de Documentos) y las DOS transacciones (SQL Server
primero, PG después).

Reglas R313 y R320 del inventario + relevamiento del libro real 21/08. El
lado Macrosoft es un CursorMacrosoft falso patcheado en el namespace del
router — jamás una conexión real (guarda _mssql_prohibido del conftest raíz).
"""
from types import SimpleNamespace

import pytest

from tests.integration.fixtures_http import cliente_http  # noqa: F401
from tests.integration import helpers_piedecamion as h


@pytest.fixture
def entorno(pg_tx, monkeypatch):
    seeds = h.sembrar_entorno(pg_tx)
    seeds["infra"] = h.patch_infra(monkeypatch)
    # Confirmar EXIGE el permiso propio de escritura (21/08). Es un ADD-ON:
    # la puerta del router sigue pidiendo el permiso de módulo (stock/…), así
    # que el back-office real lleva los dos.
    seeds["user"] = h.actor(pg_tx, "ingreso_macrosoft", "stock")
    seeds["solo_stock"] = h.actor(pg_tx, "stock", "pie_camion")
    seeds["recepcion"] = h.actor(pg_tx, "pie_camion")
    return seeds


def _crear_pie(cliente_http, entorno, **body_over) -> int:
    r = cliente_http.como(entorno["recepcion"]).post(
        "/pie-camion", json=h.body_pie(**body_over))
    assert r.status_code == 201, r.text
    return r.json()["id"]


def _abrir_gate(monkeypatch, cursor):
    """Gates prendidos (habilitado + Macrosoft real conectado) + Macrosoft
    falso + dual-write espiado, todo en el namespace del router."""
    import app.modules.piedecamion.router as router_mod

    llamadas_dw: list[tuple] = []
    monkeypatch.setattr(router_mod, "settings", SimpleNamespace(
        ingresos_a_macrosoft_habilitado=True,
        cfe_escribe_macrosoft_real=True,
    ))
    monkeypatch.setattr(router_mod, "get_cfe_cursor", lambda: h.ctx(cursor))
    monkeypatch.setattr(router_mod, "dual_write_ingreso_to_legacy",
                        lambda doc, nf: llamadas_dw.append((doc, nf)))
    return llamadas_dw


class TestGates:
    def test_gate_apagado_por_default_409_sin_tocar_macrosoft(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Regla R313: INGRESOS_A_MACROSOFT_HABILITADO está OFF por default
        (fail-safe) → confirmar devuelve 409 y NO se ejecuta ni un SQL contra
        Macrosoft; el pie sigue pendiente."""
        import app.modules.piedecamion.router as router_mod

        from app.config import settings as settings_reales
        assert settings_reales.ingresos_a_macrosoft_habilitado is False, \
            "el default del gate tiene que ser False (fail-safe)"

        cursor = h.CursorMacrosoft()
        monkeypatch.setattr(router_mod, "get_cfe_cursor", lambda: h.ctx(cursor))
        pid = _crear_pie(cliente_http, entorno)
        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 409
        assert "deshabilitados" in r.json()["detail"]
        assert cursor.ejecutado == []
        assert h.pie_row(pg_tx, pid)["estado"] == "pendiente"

    def test_ambiente_sin_macrosoft_conectado_403(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Guard nuevo (21/08, igual que el movimiento manual): habilitado pero
        SIN CFE_MSSQL_* la conexión caería al espejo/sumidero → 403 sin tocar
        nada. Antes este camino escribía en el espejo."""
        import app.modules.piedecamion.router as router_mod

        cursor = h.CursorMacrosoft()
        monkeypatch.setattr(router_mod, "settings", SimpleNamespace(
            ingresos_a_macrosoft_habilitado=True,
            cfe_escribe_macrosoft_real=False,
        ))
        monkeypatch.setattr(router_mod, "get_cfe_cursor", lambda: h.ctx(cursor))
        pid = _crear_pie(cliente_http, entorno)
        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 403
        assert "no hay Macrosoft conectado" in r.json()["detail"]
        assert cursor.ejecutado == []

    def test_sin_permiso_ingreso_macrosoft_403(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Escribir en el ERP real tiene permiso propio: `stock`+`pie_camion`
        (que antes alcanzaban) ya NO abren el confirmar."""
        cursor = h.CursorMacrosoft()
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno)
        r = cliente_http.como(entorno["solo_stock"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 403
        assert cursor.ejecutado == []
        assert h.pie_row(pg_tx, pid)["estado"] == "pendiente"


class TestDocumentoPorDeposito:
    def test_deposito_b_ingresa_como_402(self, cliente_http, pg_tx, entorno, monkeypatch):
        """ZAC (B) = Ingreso de IMPORTACIÓN ZAC (402) — lo que el back-office
        carga a mano hoy. El Nombre agrupa como los reales y las Observaciones
        llevan la identidad del camión (AFIDI/placa) + el pie."""
        cursor = h.CursorMacrosoft()
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno, numero_afidi="1566463")
        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 200, r.text

        params_cab = cursor.params_de("INSERT INTO Cabezal")
        assert params_cab[1] == "402 "                 # documento derivado, char(4)
        assert params_cab[4] == "INGRESOS DE STOCK"    # Nombre = como los reales
        obs = params_cab[5]
        assert "AFIDI 1566463" in obs and f"Pie #{pid}" in obs
        assert h.pie_row(pg_tx, pid)["ingreso_documento"] == "402"

    def test_deposito_c_ingresa_como_181(self, cliente_http, pg_tx, entorno, monkeypatch):
        """CR (C) = Ingreso de IMPORTACIÓN CR (181) — la familia que faltaba."""
        cursor = h.CursorMacrosoft()
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno, lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 80, "hay_reclamos": False, "deposito": "C"},
        ])
        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 200, r.text
        assert cursor.params_de("INSERT INTO Cabezal")[1] == "181 "
        assert cursor.params_de("UPDATE dbo.Documentos")[1] == "181"
        assert h.pie_row(pg_tx, pid)["ingreso_documento"] == "181"

    def test_documento_del_cliente_que_no_coincide_400(self, cliente_http, entorno, monkeypatch):
        """Compat: un front viejo que mande 400 (o cualquier otro) para un pie
        de ZAC se rechaza — el 400 es de los viajes CR→ZAC, no de camiones."""
        cursor = h.CursorMacrosoft()
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno)
        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={"documento": "400"})
        assert r.status_code == 400
        assert "402" in r.json()["detail"]
        assert cursor.ejecutado == []

    def test_deposito_sin_documento_de_importacion_400(self, cliente_http, entorno, monkeypatch):
        """El Puesto (A) no tiene documento de ingreso de importación."""
        cursor = h.CursorMacrosoft()
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno, lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 10, "hay_reclamos": False, "deposito": "A"},
        ])
        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 400
        assert "'A'" in r.json()["detail"]
        assert cursor.ejecutado == []

    def test_pie_con_dos_depositos_400(self, cliente_http, entorno, monkeypatch):
        """Un ingreso es de UN depósito: líneas en B y C a la vez se rechazan
        antes de tocar Macrosoft."""
        cursor = h.CursorMacrosoft()
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno, lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 10, "hay_reclamos": False, "deposito": "B"},
            {"cod_art": h.COD_PERA, "cantidad": 5, "hay_reclamos": False, "deposito": "C"},
        ])
        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 400
        assert "más de un depósito" in r.json()["detail"]
        assert cursor.ejecutado == []


class TestPrecioListaDeCosto:
    def test_precio_y_total_salen_de_la_lista_de_costo(self, cliente_http, entorno, monkeypatch):
        """La misma regla que el formulario de Macrosoft (verificado 21/08:
        Banana 490 exacto): Precio de Precios TiposPrecios=1 y TotalLinea =
        cantidad × costo. Artículo sin costo cargado → 0, como los reales."""
        cursor = h.CursorMacrosoft(precios={h.COD_BANANA: 490.0})
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno, lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 100, "hay_reclamos": False},
            {"cod_art": h.COD_PERA, "cantidad": 50, "hay_reclamos": False},
        ])
        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 200, r.text

        lineas_ins = [p for s, p in cursor.ejecutado if "INSERT INTO Lineas" in s]
        assert len(lineas_ins) == 2
        por_cod = {p[5].strip(): p for p in lineas_ins}
        banana = por_cod[h.COD_BANANA]
        assert (banana[9], banana[10]) == (490.0, 49_000.0)   # Precio, TotalLinea
        pera = por_cod[h.COD_PERA]
        assert (pera[9], pera[10]) == (0.0, 0.0)              # sin costo cargado
        assert all(p[11] == "A" for p in lineas_ins)          # entrada


class TestNumeracionNroDoc:
    def test_contador_oficial_mas_uno_en_cabezal_y_lineas(self, cliente_http, pg_tx, entorno, monkeypatch):
        """NroDoc = contador oficial de Documentos + 1, escrito igual en
        Cabezal y en cada línea, y el contador queda actualizado en la MISMA
        transacción DESPUÉS de los INSERT — ahora sobre el 402 derivado."""
        cursor = h.CursorMacrosoft(ultimo_usado=1751, next_nro_fact=90_001)
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno, lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 100, "hay_reclamos": False},
            {"cod_art": h.COD_PERA, "cantidad": 50, "hay_reclamos": False},
        ])
        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 200, r.text

        # Lee el contador oficial (dbo.Documentos con UPDLOCK), no un MAX pelado.
        assert cursor.params_de("ultimo_usado") is not None
        assert cursor.params_de("INSERT INTO Cabezal")[3] == "1752"
        lineas_ins = [p for s, p in cursor.ejecutado if "INSERT INTO Lineas" in s]
        assert len(lineas_ins) == 2
        assert all(p[3] == "1752" for p in lineas_ins)
        assert cursor.params_de("UPDATE dbo.Documentos") == (1752, "402")

        sqls = cursor.sqls()
        pos_linea = max(i for i, s in enumerate(sqls) if "INSERT INTO Lineas" in s)
        pos_update = next(i for i, s in enumerate(sqls) if "UPDATE dbo.Documentos" in s)
        assert pos_update > pos_linea

    def test_documento_inexistente_en_macrosoft_400(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Si dbo.Documentos no tiene la fila del tipo, 400 sin insertar nada
        y el pie queda pendiente."""
        cursor = h.CursorMacrosoft(ultimo_usado=None)
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno)
        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 400
        assert "INSERT INTO Cabezal" not in " ".join(cursor.sqls())
        assert h.pie_row(pg_tx, pid)["estado"] == "pendiente"


class TestDosTransacciones:
    def test_confirmar_ok_estado_meta_y_link_del_reclamo(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Regla R320 (camino feliz): tras el commit de Macrosoft, PG guarda la
        metadata (ext.movimiento_stock_meta), marca el pie ingresado y linkea el
        reclamo post-hoc al movimiento (documento/nro_fact)."""
        cursor = h.CursorMacrosoft(ultimo_usado=10, next_nro_fact=91_234)
        dw = _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno, motivo_id=entorno["motivo_id"])
        reclamo_id = h.pie_row(pg_tx, pid)["reclamo_id"]
        assert h.reclamo_row(pg_tx, reclamo_id)["documento"] is None

        r = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={"documento": "402"})
        assert r.status_code == 200, r.text

        fila = h.pie_row(pg_tx, pid)
        assert fila["estado"] == "ingresado"
        assert fila["ingreso_documento"] == "402"
        assert fila["ingreso_nro_fact"] == 91_234
        assert fila["confirmado_por_usuario_id"] == entorno["user"].id
        with pg_tx.cursor() as cur:
            cur.execute("SELECT usuario_id FROM ext.movimiento_stock_meta "
                        "WHERE documento = '402' AND nro_fact = %s", (91_234,))
            assert cur.fetchone() == (entorno["user"].id,)
        reclamo = h.reclamo_row(pg_tx, reclamo_id)
        assert (reclamo["documento"], reclamo["nro_fact"]) == ("402", 91_234)
        assert dw == [("402 ", 91_234)]     # dual-write con el char(4) padded

    def test_si_pg_no_responde_macrosoft_no_se_toca(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Desde la mig 0112 la RESERVA en PG va PRIMERO, así que un PG caído ya
        no puede dejar un ingreso huérfano en Macrosoft: no se escribe nada.

        Antes era al revés (Macrosoft primero) y este mismo test verificaba la
        inconsistencia resultante como un hecho de la vida."""
        import app.modules.piedecamion.router as router_mod

        cursor = h.CursorMacrosoft()
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno)

        def _pg_caido():
            raise RuntimeError("PG no responde")

        monkeypatch.setattr(router_mod, "get_cursor", _pg_caido)
        with pytest.raises(RuntimeError):
            cliente_http.como(entorno["user"]).post(
                f"/pie-camion/{pid}/confirmar", json={})

        assert cursor.sqls() == [], "se escribió en Macrosoft con PG caído"
        fila = h.pie_row(pg_tx, pid)
        assert (fila["estado"], fila["ingreso_nro_fact"]) == ("pendiente", None)

    def test_el_segundo_click_no_crea_un_segundo_ingreso(self, cliente_http, pg_tx, entorno, monkeypatch):
        """EL error caro de la madrugada: el pie queda reservado antes de tocar
        Macrosoft, así que el segundo request corta con 409 SIN escribir.

        Se simula el caso real —dos requests con el primero a mitad de camino—
        dejando la reserva puesta y el pie todavía 'pendiente'."""
        cursor = h.CursorMacrosoft()
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno)
        with pg_tx.cursor() as cur:
            cur.execute("UPDATE ext.pie_de_camion SET confirmando_en = now() WHERE id = %s", (pid,))

        r = cliente_http.como(entorno["user"]).post(f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 409
        assert "NO reintentes" in r.json()["detail"]
        assert cursor.sqls() == [], "el segundo click escribió en Macrosoft"

    def test_si_macrosoft_falla_la_reserva_se_libera_y_se_puede_reintentar(
            self, cliente_http, pg_tx, entorno, monkeypatch):
        """Si Macrosoft no commiteó no hay nada que revisar: el pie tiene que
        quedar libre para reintentar. Reservado-para-siempre por un error de red
        obligaría a tocar la base a mano."""
        class _Explota(h.CursorMacrosoft):
            def execute(self, sql, params=None):
                raise RuntimeError("Macrosoft no responde")

        _abrir_gate(monkeypatch, _Explota())
        pid = _crear_pie(cliente_http, entorno)
        with pytest.raises(RuntimeError):
            cliente_http.como(entorno["user"]).post(f"/pie-camion/{pid}/confirmar", json={})

        fila = h.pie_row(pg_tx, pid)
        assert fila["estado"] == "pendiente"
        assert fila["confirmando_en"] is None, "la reserva quedó trabada tras un fallo de Macrosoft"

    def test_confirmar_dos_veces_400(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Regla R320: re-confirmar un pie ya ingresado se corta con 400 antes
        de tocar Macrosoft (no duplica el movimiento)."""
        cursor = h.CursorMacrosoft()
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno)
        r1 = cliente_http.como(entorno["user"]).post(
            f"/pie-camion/{pid}/confirmar", json={})
        assert r1.status_code == 200, r1.text
        n_sqls = len(cursor.ejecutado)

        r2 = cliente_http.post(f"/pie-camion/{pid}/confirmar", json={})
        assert r2.status_code == 400
        assert len(cursor.ejecutado) == n_sqls


class TestFechaDelIngreso:
    """La fecha del ingreso es HOY, siempre (dueño 1/09).

    Los camiones se ingresan al momento de descargarlos, nunca días después.
    Antes la fecha salía del campo `fecha` del pie, que era tipeable: el 1/09
    alguien copió la fecha PLANIFICADA de la carpeta (29/08) y el movimiento de
    stock quedó imputado tres días atrás — el total daba bien, pero caía en un
    período cerrado y ensuciaba la conciliación.
    """

    def test_el_movimiento_se_fecha_hoy_aunque_el_pie_diga_otra_cosa(
            self, cliente_http, pg_tx, entorno, monkeypatch):
        from datetime import date, timedelta

        cursor = h.CursorMacrosoft()
        _abrir_gate(monkeypatch, cursor)
        pid = _crear_pie(cliente_http, entorno)
        # Un pie con la fecha de la carpeta, tres días atrás (el caso real).
        viejo = date.today() - timedelta(days=3)
        with pg_tx.cursor() as cur:
            cur.execute("UPDATE ext.pie_de_camion SET fecha = %s WHERE id = %s", (viejo, pid))

        r = cliente_http.como(entorno["user"]).post(f"/pie-camion/{pid}/confirmar", json={})
        assert r.status_code == 200, r.text

        # La fecha que viajó al INSERT del Cabezal es la de hoy, no la del pie.
        params = cursor.params_de("INSERT INTO Cabezal")
        assert params, "no se encontró el INSERT del Cabezal"
        assert params[0].date() == date.today(), (
            f"el ingreso salió fechado {params[0].date()} y el pie decía {viejo}"
        )
