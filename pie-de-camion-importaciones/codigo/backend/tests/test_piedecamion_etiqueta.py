"""Etiquetas Zebra: ext.etiqueta_camion (clave placa+fecha) y las rutas
literales del router de pie de camión declaradas ANTES de /{pdc_id}.

Reglas R311 y R310 del inventario.
"""
from datetime import date

import pytest

from tests.integration.fixtures_http import cliente_http  # noqa: F401
from tests.integration import helpers_piedecamion as h


@pytest.fixture
def entorno(pg_tx, monkeypatch):
    seeds = h.sembrar_entorno(pg_tx)
    seeds["infra"] = h.patch_infra(monkeypatch)
    seeds["user"] = h.actor(pg_tx, "pie_camion")
    return seeds


def _filas_etiqueta(conn, placa: str) -> list[tuple]:
    with conn.cursor() as cur:
        cur.execute("SELECT placa, BTRIM(codigo), cantidad, plan_carga_id "
                    "FROM ext.etiqueta_camion WHERE placa = %s", (placa,))
        return cur.fetchall()


class TestEtiquetaCamion:
    def test_upsert_por_placa_fecha_la_ultima_impresion_pisa(self, cliente_http, pg_tx, entorno):
        """Regla R311: ext.etiqueta_camion es única por (placa normalizada,
        fecha) — re-imprimir con otro código PISA (vale el papel que quedó
        pegado en los pallets), nunca duplica."""
        hoy = date.today().isoformat()
        r1 = cliente_http.como(entorno["user"]).post("/pie-camion/etiqueta-impresa", json={
            "placa": "  ab123cd ", "fecha": hoy, "codigo": "mk017", "cantidad": 20})
        assert r1.status_code == 200, r1.text
        assert r1.json()["placa"] == "AB123CD"     # normalizada UPPER+BTRIM
        assert r1.json()["codigo"] == "MK017"

        r2 = cliente_http.post("/pie-camion/etiqueta-impresa", json={
            "placa": "AB123CD", "fecha": hoy, "codigo": "EXOTICO", "cantidad": 8})
        assert r2.status_code == 200
        filas = _filas_etiqueta(pg_tx, "AB123CD")
        assert len(filas) == 1, "el upsert duplicó la etiqueta del camión"
        assert filas[0][1] == "EXOTICO" and filas[0][2] == 8

    def test_plan_carga_id_es_informativo_y_no_se_pierde(self, cliente_http, pg_tx, entorno):
        """Regla R311: plan_carga_id NUNCA es clave (el puente OneDrive regenera
        los ids cada 30s) — y una re-impresión sin plan no borra el que había
        (COALESCE)."""
        hoy = date.today().isoformat()
        cliente_http.como(entorno["user"]).post("/pie-camion/etiqueta-impresa", json={
            "placa": "XY999", "fecha": hoy, "codigo": "A1", "plan_carga_id": 424242})
        cliente_http.post("/pie-camion/etiqueta-impresa", json={
            "placa": "XY999", "fecha": hoy, "codigo": "A2"})
        filas = _filas_etiqueta(pg_tx, "XY999")
        assert len(filas) == 1
        assert filas[0][1] == "A2"
        assert filas[0][3] == 424242, "la re-impresión sin plan borró el link informativo"

    def test_indice_unico_placa_fecha_existe(self, pg_tx, entorno):
        """Regla R311: el candado es un índice ÚNICO (placa, fecha) en la DB."""
        with pg_tx.cursor() as cur:
            cur.execute("""
                SELECT indexdef FROM pg_indexes
                WHERE schemaname = 'ext' AND tablename = 'etiqueta_camion'
                  AND indexname = 'etiqueta_camion_placa_fecha_uq'
            """)
            fila = cur.fetchone()
        assert fila and "UNIQUE" in fila[0]

    def test_get_precarga_por_placa_y_fecha(self, cliente_http, entorno):
        """Regla R311: el celular pre-carga el código con GET /etiqueta-camion
        (placa+fecha); sin impresión devuelve null."""
        hoy = date.today().isoformat()
        cliente_http.como(entorno["user"]).post("/pie-camion/etiqueta-impresa", json={
            "placa": "PRE111", "fecha": hoy, "codigo": "FH-044"})
        r = cliente_http.get(f"/pie-camion/etiqueta-camion?placa=pre111&fecha={hoy}")
        assert r.status_code == 200 and r.json()["codigo"] == "FH-044"
        r2 = cliente_http.get(f"/pie-camion/etiqueta-camion?placa=NUNCA&fecha={hoy}")
        assert r2.status_code == 200 and r2.json() is None

    def test_placa_o_codigo_vacios_400(self, cliente_http, entorno):
        """Regla R311: sin placa o sin código no hay asociación que guardar."""
        r = cliente_http.como(entorno["user"]).post("/pie-camion/etiqueta-impresa", json={
            "placa": "   ", "fecha": date.today().isoformat(), "codigo": "X1"})
        assert r.status_code == 400


class TestRutasLiterales:
    def test_rutas_literales_no_las_captura_pdc_id(self, cliente_http, pg_tx, entorno):
        """Regla R310: /etiqueta-qr, /por-codigo, /etiqueta-camion declaradas
        ANTES de /{pdc_id} — si el orden se rompe, FastAPI las captura como id y
        devuelven 422 (int parse) en vez de funcionar."""
        c = cliente_http.como(entorno["user"])
        r = c.get("/pie-camion/etiqueta-qr?cod=mk017")
        assert r.status_code == 200 and "<svg" in r.json()["svg"]

        r = c.get("/pie-camion/por-codigo?cod=NOEXISTE")
        assert r.status_code == 200 and r.json() == []

        r = c.get(f"/pie-camion/etiqueta-camion?placa=Z&fecha={date.today().isoformat()}")
        assert r.status_code == 200

    def test_por_codigo_encuentra_el_pie_por_su_codigo(self, cliente_http, entorno):
        """Regla R310/R309 (parcial): el QR CÓDIGO|PLACA|FECHA resuelve al pie
        cargado con ese código de importador."""
        body = h.body_pie(codigo_importador_camion="MK017")
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 201, r.text
        pid = r.json()["id"]
        placa, fecha = body["placa_camion"], body["fecha"]

        res = cliente_http.get(f"/pie-camion/por-codigo?cod=MK017|{placa}|{fecha}")
        assert res.status_code == 200
        assert [p["id"] for p in res.json()] == [pid]
