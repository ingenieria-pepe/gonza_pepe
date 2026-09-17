"""Contrato de GET /venta/stock-disponible.

Lo que se prueba acá es lo que decide si el vendedor ve un numero util:
que se pidan excluidas las familias que no son mercaderia, que cada articulo
reciba el saldo de SU familia, y que un disponible negativo llegue crudo al
front (que decide mostrarlo como "sin stock") en vez de venir aplastado a cero.
"""
import unittest
from datetime import datetime
from unittest.mock import patch

from app.modules.stock.curation import FAMILIAS_SIN_STOCK_VENDIBLE
from app.modules.venta.router import stock_disponible

T1 = datetime(2026, 8, 12, 10, 0, 0)
T2 = datetime(2026, 8, 12, 10, 5, 0)


def _fila(cod_art, codstock, familia, saldo, comprometido, ts=T1, ranking=0, pedidos=0):
    return {
        "cod_art": cod_art,
        "codstock": codstock,
        "familia": familia,
        "saldo_familia": saldo,
        "comprometido": comprometido,
        "disponible": saldo - comprometido,
        "pedidos_pendientes": pedidos,
        "ranking": ranking,
        "actualizado_en": ts,
    }


class StockDisponibleVentaTest(unittest.TestCase):
    def test_excluye_las_familias_que_no_son_mercaderia(self):
        """Envases y Descuentos caen bajo '1.1.*' pero no son productos."""
        with patch("app.modules.venta.router.fetch_all", return_value=[]) as mock:
            stock_disponible()

        (_sql, params), _ = mock.call_args
        excluidas = set(params[0])
        self.assertEqual(excluidas, set(FAMILIAS_SIN_STOCK_VENDIBLE))
        self.assertIn("1.1.2.98", excluidas, "Envases tiene que quedar afuera")
        self.assertIn("1.1.3.1", excluidas, "Descuentos tiene que quedar afuera")

    def test_todos_los_colores_comparten_el_numero_de_la_familia(self):
        """El saldo por color es ficcion: Color 4 da negativo y Color 1 positivo.
        El numero con sentido fisico es el de la familia, para todos igual."""
        filas = [
            _fila("010101-1", "1.1.1.01", "Banana Brasil", 12000, 47),
            _fila("010101-4", "1.1.1.01", "Banana Brasil", 12000, 47),
        ]
        with patch("app.modules.venta.router.fetch_all", return_value=filas):
            r = stock_disponible()

        self.assertEqual(len(r.disponible), 2)
        self.assertEqual({a.disponible for a in r.disponible}, {11953.0})
        self.assertEqual({a.cod_stock for a in r.disponible}, {"1.1.1.01"})

    def test_resta_los_pedidos_comprometidos(self):
        filas = [_fila("600101", "1.1.2.60", "Palta Cal.60", 1351, 154, pedidos=3)]
        with patch("app.modules.venta.router.fetch_all", return_value=filas):
            r = stock_disponible()

        a = r.disponible[0]
        self.assertEqual(a.saldo_familia, 1351.0)
        self.assertEqual(a.comprometido, 154.0)
        self.assertEqual(a.disponible, 1197.0)
        self.assertEqual(a.pedidos_pendientes, 3)

    def test_el_negativo_llega_crudo(self):
        """No se aplasta a cero en la API: el front decide como mostrarlo."""
        filas = [_fila("010102", "1.1.1.02", "Banana Brasil Fibra", -90, 0)]
        with patch("app.modules.venta.router.fetch_all", return_value=filas):
            r = stock_disponible()

        self.assertEqual(r.disponible[0].disponible, -90.0)

    def test_informa_la_lectura_mas_reciente_del_espejo(self):
        """Si el mirror esta congelado, el front tiene que poder avisarlo."""
        filas = [
            _fila("010101", "1.1.1.01", "Banana Brasil", 10, 0, ts=T1),
            _fila("600101", "1.1.2.60", "Palta Cal.60", 20, 0, ts=T2),
        ]
        with patch("app.modules.venta.router.fetch_all", return_value=filas):
            r = stock_disponible()

        self.assertEqual(r.macrosoft_actualizado_en, T2)

    def test_mirror_vacio_no_inventa_un_timestamp(self):
        with patch("app.modules.venta.router.fetch_all", return_value=[]):
            r = stock_disponible()

        self.assertEqual(r.disponible, [])
        self.assertIsNone(r.macrosoft_actualizado_en)


if __name__ == "__main__":
    unittest.main()
