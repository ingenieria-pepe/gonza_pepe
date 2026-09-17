"""Webhook saliente a los dashboards de maduración: best-effort de verdad.

Reglas R299, R300 y R302 del inventario. Todo httpx patcheado en el namespace
del webhook — cero red real.
"""
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from app.modules.piedecamion import webhook


def _settings(token="tok-123", zac="https://zac.example/api", cr="https://cr.example/api"):
    return SimpleNamespace(
        aloha_webhook_token=token,
        aloha_webhook_zac_url=zac,
        aloha_webhook_cr_url=cr,
    )


class _ClientFalso:
    """httpx.Client falso: registra los POST. `fallar=True` simula red caída."""

    instancias: list["_ClientFalso"] = []

    def __init__(self, *a, fallar=False, **kw):
        self.posts: list[tuple[str, dict]] = []
        self._fallar = fallar
        _ClientFalso.instancias.append(self)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def post(self, url, json=None, headers=None):
        if self._fallar:
            raise ConnectionError("red caída simulada")
        self.posts.append((url, headers))
        return SimpleNamespace(status_code=200, text="ok")


def _payload(pie_id=7):
    return {"pie_de_camion": {"id": pie_id}}


class TokenVacioApagaTest(unittest.TestCase):
    def test_sin_token_no_se_manda_nada(self):
        """Regla R299: token vacío = integración APAGADA — ni siquiera se
        instancia el cliente HTTP."""
        _ClientFalso.instancias = []
        with (
            patch.object(webhook, "settings", _settings(token="")),
            patch.object(webhook.httpx, "Client", _ClientFalso),
        ):
            webhook._post(_payload(), [{"ubicacion": "ZAC"}])
        self.assertEqual(_ClientFalso.instancias, [])


class BestEffortTest(unittest.TestCase):
    def test_post_con_red_caida_no_lanza(self):
        """Regla R299: CUALQUIER error del POST se loguea y nunca se propaga —
        el webhook jamás rompe la carga del pie."""
        with (
            patch.object(webhook, "settings", _settings()),
            patch.object(webhook.httpx, "Client",
                         lambda *a, **kw: _ClientFalso(fallar=True)),
        ):
            webhook._post(_payload(), [{"ubicacion": "ZAC"}])   # no debe lanzar

    def test_enviar_registrado_con_db_rota_no_lanza(self):
        """Regla R299: si la reconstrucción del payload revienta (DB caída en el
        BackgroundTask), enviar_registrado se lo traga con un WARNING."""
        def _boom(*_a, **_kw):
            raise RuntimeError("DB caída simulada")

        with patch.object(webhook, "fetch_one", _boom):
            webhook.enviar_registrado(99)    # no debe lanzar

    def test_sin_camaras_mapeables_no_se_manda_nada(self):
        """Regla R300 (borde): sin cámaras con URL configurada no hay destino —
        y tampoco error."""
        _ClientFalso.instancias = []
        with (
            patch.object(webhook, "settings", _settings(zac="", cr="")),
            patch.object(webhook.httpx, "Client", _ClientFalso),
        ):
            webhook._post(_payload(), [{"ubicacion": "ZAC"}])
        self.assertEqual(_ClientFalso.instancias, [])


class RuteoPorUbicacionTest(unittest.TestCase):
    def test_solo_pega_a_las_urls_de_las_ubicaciones_del_pie(self):
        """Regla R300: el POST rutea por ubicación de las cámaras — un pie que
        entró solo a ZAC no le pega al dashboard de CR."""
        cliente = _ClientFalso()
        with (
            patch.object(webhook, "settings", _settings()),
            patch.object(webhook.httpx, "Client", lambda *a, **kw: cliente),
        ):
            webhook._post(_payload(), [{"ubicacion": "ZAC"}, {"ubicacion": "ZAC"}])
        urls = [u for u, _ in cliente.posts]
        self.assertEqual(urls, ["https://zac.example/api"])

    def test_pie_repartido_pega_a_las_dos(self):
        cliente = _ClientFalso()
        with (
            patch.object(webhook, "settings", _settings()),
            patch.object(webhook.httpx, "Client", lambda *a, **kw: cliente),
        ):
            webhook._post(_payload(), [{"ubicacion": "ZAC"}, {"ubicacion": "CR"}])
        self.assertEqual(
            sorted(u for u, _ in cliente.posts),
            ["https://cr.example/api", "https://zac.example/api"],
        )

    def test_user_agent_browser_like(self):
        """Regla R302: el Cloudflare de camcontador2 devuelve 403 a los UA de
        librerías Python — el POST sale con un UA browser-like."""
        cliente = _ClientFalso()
        with (
            patch.object(webhook, "settings", _settings()),
            patch.object(webhook.httpx, "Client", lambda *a, **kw: cliente),
        ):
            webhook._post(_payload(), [{"ubicacion": "CR"}])
        _, headers = cliente.posts[0]
        self.assertTrue(headers["User-Agent"].startswith("Mozilla/5.0"))
        self.assertEqual(headers["Authorization"], "Bearer tok-123")


if __name__ == "__main__":
    unittest.main()
