"""Reclamo post-hoc de un pie (POST/PUT /pie-camion/{id}/reclamo): PDF partido
informe/fotos, fotos que se ANEXAN al editar (incidente del pie 87) y guards.

Reglas R271, R272, R273, R274, R275, R276 y R292 del inventario.
"""
import pytest

from tests.integration.fixtures_http import cliente_http  # noqa: F401
from tests.integration import helpers_piedecamion as h


@pytest.fixture
def entorno(pg_tx, monkeypatch):
    seeds = h.sembrar_entorno(pg_tx)
    seeds["infra"] = h.patch_infra(monkeypatch)
    seeds["user"] = h.actor(pg_tx, "stock")   # Ingresos: puede reclamar, no crear
    seeds["recepcion"] = h.actor(pg_tx, "pie_camion")
    return seeds


def _crear_pie(cliente_http, entorno, **body_over) -> int:
    r = cliente_http.como(entorno["recepcion"]).post("/pie-camion", json=h.body_pie(**body_over))
    assert r.status_code == 201, r.text
    return r.json()["id"]


def _defecto(entorno, linea_id, n_fotos=1, cantidad=4.0, notas=None):
    return {
        "linea_id": linea_id, "motivo_id": entorno["motivo_id"],
        "cantidad": cantidad, "notas": notas,
        "fotos": [h.data_uri(h.jpeg(color=(40 * i % 255, 60, 60))) for i in range(n_fotos)],
    }


def _reclamar(cliente_http, entorno, pid, defectos, **extra):
    return cliente_http.como(entorno["user"]).post(
        f"/pie-camion/{pid}/reclamo", json={"defectos": defectos, **extra})


class TestCrearYReHacer:
    def test_post_solo_pies_sin_reclamo_409(self, cliente_http, pg_tx, entorno):
        """Regla R274: el POST es para pies SIN reclamo — el segundo intento
        devuelve 409 (para corregir existe el PUT)."""
        pid = _crear_pie(cliente_http, entorno)
        lid = h.lineas_de(pg_tx, pid)[0]["id"]
        r1 = _reclamar(cliente_http, entorno, pid, [_defecto(entorno, lid)])
        assert r1.status_code == 201, r1.text
        r2 = _reclamar(cliente_http, entorno, pid, [_defecto(entorno, lid)])
        assert r2.status_code == 409
        assert "ya tiene un reclamo" in r2.json()["detail"]

    def test_put_rehace_conservando_identidad_del_reclamo(self, cliente_http, pg_tx, entorno):
        """Regla R274: el PUT re-hace el reclamo conservando id, link al
        movimiento (documento/nro_fact), generado_en y generado_por — re-fecharlo
        lo hacía "reaparecer" como nuevo en los listados."""
        pid = _crear_pie(cliente_http, entorno)
        lid = h.lineas_de(pg_tx, pid)[0]["id"]
        rid = _reclamar(cliente_http, entorno, pid, [_defecto(entorno, lid)]).json()["reclamo_id"]
        # Simular que el pie ya se confirmó y el reclamo quedó linkeado.
        with pg_tx.cursor() as cur:
            cur.execute("UPDATE ext.reclamo SET documento = '400', nro_fact = 777 "
                        "WHERE id = %s", (rid,))
        antes = h.reclamo_row(pg_tx, rid)

        r = cliente_http.como(entorno["user"]).put(
            f"/pie-camion/{pid}/reclamo",
            json={"defectos": [_defecto(entorno, lid, cantidad=9.0, n_fotos=0)]})
        assert r.status_code == 200, r.text
        assert r.json()["reclamo_id"] == rid
        despues = h.reclamo_row(pg_tx, rid)
        assert despues["documento"] == "400" and despues["nro_fact"] == 777
        assert despues["generado_en"] == antes["generado_en"]
        assert despues["generado_por_usuario_id"] == antes["generado_por_usuario_id"]
        # El informe del reclamo sí se re-hizo y los defectos son los nuevos.
        assert bytes(despues["pdf_blob"]) != bytes(antes["pdf_blob"])
        defectos = h.defectos_de(pg_tx, pid)
        assert len(defectos) == 1 and float(defectos[0]["cantidad"]) == 9.0

    def test_put_sin_reclamo_previo_409(self, cliente_http, pg_tx, entorno):
        """Regla R274: PUT sobre un pie sin reclamo → 409 (no crea de costado)."""
        pid = _crear_pie(cliente_http, entorno)
        lid = h.lineas_de(pg_tx, pid)[0]["id"]
        r = cliente_http.como(entorno["user"]).put(
            f"/pie-camion/{pid}/reclamo", json={"defectos": [_defecto(entorno, lid)]})
        assert r.status_code == 409
        assert "no tiene reclamo" in r.json()["detail"]


class TestFotosSeAnexan:
    def test_editar_con_fotos_nuevas_anexa_por_defecto(self, cliente_http, pg_tx, entorno):
        """Regla R271 (incidente pie 87): las fotos nuevas del PUT se ANEXAN al
        doc de fotos del reclamo (merge de PDFs) — reemplazar borró para siempre
        las de la papaya, porque Aloha guarda el PDF, no las imágenes."""
        pid = _crear_pie(cliente_http, entorno)
        lid = h.lineas_de(pg_tx, pid)[0]["id"]
        rid = _reclamar(cliente_http, entorno, pid,
                        [_defecto(entorno, lid, n_fotos=2)]).json()["reclamo_id"]
        p_inicial = h.paginas(h.reclamo_row(pg_tx, rid)["fotos_pdf_blob"])
        assert p_inicial >= 1

        r = cliente_http.como(entorno["user"]).put(
            f"/pie-camion/{pid}/reclamo",
            json={"defectos": [_defecto(entorno, lid, n_fotos=2)]})
        assert r.status_code == 200, r.text
        p_anexado = h.paginas(h.reclamo_row(pg_tx, rid)["fotos_pdf_blob"])
        assert p_anexado > p_inicial, "las fotos nuevas tenían que SUMARSE a las viejas"

    def test_reemplazar_fotos_solo_explicito(self, cliente_http, pg_tx, entorno):
        """Regla R271: reemplazar el doc de fotos exige reemplazar_fotos=true
        explícito (default apagado) — ahí sí queda solo el batch nuevo."""
        pid = _crear_pie(cliente_http, entorno)
        lid = h.lineas_de(pg_tx, pid)[0]["id"]
        rid = _reclamar(cliente_http, entorno, pid,
                        [_defecto(entorno, lid, n_fotos=2)]).json()["reclamo_id"]
        p_inicial = h.paginas(h.reclamo_row(pg_tx, rid)["fotos_pdf_blob"])

        r = cliente_http.como(entorno["user"]).put(
            f"/pie-camion/{pid}/reclamo",
            json={"defectos": [_defecto(entorno, lid, n_fotos=2)],
                  "reemplazar_fotos": True})
        assert r.status_code == 200, r.text
        p_final = h.paginas(h.reclamo_row(pg_tx, rid)["fotos_pdf_blob"])
        # Mismo batch (2 fotos) → mismas páginas que el inicial, sin anexo.
        assert p_final == p_inicial

    def test_editar_sin_fotos_nuevas_conserva_el_doc_intacto(self, cliente_http, pg_tx, entorno):
        """Regla R271: un PUT sin fotos deja el doc de fotos EXACTAMENTE igual
        (ese era el punto de separar informe y fotos en la mig 0047)."""
        pid = _crear_pie(cliente_http, entorno)
        lid = h.lineas_de(pg_tx, pid)[0]["id"]
        rid = _reclamar(cliente_http, entorno, pid,
                        [_defecto(entorno, lid, n_fotos=1)]).json()["reclamo_id"]
        blob_antes = bytes(h.reclamo_row(pg_tx, rid)["fotos_pdf_blob"])

        r = cliente_http.como(entorno["user"]).put(
            f"/pie-camion/{pid}/reclamo",
            json={"defectos": [_defecto(entorno, lid, n_fotos=0, cantidad=7.0)]})
        assert r.status_code == 200, r.text
        assert bytes(h.reclamo_row(pg_tx, rid)["fotos_pdf_blob"]) == blob_antes


class TestContadorDeFotos:
    def test_defecto_que_vuelve_sin_fotos_conserva_cantidad_fotos(self, cliente_http, pg_tx, entorno):
        """Regla R272: re-hacer el reclamo sin re-subir las fotos (el modal no
        las pre-carga: viven solo en el PDF) conserva la cantidad_fotos anterior
        — el contador tiene que decir la verdad sobre el PDF."""
        pid = _crear_pie(cliente_http, entorno)
        lid = h.lineas_de(pg_tx, pid)[0]["id"]
        _reclamar(cliente_http, entorno, pid, [_defecto(entorno, lid, n_fotos=3)])
        assert h.defectos_de(pg_tx, pid)[0]["cantidad_fotos"] == 3

        r = cliente_http.como(entorno["user"]).put(
            f"/pie-camion/{pid}/reclamo",
            json={"defectos": [_defecto(entorno, lid, n_fotos=0, cantidad=6.0)]})
        assert r.status_code == 200, r.text
        assert h.defectos_de(pg_tx, pid)[0]["cantidad_fotos"] == 3

    def test_con_reemplazo_explicito_el_contador_arranca_de_cero(self, cliente_http, pg_tx, entorno):
        """Regla R272 (contracara): con reemplazar_fotos=true las viejas ya no
        están en el PDF → un defecto sin fotos nuevas queda en 0."""
        pid = _crear_pie(cliente_http, entorno)
        lid = h.lineas_de(pg_tx, pid)[0]["id"]
        _reclamar(cliente_http, entorno, pid, [_defecto(entorno, lid, n_fotos=3)])

        r = cliente_http.como(entorno["user"]).put(
            f"/pie-camion/{pid}/reclamo",
            json={"defectos": [_defecto(entorno, lid, n_fotos=0)],
                  "reemplazar_fotos": True})
        assert r.status_code == 200, r.text
        assert h.defectos_de(pg_tx, pid)[0]["cantidad_fotos"] == 0


class TestGuards:
    def test_previos_mas_nuevos_superan_la_cantidad_400(self, cliente_http, pg_tx, entorno):
        """Regla R276: en el POST los defectos del ALTA cuentan — previos +
        nuevos > cantidad de la línea → 400."""
        pid = _crear_pie(cliente_http, entorno, lineas=[
            {"cod_art": h.COD_BANANA, "cantidad": 10, "hay_reclamos": True,
             "defectos": [{"motivo_id": entorno["motivo_id"], "cantidad": 8,
                           "fotos": [h.data_uri(h.jpeg())]}]},
        ])
        # Pie con defectos del alta pero sin reclamo (simula un pie viejo, de
        # antes de que el alta generara el reclamo): el POST post-hoc tiene que
        # sumar los previos → 8 previos + 3 nuevos > 10 de la línea.
        lid = h.lineas_de(pg_tx, pid)[0]["id"]
        with pg_tx.cursor() as cur:
            cur.execute("UPDATE ext.pie_de_camion SET reclamo_id = NULL WHERE id = %s", (pid,))
        r = _reclamar(cliente_http, entorno, pid,
                      [_defecto(entorno, lid, cantidad=3.0)])
        assert r.status_code == 400
        assert "superan la cantidad" in r.json()["detail"]

    def test_linea_de_otro_pie_400(self, cliente_http, pg_tx, entorno):
        """Regla R275 (precheck): un linea_id que no pertenece al pie → 400."""
        pid = _crear_pie(cliente_http, entorno)
        otro = _crear_pie(cliente_http, entorno)
        lid_ajena = h.lineas_de(pg_tx, otro)[0]["id"]
        r = _reclamar(cliente_http, entorno, pid, [_defecto(entorno, lid_ajena)])
        assert r.status_code == 400
        assert "no pertenece" in r.json()["detail"]

    def test_edicion_concurrente_del_pie_409_no_fk_500(self, cliente_http, pg_tx, entorno, monkeypatch):
        """Regla R275: el reclamo re-valida los linea_ids DENTRO de su tx — si
        una edición concurrente re-creó las líneas (ids nuevos), devuelve 409
        "el pie fue editado" en vez de reventar con FK 500."""
        from app.modules import stock

        pid = _crear_pie(cliente_http, entorno)
        lid_vieja = h.lineas_de(pg_tx, pid)[0]["id"]

        # La "edición concurrente": se cuela después del precheck (que ya leyó
        # las líneas) y antes de la tx del reclamo. Se engancha en la generación
        # del PDF del reclamo, que corre exactamente en esa ventana.
        real_gen = stock.pdf.generate_reclamo_pdf

        def _editar_en_el_medio(*a, **kw):
            with pg_tx.cursor() as cur:
                cur.execute("DELETE FROM ext.pie_de_camion_linea WHERE pie_camion_id = %s", (pid,))
                cur.execute(
                    "INSERT INTO ext.pie_de_camion_linea "
                    "(pie_camion_id, cod_art, descripcion, deposito, cantidad, orden) "
                    "VALUES (%s, %s, 'BANANA BRASIL', 'B', 100, 0)",
                    (pid, h.COD_BANANA),
                )
            return real_gen(*a, **kw)

        monkeypatch.setattr(stock.pdf, "generate_reclamo_pdf", _editar_en_el_medio)
        r = _reclamar(cliente_http, entorno, pid, [_defecto(entorno, lid_vieja)])
        assert r.status_code == 409, r.text
        assert "editado" in r.json()["detail"]
        assert h.defectos_de(pg_tx, pid) == []          # nada quedó a medias
        assert h.pie_row(pg_tx, pid)["reclamo_id"] is None


class TestHayReclamosPostHoc:
    def test_reclamo_posthoc_contradice_el_sin_reclamos_del_alta(self, cliente_http, pg_tx, entorno):
        """Regla R292: reclamar post-hoc pone hay_reclamos=TRUE en el pie Y en
        la línea reclamada, y el informe re-generado ya no dice SIN RECLAMOS
        (se corrige el objeto en memoria ANTES de re-generar)."""
        pid = _crear_pie(cliente_http, entorno)     # alta declaró NO en todo
        fila = h.pie_row(pg_tx, pid)
        assert fila["hay_reclamos"] is False
        assert "SIN RECLAMOS" in h.texto_pdf(fila["pdf_blob"])
        lid = h.lineas_de(pg_tx, pid)[0]["id"]

        r = _reclamar(cliente_http, entorno, pid, [_defecto(entorno, lid)])
        assert r.status_code == 201, r.text
        fila = h.pie_row(pg_tx, pid)
        assert fila["hay_reclamos"] is True
        assert h.lineas_de(pg_tx, pid)[0]["hay_reclamos"] is True
        texto = h.texto_pdf(fila["pdf_blob"])
        assert "SIN RECLAMOS" not in texto, "la planilla seguía negando el reclamo adjunto"
        assert "SE RECLAMA" in texto
