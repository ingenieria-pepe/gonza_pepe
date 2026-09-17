"""PUT /pie-camion/{id}: solo pendiente, conserva los adjuntos y re-genera
SOLO el datos-PDF.

Reglas R284, R285, R286, R287 y R291 del inventario.
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


def _crear(cliente_http, entorno, **body_over) -> int:
    r = cliente_http.como(entorno["user"]).post("/pie-camion", json=h.body_pie(**body_over))
    assert r.status_code == 201, r.text
    return r.json()["id"]


class TestSoloPendiente:
    def test_editar_un_pie_ingresado_409(self, cliente_http, pg_tx, entorno):
        """Regla R284: PUT solo con estado='pendiente' — un pie ya ingresado
        (o anulado) devuelve 409 nombrando el estado."""
        pid = _crear(cliente_http, entorno)
        with pg_tx.cursor() as cur:
            cur.execute("UPDATE ext.pie_de_camion SET estado = 'ingresado' WHERE id = %s", (pid,))
        r = cliente_http.put(f"/pie-camion/{pid}", json=h.body_pie())
        assert r.status_code == 409
        assert "ingresado" in r.json()["detail"]

    def test_race_confirmar_en_el_medio_409_sin_tocar_nada(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Regla R284: el UPDATE re-chequea estado + rowcount — si otro proceso
        confirmó el pie ENTRE el chequeo inicial y el UPDATE, la edición aborta
        con 409 y no toca nada (race-safe con confirmar)."""
        import app.modules.piedecamion.router as router_mod

        pid = _crear(cliente_http, entorno)
        # El pie deja de estar pendiente en la DB…
        with pg_tx.cursor() as cur:
            cur.execute("UPDATE ext.pie_de_camion SET estado = 'ingresado' WHERE id = %s", (pid,))

        # …pero el chequeo inicial ve la foto VIEJA (pendiente) — la carrera.
        real_fetch_one = router_mod.fetch_one

        def _fetch_stale(sql, params=None):
            if "SELECT BTRIM(estado) AS estado, plan_carga_id" in sql:
                return {"estado": "pendiente", "plan_carga_id": None, "hay_reclamos": None}
            return real_fetch_one(sql, params)

        monkeypatch.setattr(router_mod, "fetch_one", _fetch_stale)
        lineas_antes = h.lineas_de(pg_tx, pid)
        r = cliente_http.put(f"/pie-camion/{pid}", json=h.body_pie(chofer_nombre="Pisado"))
        assert r.status_code == 409
        assert "pendiente" in r.json()["detail"]
        fila = h.pie_row(pg_tx, pid)
        assert fila["chofer_nombre"] != "Pisado"
        assert h.lineas_de(pg_tx, pid) == lineas_antes    # la tx entera rollbackeó


class TestConservaAdjuntos:
    def test_edicion_regenera_solo_el_datos_pdf(self, cliente_http, pg_tx, entorno):
        """Regla R285: editar conserva fotos-PDF, doc-PDF y termógrafo tal cual;
        re-genera SOLO el datos-PDF y limpia pdf_s3_key (no servir el viejo)."""
        pid = _crear(
            cliente_http, entorno,
            fotos=[h.data_uri(h.jpeg())],
            documentacion=[h.data_uri(h.jpeg(400, 560))],
        )
        r = cliente_http.post(f"/pie-camion/{pid}/termografo-pdf",
                              json={"pdf": h.data_uri(h.pdf_simple("termógrafo"), "application/pdf")})
        assert r.status_code == 200, r.text
        # Simular que el informe ya se offloadeó a S3.
        with pg_tx.cursor() as cur:
            cur.execute("UPDATE ext.pie_de_camion SET pdf_s3_key = 'piedecamion/x.pdf' "
                        "WHERE id = %s", (pid,))
        antes = h.pie_row(pg_tx, pid)

        r = cliente_http.put(f"/pie-camion/{pid}",
                             json=h.body_pie(chofer_nombre="Chofer Corregido"))
        assert r.status_code == 200, r.text
        despues = h.pie_row(pg_tx, pid)

        assert despues["chofer_nombre"] == "Chofer Corregido"
        # El datos-PDF se re-generó y el puntero a S3 se limpió.
        assert bytes(despues["pdf_blob"]) != bytes(antes["pdf_blob"])
        assert despues["pdf_s3_key"] is None
        # Los adjuntos NO se tocaron.
        assert bytes(despues["fotos_pdf_blob"]) == bytes(antes["fotos_pdf_blob"])
        assert bytes(despues["doc_pdf_blob"]) == bytes(antes["doc_pdf_blob"])
        assert bytes(despues["termografo_pdf_blob"]) == bytes(antes["termografo_pdf_blob"])

    def test_edicion_conserva_el_reclamo_y_sus_defectos(self, cliente_http, pg_tx, entorno):
        """Regla R285: los defectos (y el reclamo generado en el alta) sobreviven
        a la edición — se re-adjuntan a la línea del mismo cod_art."""
        pid = _crear(cliente_http, entorno, motivo_id=entorno["motivo_id"])
        antes = h.pie_row(pg_tx, pid)
        assert antes["reclamo_id"] is not None
        defectos_antes = h.defectos_de(pg_tx, pid)
        assert len(defectos_antes) == 1

        body = h.body_pie(lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 120},    # cambia la cantidad
        ])
        r = cliente_http.put(f"/pie-camion/{pid}", json=body)
        assert r.status_code == 200, r.text

        despues = h.pie_row(pg_tx, pid)
        assert despues["reclamo_id"] == antes["reclamo_id"]
        defectos = h.defectos_de(pg_tx, pid)
        assert len(defectos) == 1
        assert defectos[0]["cod_art"] == h.COD_BANANA
        assert float(defectos[0]["cantidad"]) == 5.0
        assert defectos[0]["cantidad_fotos"] == 1


class TestSnapshotDefectosPop:
    def test_dos_lineas_del_mismo_codigo_no_duplican_defectos(self, cliente_http, pg_tx, entorno):
        """Regla R286: el snapshot se re-adjunta con .pop — cada defecto se
        asigna UNA vez aunque la edición parta el código en dos líneas."""
        pid = _crear(cliente_http, entorno, motivo_id=entorno["motivo_id"])
        body = h.body_pie(lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 60},
            {"cod_art": h.COD_BANANA, "cantidad": 40},
        ])
        r = cliente_http.put(f"/pie-camion/{pid}", json=body)
        assert r.status_code == 200, r.text
        defectos = h.defectos_de(pg_tx, pid)
        assert len(defectos) == 1, "el defecto se duplicó entre líneas del mismo código"
        lineas = h.lineas_de(pg_tx, pid)
        assert defectos[0]["pie_camion_linea_id"] == lineas[0]["id"]

    def test_sacar_un_producto_con_defecto_409(self, cliente_http, pg_tx, entorno):
        """Regla R286 (guard): quitar de la mercadería un producto reclamado se
        corta con 409 ANTES de tocar nada — el defecto no se tira en silencio."""
        pid = _crear(cliente_http, entorno, motivo_id=entorno["motivo_id"])
        body = h.body_pie(lineas=[{"cod_art": h.COD_PERA, "cantidad": 50}])
        r = cliente_http.put(f"/pie-camion/{pid}", json=body)
        assert r.status_code == 409
        assert h.COD_BANANA in r.json()["detail"]
        assert len(h.defectos_de(pg_tx, pid)) == 1     # nada cambió


class TestPieViejoConFotosComoFilas:
    def test_migra_las_fotos_individuales_antes_de_regenerar(self, cliente_http, pg_tx, entorno):
        """Regla R287: un pie VIEJO (fotos como filas, sin fotos-PDF) se migra
        al fotos-PDF DURANTE la edición — si no, al regenerar el datos-PDF (que
        ya no lleva fotos) desaparecerían del informe."""
        from tests import factories

        pid = _crear(cliente_http, entorno)
        assert h.pie_row(pg_tx, pid)["fotos_pdf_blob"] is None
        for orden in (0, 1):
            blob = h.jpeg(color=(10 + orden * 100, 90, 90))
            factories.insertar(
                pg_tx, "ext.pie_de_camion_foto",
                pie_camion_id=pid, foto_blob=blob, size_bytes=len(blob),
                orden=orden, caption=None,
            )

        r = cliente_http.put(f"/pie-camion/{pid}", json=h.body_pie())
        assert r.status_code == 200, r.text
        fila = h.pie_row(pg_tx, pid)
        assert fila["fotos_pdf_blob"] is not None, "las fotos del pie viejo se perdieron"
        assert h.paginas(fila["fotos_pdf_blob"]) >= 1

    def test_pie_nuevo_sin_fotos_en_el_body_conserva_su_fotos_pdf(self, cliente_http, pg_tx, entorno):
        """Regla R287 (contracara R285): con fotos-PDF ya armado, editar sin
        mandar fotos NO lo re-genera ni lo pisa."""
        pid = _crear(cliente_http, entorno, fotos=[h.data_uri(h.jpeg())])
        antes = h.pie_row(pg_tx, pid)["fotos_pdf_blob"]
        r = cliente_http.put(f"/pie-camion/{pid}", json=h.body_pie())
        assert r.status_code == 200, r.text
        assert bytes(h.pie_row(pg_tx, pid)["fotos_pdf_blob"]) == bytes(antes)


class TestHayReclamosEnEdicion:
    def test_put_sin_hay_reclamos_conserva_la_respuesta(self, cliente_http, pg_tx, entorno):
        """Regla R291: la edición no re-pregunta — un body sin hay_reclamos NO
        NULLea ni al pie ni a la línea (se conserva lo declarado en el alta)."""
        pid = _crear(cliente_http, entorno, motivo_id=entorno["motivo_id"])
        assert h.pie_row(pg_tx, pid)["hay_reclamos"] is True

        r = cliente_http.put(f"/pie-camion/{pid}", json=h.body_pie(lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 100}]))    # sin hay_reclamos
        assert r.status_code == 200, r.text
        assert h.pie_row(pg_tx, pid)["hay_reclamos"] is True
        assert h.lineas_de(pg_tx, pid)[0]["hay_reclamos"] is True

    def test_el_body_no_puede_pisar_la_respuesta_por_api(self, cliente_http, pg_tx, entorno):
        """Regla R291: ni siquiera mandando hay_reclamos=False explícito se
        puede declarar "sin reclamos" en un pie con defectos — se ignora."""
        pid = _crear(cliente_http, entorno, motivo_id=entorno["motivo_id"])
        r = cliente_http.put(f"/pie-camion/{pid}", json=h.body_pie(
            hay_reclamos=False,
            lineas=[{"cod_art": h.COD_BANANA, "cantidad": 100, "hay_reclamos": False}],
        ))
        assert r.status_code == 200, r.text
        assert h.pie_row(pg_tx, pid)["hay_reclamos"] is True
