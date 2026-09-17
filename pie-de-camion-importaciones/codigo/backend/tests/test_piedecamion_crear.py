"""POST /pie-camion: idempotencia por client_ref, "¿hay reclamos?" por línea y
best-effort de los PDFs secundarios.

Reglas R278, R289, R290, R293, R277 y R307 del inventario.
"""
import uuid

import pytest

from tests.integration.fixtures_http import cliente_http  # noqa: F401
from tests.integration import helpers_piedecamion as h


@pytest.fixture
def entorno(pg_tx, monkeypatch):
    seeds = h.sembrar_entorno(pg_tx)
    seeds["infra"] = h.patch_infra(monkeypatch)
    seeds["user"] = h.actor(pg_tx, "pie_camion")
    return seeds


def _count_pies(conn, client_ref: str) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM ext.pie_de_camion WHERE client_ref = %s",
                    (client_ref,))
        return cur.fetchone()[0]


class TestIdempotenciaClientRef:
    def test_reintento_con_mismo_client_ref_no_duplica(self, cliente_http, pg_tx, entorno):
        """Regla R278: el client_ref UUID reserva el pie — reintentar el POST
        (timeout donde la respuesta se perdió) devuelve el pie ORIGINAL, nunca
        un duplicado."""
        ref = str(uuid.uuid4())
        body = h.body_pie(client_ref=ref)
        r1 = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r1.status_code == 201, r1.text
        id_original = r1.json()["id"]

        # El celu re-manda el MISMO body (mismo ref) tras el timeout.
        r2 = cliente_http.post("/pie-camion", json=body)
        assert r2.status_code == 201
        assert r2.json()["id"] == id_original
        assert _count_pies(pg_tx, ref) == 1

    def test_reintento_devuelve_el_original_aunque_cambie_el_body(self, cliente_http, pg_tx, entorno):
        """Regla R278: manda el ref, no el contenido — el retry con body apenas
        distinto (el borrador siguió vivo) igual devuelve el pie ya guardado."""
        ref = str(uuid.uuid4())
        r1 = cliente_http.como(entorno["user"]).post("/pie-camion", json=h.body_pie(client_ref=ref))
        assert r1.status_code == 201
        r2 = cliente_http.post(
            "/pie-camion", json=h.body_pie(client_ref=ref, chofer_nombre="Otro Chofer"))
        assert r2.status_code == 201
        assert r2.json()["id"] == r1.json()["id"]
        assert _count_pies(pg_tx, ref) == 1

    def test_indice_unico_parcial_de_client_ref_existe(self, pg_tx, entorno):
        """Regla R278 (mig 0058): el candado duro contra la carrera del retry es
        el índice ÚNICO parcial sobre client_ref (el precheck solo no alcanza)."""
        with pg_tx.cursor() as cur:
            cur.execute("""
                SELECT indexdef FROM pg_indexes
                WHERE schemaname = 'ext' AND tablename = 'pie_de_camion'
                  AND indexname = 'uq_pie_de_camion_client_ref'
            """)
            fila = cur.fetchone()
        assert fila, "falta el índice único de client_ref (mig 0058)"
        assert "UNIQUE" in fila[0]
        assert "client_ref IS NOT NULL" in fila[0]

    def test_sin_client_ref_cada_post_crea_un_pie(self, cliente_http, pg_tx, entorno):
        """Regla R278: clientes viejos sin ref no se idempotentizan entre sí
        (dos camiones reales del mismo día no se pisan)."""
        r1 = cliente_http.como(entorno["user"]).post("/pie-camion", json=h.body_pie())
        r2 = cliente_http.post("/pie-camion", json=h.body_pie())
        assert r1.status_code == 201 and r2.status_code == 201
        assert r1.json()["id"] != r2.json()["id"]


class TestHayReclamosPorLinea:
    def test_rollup_del_pie_es_any_de_las_lineas(self, cliente_http, pg_tx, entorno):
        """Regla R289: la respuesta es POR PRODUCTO y el pie guarda el roll-up
        (hay reclamos en el camión si los hay en alguna fruta)."""
        body = h.body_pie(lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 100, "hay_reclamos": True,
             "defectos": [{"motivo_id": entorno["motivo_id"], "cantidad": 3,
                           "fotos": [h.data_uri(h.jpeg())]}]},
            {"cod_art": h.COD_PERA, "cantidad": 50, "hay_reclamos": False},
        ])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 201, r.text
        pid = r.json()["id"]
        assert h.pie_row(pg_tx, pid)["hay_reclamos"] is True
        lineas = h.lineas_de(pg_tx, pid)
        assert [(l["cod_art"], l["hay_reclamos"]) for l in lineas] == [
            (h.COD_BANANA, True), (h.COD_PERA, False)]

    def test_todas_no_deja_el_pie_en_false(self, cliente_http, pg_tx, entorno):
        """Regla R289: todas las frutas revisadas y sanas → el pie declara
        explícitamente que NO hay reclamos (False, no NULL)."""
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=h.body_pie())
        assert r.status_code == 201
        assert h.pie_row(pg_tx, r.json()["id"])["hay_reclamos"] is False

    def test_falta_responder_una_linea_400_nombrando_el_producto(self, cliente_http, entorno):
        """Regla R290: una línea sin responder → 400 que NOMBRA el cod_art."""
        body = h.body_pie(lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 100, "hay_reclamos": False},
            {"cod_art": h.COD_PERA, "cantidad": 50},   # sin responder
        ])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 400
        assert h.COD_PERA in r.json()["detail"]

    def test_si_con_cero_defectos_400(self, cliente_http, entorno):
        """Regla R290: responder SÍ y no marcar ningún defecto es incoherente."""
        body = h.body_pie(lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 100, "hay_reclamos": True}])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 400
        assert h.COD_BANANA in r.json()["detail"]

    def test_no_con_defectos_marcados_400(self, cliente_http, entorno):
        """Regla R290: responder NO con defectos marcados también se rechaza."""
        body = h.body_pie(lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 100, "hay_reclamos": False,
             "defectos": [{"motivo_id": entorno["motivo_id"], "cantidad": 2}]}])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 400
        assert h.COD_BANANA in r.json()["detail"]

    def test_respuesta_a_nivel_pie_se_baja_a_todas_las_lineas(self, cliente_http, pg_tx, entorno):
        """Regla R293: front de la mig 0071 (responde a nivel PIE) → la
        respuesta se propaga a cada línea y el POST pasa."""
        body = h.body_pie(hay_reclamos=False, lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 100},
            {"cod_art": h.COD_PERA, "cantidad": 50},
        ])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 201, r.text
        assert all(l["hay_reclamos"] is False for l in h.lineas_de(pg_tx, r.json()["id"]))

    def test_sin_ninguna_respuesta_400_recarga(self, cliente_http, entorno):
        """Regla R293: front anterior a todo (ni pie ni líneas) → 400 con la
        instrucción de RECARGAR (no un error críptico a las 3 AM)."""
        body = h.body_pie(lineas=[{"cod_art": h.COD_BANANA, "cantidad": 100}])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 400
        assert "Recarg" in r.json()["detail"]


class TestPesoFotos:
    def test_fotos_que_superan_30mb_413_legible(self, cliente_http, entorno):
        """Regla R277: el tope de fotos es por PESO (30 MB), no por cantidad —
        antes de que nginx corte el body con un 413 en HTML inexplicable."""
        # ~31 MB de "foto" en base64 (no hace falta que sea una imagen real:
        # el peso se estima sin decodificar).
        gigante = "A" * (31 * 1024 * 1024 * 4 // 3)
        body = h.body_pie(lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 100, "hay_reclamos": True,
             "defectos": [{"motivo_id": entorno["motivo_id"], "cantidad": 2,
                           "fotos": [gigante]}]}])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 413
        assert "MB" in r.json()["detail"]

    def test_muchas_fotos_livianas_pasan(self, cliente_http, entorno):
        """Regla R277 (contracara): la CANTIDAD no limita — un reclamo real
        trajo 46 fotos y tiene que entrar."""
        fotos = [h.data_uri(h.jpeg(color=(i * 5 % 255, 80, 80))) for i in range(46)]
        body = h.body_pie(lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 100, "hay_reclamos": True,
             "defectos": [{"motivo_id": entorno["motivo_id"], "cantidad": 2,
                           "fotos": fotos}]}])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 201, r.text


class TestDocPdfBestEffort:
    def test_doc_pdf_roto_no_tumba_la_carga_del_pie(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Regla R307: el PDF de documentación es secundario — si su armado
        explota (imagen patológica, LayoutError), el pie se guarda SIN doc y
        no se pierde la carga entera."""
        from app.modules.piedecamion import pdf as pdf_gen

        def _boom(*_a, **_kw):
            raise RuntimeError("LayoutError simulado")

        monkeypatch.setattr(pdf_gen, "generate_documentacion_pdf", _boom)
        body = h.body_pie(documentacion=[h.data_uri(h.jpeg(400, 560))])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 201, r.text
        row = h.pie_row(pg_tx, r.json()["id"])
        assert row["doc_pdf_blob"] is None
        assert row["pdf_blob"] is not None          # la planilla sí se generó
        assert h.paginas(row["pdf_blob"]) >= 1

    def test_con_doc_valida_el_pie_lleva_su_doc_pdf_aparte(self, cliente_http, pg_tx, entorno):
        """Regla R307 (camino feliz): documentación válida → doc-PDF APARTE de
        la planilla, una página por imagen."""
        body = h.body_pie(documentacion=[
            h.data_uri(h.jpeg(400, 560)), h.data_uri(h.jpeg(400, 560, (30, 30, 200)))])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 201, r.text
        row = h.pie_row(pg_tx, r.json()["id"])
        assert row["doc_pdf_blob"] is not None
        assert h.paginas(row["doc_pdf_blob"]) == 2
