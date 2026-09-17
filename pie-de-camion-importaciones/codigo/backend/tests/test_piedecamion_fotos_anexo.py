"""POST /pie-camion/{id}/fotos: anexar fotos a un pie YA enviado — el merge se
verifica por páginas y aborta la tx si no cierra.

Regla R273 (y el camino feliz del anexo, R288 parcial) del inventario.
"""
import pytest

from tests.integration.fixtures_http import cliente_http  # noqa: F401
from tests.integration import helpers_piedecamion as h


@pytest.fixture
def entorno(pg_tx, monkeypatch):
    seeds = h.sembrar_entorno(pg_tx)
    seeds["infra"] = h.patch_infra(monkeypatch)
    seeds["user"] = h.actor(pg_tx, "pie_camion")
    return seeds


def _crear_con_fotos(cliente_http, entorno, n=2) -> int:
    r = cliente_http.como(entorno["user"]).post("/pie-camion", json=h.body_pie(
        fotos=[h.data_uri(h.jpeg(color=(50 * i % 255, 90, 90))) for i in range(n)]))
    assert r.status_code == 201, r.text
    return r.json()["id"]


class TestAnexoVerificado:
    def test_anexo_ok_suma_paginas_y_audita(self, cliente_http, pg_tx, entorno):
        """Regla R288 (parcial): el anexo agrega páginas al fotos-PDF (las
        anteriores quedan) y deja la auditoría fotos_anexos_n/anexo_por."""
        pid = _crear_con_fotos(cliente_http, entorno)
        antes = h.pie_row(pg_tx, pid)
        p_antes = h.paginas(antes["fotos_pdf_blob"])
        assert p_antes >= 1 and antes["fotos_anexos_n"] in (0, None)

        r = cliente_http.post(f"/pie-camion/{pid}/fotos", json={
            "fotos": [h.data_uri(h.jpeg(color=(10, 200, 10)))],
            "nota": "pallet del fondo",
        })
        assert r.status_code == 200, r.text
        assert r.json()["fotos_agregadas"] == 1
        despues = h.pie_row(pg_tx, pid)
        assert h.paginas(despues["fotos_pdf_blob"]) > p_antes
        assert despues["fotos_anexos_n"] == 1
        assert despues["fotos_anexo_por"] == entorno["user"].id

    def test_merge_que_no_cierra_aborta_sin_perder_nada(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Regla R273: merge_pdfs es best-effort (devuelve solo la base si algo
        falla) — acá eso sería perder las fotos nuevas EN SILENCIO después de
        decir "listo". El anexo verifica por cantidad de páginas y aborta la tx:
        500 con mensaje claro y la DB intacta."""
        import app.modules.piedecamion.router as router_mod

        pid = _crear_con_fotos(cliente_http, entorno)
        antes = h.pie_row(pg_tx, pid)

        # merge "fallado": devuelve SOLO la base (el modo de falla real).
        monkeypatch.setattr(router_mod, "merge_pdfs", lambda base, extra: base)
        r = cliente_http.post(f"/pie-camion/{pid}/fotos", json={
            "fotos": [h.data_uri(h.jpeg())]})
        assert r.status_code == 500
        assert "No se cambió nada" in r.json()["detail"]
        despues = h.pie_row(pg_tx, pid)
        assert bytes(despues["fotos_pdf_blob"]) == bytes(antes["fotos_pdf_blob"])
        assert (despues["fotos_anexos_n"] or 0) == (antes["fotos_anexos_n"] or 0)

    def test_sin_fotos_validas_400(self, cliente_http, entorno):
        """Regla R273 (borde): un body sin ninguna foto decodificable → 400 sin
        tocar el pie."""
        pid = _crear_con_fotos(cliente_http, entorno)
        r = cliente_http.post(f"/pie-camion/{pid}/fotos", json={"fotos": ["   "]})
        assert r.status_code == 400

    def test_pie_viejo_sin_fotos_pdf_arma_el_suyo_primero(self, cliente_http, pg_tx, entorno):
        """Regla R273/R287: anexar a un pie VIEJO (fotos como filas, sin
        fotos-PDF) arma primero el PDF de las originales — el anexo no se las
        come."""
        from tests import factories

        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=h.body_pie())
        pid = r.json()["id"]
        blob = h.jpeg()
        factories.insertar(pg_tx, "ext.pie_de_camion_foto",
                           pie_camion_id=pid, foto_blob=blob,
                           size_bytes=len(blob), orden=0)

        r = cliente_http.post(f"/pie-camion/{pid}/fotos", json={
            "fotos": [h.data_uri(h.jpeg(color=(0, 0, 250)))]})
        assert r.status_code == 200, r.text
        final = h.pie_row(pg_tx, pid)["fotos_pdf_blob"]
        # El PDF final lleva las originales + el anexo (≥2 páginas: el anexo
        # solo daría 1).
        assert h.paginas(final) >= 2
