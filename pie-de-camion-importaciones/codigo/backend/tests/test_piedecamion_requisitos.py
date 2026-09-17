"""Requisitos por fruta en Pie de Camión (mig 0092).

El ing. agrónomo define POR CATEGORÍA de fruta qué se pide al ingreso (número /
texto / opciones / foto); el operario responde UNA vez por fruta presente en la
mercadería y el pie snapshotea todo.
"""
import pytest

from tests.integration.fixtures_http import cliente_http  # noqa: F401
from tests.integration import helpers_piedecamion as h
from tests import factories

COD_KIWI = "080301"


@pytest.fixture
def entorno(pg_tx, monkeypatch):
    seeds = h.sembrar_entorno(pg_tx)
    factories.insertar(pg_tx, "legacy.articulos",
                       codarticulo=COD_KIWI, descripcion="Kiwi Chile Calibre 27")
    seeds["infra"] = h.patch_infra(monkeypatch)
    seeds["user"] = h.actor(pg_tx, "pie_camion")
    seeds["agronomo"] = h.actor(pg_tx, "pie_requisitos_config")
    return seeds


def _config_kiwi(cliente_http, agronomo, requisitos):
    r = cliente_http.como(agronomo).put(
        "/pie-camion/requisitos/Kiwi", json={"requisitos": requisitos},
    )
    assert r.status_code == 200, r.text
    return r.json()


REQS_KIWI = [
    {"tipo": "numero", "etiqueta": "Presión de pulpa", "unidad": "kgf", "obligatorio": True},
    {"tipo": "opciones", "etiqueta": "Estado de la cáscara",
     "opciones": ["Sana", "Con russet", "Dañada"], "obligatorio": True},
    {"tipo": "texto", "etiqueta": "Observaciones del lote", "obligatorio": False},
    {"tipo": "foto", "etiqueta": "Foto de la pulpa", "obligatorio": True},
]


class TestConfigAbm:
    def test_alta_y_lectura(self, cliente_http, entorno):
        out = _config_kiwi(cliente_http, entorno["agronomo"], REQS_KIWI)
        assert [r["etiqueta"] for r in out] == [r["etiqueta"] for r in REQS_KIWI]
        assert out[1]["opciones"] == ["Sana", "Con russet", "Dañada"]
        r = cliente_http.get("/pie-camion/requisitos")
        assert r.status_code == 200
        assert any(x["categoria"] == "Kiwi" for x in r.json())

    def test_fila_omitida_se_desactiva_pero_no_se_borra(self, cliente_http, pg_tx, entorno):
        out = _config_kiwi(cliente_http, entorno["agronomo"], REQS_KIWI)
        out2 = _config_kiwi(cliente_http, entorno["agronomo"], [
            {"id": out[0]["id"], "tipo": "numero", "etiqueta": "Presión de pulpa (kgf)",
             "unidad": "kgf", "obligatorio": True},
        ])
        assert len(out2) == 1 and out2[0]["etiqueta"] == "Presión de pulpa (kgf)"
        with pg_tx.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM ext.pie_requisito WHERE categoria = 'Kiwi'")
            assert cur.fetchone()[0] == len(REQS_KIWI)  # siguen todas, inactivas

    def test_opciones_necesita_dos(self, cliente_http, entorno):
        r = cliente_http.como(entorno["agronomo"]).put(
            "/pie-camion/requisitos/Kiwi",
            json={"requisitos": [{"tipo": "opciones", "etiqueta": "Color", "opciones": ["Verde"]}]},
        )
        assert r.status_code == 400

    def test_categoria_invalida_400_y_operario_403(self, cliente_http, pg_tx, entorno):
        r = cliente_http.como(entorno["agronomo"]).put(
            "/pie-camion/requisitos/Dinosaurio", json={"requisitos": []},
        )
        assert r.status_code == 400
        r = cliente_http.como(entorno["user"]).put(
            "/pie-camion/requisitos/Kiwi", json={"requisitos": []},
        )
        assert r.status_code == 403  # recepción responde, no define
        # `stock` (Ingresos) tampoco: el ABM es EXCLUSIVO del permiso nuevo.
        r = cliente_http.como(h.actor(pg_tx, "stock")).put(
            "/pie-camion/requisitos/Kiwi", json={"requisitos": []},
        )
        assert r.status_code == 403

    def test_agronomo_puro_entra_al_modulo(self, cliente_http, pg_tx, entorno):
        """Un usuario SOLO con pie_requisitos_config pasa la puerta de lectura
        del router (si no, no podría llegar a su propio ABM)."""
        agronomo_puro = h.actor(pg_tx, "pie_requisitos_config")
        r = cliente_http.como(agronomo_puro).get("/pie-camion/requisitos")
        assert r.status_code == 200

    def test_aplicables_resuelve_categoria_desde_los_cods(self, cliente_http, entorno):
        """El form manda los cod_art de sus líneas; el back matchea la fruta
        (cero duplicación del categorizador en el front)."""
        _config_kiwi(cliente_http, entorno["agronomo"], REQS_KIWI)
        r = cliente_http.como(entorno["user"]).get(
            f"/pie-camion/requisitos/aplicables?cods={h.COD_BANANA},{COD_KIWI}",
        )
        assert r.status_code == 200, r.text
        grupos = r.json()
        # Banana no tiene config → sólo aparece Kiwi
        assert [g["categoria"] for g in grupos] == ["Kiwi"]
        assert grupos[0]["icono"] == "kiwi"
        assert len(grupos[0]["requisitos"]) == len(REQS_KIWI)


class TestCreateConRequisitos:
    def _respuestas(self, ids, *, presion="6,5", estado="Sana"):
        return [
            {"requisito_id": ids[0], "valor": presion},
            {"requisito_id": ids[1], "valor": estado},
        ]

    def _body(self, ids, **overrides):
        base = h.body_pie(
            lineas=[
                {"cod_art": h.COD_BANANA, "cantidad": 100, "hay_reclamos": False},
                {"cod_art": COD_KIWI, "cantidad": 40, "hay_reclamos": False},
            ],
            requisitos=self._respuestas(ids),
            fotos_categoria=[{
                "categoria": f"req-{ids[3]}",
                "label": "Kiwi — Foto de la pulpa",
                "foto": h.data_uri(h.jpeg()),
            }],
        )
        base.update(overrides)
        return base

    def test_falta_obligatorio_400_nombrandolo(self, cliente_http, entorno):
        out = _config_kiwi(cliente_http, entorno["agronomo"], REQS_KIWI)
        ids = [r["id"] for r in out]
        r = cliente_http.como(entorno["user"]).post(
            "/pie-camion", json=self._body(ids, requisitos=[]),
        )
        assert r.status_code == 400
        assert "Kiwi: Presión de pulpa" in r.json()["detail"]

    def test_falta_la_foto_400(self, cliente_http, entorno):
        out = _config_kiwi(cliente_http, entorno["agronomo"], REQS_KIWI)
        ids = [r["id"] for r in out]
        r = cliente_http.como(entorno["user"]).post(
            "/pie-camion", json=self._body(ids, fotos_categoria=[]),
        )
        assert r.status_code == 400
        assert "Foto de la pulpa" in r.json()["detail"]

    def test_opcion_invalida_400(self, cliente_http, entorno):
        out = _config_kiwi(cliente_http, entorno["agronomo"], REQS_KIWI)
        ids = [r["id"] for r in out]
        r = cliente_http.como(entorno["user"]).post(
            "/pie-camion", json=self._body(ids, requisitos=self._respuestas(ids, estado="Violeta")),
        )
        assert r.status_code == 400

    def test_ok_persiste_snapshot_y_detail_y_pdf(self, cliente_http, pg_tx, entorno):
        out = _config_kiwi(cliente_http, entorno["agronomo"], REQS_KIWI)
        ids = [r["id"] for r in out]
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=self._body(ids))
        assert r.status_code == 201, r.text
        pdc_id = r.json()["id"]

        with pg_tx.cursor() as cur:
            cur.execute(
                "SELECT BTRIM(tipo), BTRIM(etiqueta), valor_numero, valor_texto, fotos_n "
                "FROM ext.pie_requisito_respuesta WHERE pie_camion_id = %s ORDER BY orden",
                (pdc_id,),
            )
            filas = cur.fetchall()
        assert ("numero", "Presión de pulpa", 6.5, None, 0) in filas
        assert ("opciones", "Estado de la cáscara", None, "Sana", 0) in filas
        assert ("foto", "Foto de la pulpa", None, None, 1) in filas

        det = cliente_http.get(f"/pie-camion/{pdc_id}").json()
        assert {x["etiqueta"] for x in det["requisitos"]} == {
            "Presión de pulpa", "Estado de la cáscara", "Foto de la pulpa",
        }
        assert all(x["categoria"] == "Kiwi" for x in det["requisitos"])

        texto = h.texto_pdf(h.pie_row(pg_tx, pdc_id)["pdf_blob"])
        assert "REQUISITOS POR FRUTA" in texto
        assert "Presión de pulpa" in texto and "6.5 kgf" in texto

    def test_config_cambia_despues_y_el_snapshot_queda(self, cliente_http, pg_tx, entorno):
        out = _config_kiwi(cliente_http, entorno["agronomo"], REQS_KIWI)
        ids = [r["id"] for r in out]
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=self._body(ids))
        pdc_id = r.json()["id"]
        _config_kiwi(cliente_http, entorno["agronomo"], [])  # el agrónomo borra todo
        det = cliente_http.get(f"/pie-camion/{pdc_id}").json()
        assert any(x["etiqueta"] == "Presión de pulpa" for x in det["requisitos"])

    def test_productos_legacy_tambien_matchean(self, cliente_http, entorno):
        """Clientes viejos sin líneas: la lista `productos` también dispara la
        validación por fruta."""
        out = _config_kiwi(cliente_http, entorno["agronomo"], REQS_KIWI)
        ids = [r["id"] for r in out]
        body = h.body_pie(lineas=[], productos=[{"producto": "Kiwi Gold"}], requisitos=[])
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=body)
        assert r.status_code == 400
        assert "Kiwi" in r.json()["detail"]
        assert ids  # (la config existe: el 400 vino de los obligatorios)

    def test_sin_config_el_pie_sale_igual(self, cliente_http, entorno):
        """Banana sin requisitos configurados: el flujo actual no cambia."""
        r = cliente_http.como(entorno["user"]).post("/pie-camion", json=h.body_pie())
        assert r.status_code == 201, r.text
