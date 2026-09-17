"""PDFs de pie de camión con reportlab REAL, asertados con pypdf: el anexo de
fotos downscalea (anti-OOM de la t3.small) y el doc-PDF de documentación NO
(nitidez A4).

Reglas R306 y R330 del inventario.
"""
import unittest
from io import BytesIO

from PIL import Image as PILImage
from pypdf import PdfReader

from app.modules.piedecamion import pdf as pdf_gen


def _jpeg(w: int, h: int, color=(180, 40, 40)) -> bytes:
    buf = BytesIO()
    PILImage.new("RGB", (w, h), color).save(buf, format="JPEG")
    return buf.getvalue()


def _imagenes_embebidas(pdf_bytes: bytes) -> list[tuple[int, int]]:
    """(ancho, alto) de cada imagen embebida en el PDF."""
    out = []
    for page in PdfReader(BytesIO(pdf_bytes)).pages:
        for img in page.images:
            out.append(PILImage.open(BytesIO(img.data)).size)
    return out


class ThumbJpegTest(unittest.TestCase):
    def test_achica_a_1000px_de_lado_mayor(self):
        """Regla R330: _thumb_jpeg reduce a 1000px el lado mayor ANTES de
        maquetar — un pie de 49 fotos originales pegaba picos de ~1GB de RAM y
        el kernel mataba uvicorn (OOM → 502 en la t3.small)."""
        out = pdf_gen._thumb_jpeg(_jpeg(2000, 1200))
        im = PILImage.open(BytesIO(out))
        self.assertLessEqual(max(im.size), 1000)
        # Aspecto preservado (2000:1200 = 5:3).
        self.assertAlmostEqual(im.width / im.height, 2000 / 1200, places=2)

    def test_no_agranda_fotos_chicas(self):
        out = pdf_gen._thumb_jpeg(_jpeg(400, 300))
        self.assertEqual(PILImage.open(BytesIO(out)).size, (400, 300))

    def test_blob_roto_devuelve_el_original(self):
        """Regla R330: best-effort — un blob ilegible vuelve tal cual (nunca
        rompe el PDF)."""
        basura = b"esto no es una imagen"
        self.assertEqual(pdf_gen._thumb_jpeg(basura), basura)


class FotosPdfDownscaleaTest(unittest.TestCase):
    def test_el_fotos_pdf_embebe_thumbnails_no_originales(self):
        """Reglas R306/R330: el PDF de fotos del camión pasa TODO por
        _thumb_jpeg(1000px) — ninguna imagen embebida supera los 1000px."""
        # Colores distintos: dos fotos idénticas tras el downscale se dedupean
        # en un solo XObject y el conteo mentiría.
        grupos = [("Estado de la fruta",
                   [_jpeg(2000, 1500), _jpeg(1600, 1000, (40, 40, 180))])]
        pdf = pdf_gen.generate_piedecamion_fotos_pdf(id_documento=1, fotos_grupos=grupos)
        self.assertIsNotNone(pdf)
        tamanios = _imagenes_embebidas(pdf)
        self.assertEqual(len(tamanios), 2)
        for w, h in tamanios:
            self.assertLessEqual(max(w, h), 1000, "se embebió la foto original")

    def test_sin_fotos_devuelve_none(self):
        """El None es la señal de CONSERVAR el fotos-PDF anterior al editar."""
        self.assertIsNone(pdf_gen.generate_piedecamion_fotos_pdf(
            id_documento=1, fotos_grupos=[]))
        self.assertIsNone(pdf_gen.generate_piedecamion_fotos_pdf(
            id_documento=1, fotos_grupos=[("Vacío", [])]))


class DocumentacionPdfNoDownscaleaTest(unittest.TestCase):
    def test_el_doc_pdf_embebe_la_imagen_original(self):
        """Regla R306: la documentación escaneada NO se downscalea (se lee en
        A4 — bajarla a 1000px la vuelve ilegible). La imagen va tal cual."""
        pdf = pdf_gen.generate_documentacion_pdf([_jpeg(1654, 2339)], id_documento=1)
        tamanios = _imagenes_embebidas(pdf)
        self.assertEqual(tamanios, [(1654, 2339)])

    def test_una_pagina_por_imagen(self):
        pdf = pdf_gen.generate_documentacion_pdf(
            [_jpeg(800, 1100), _jpeg(800, 1100, (30, 30, 200))], id_documento=1)
        self.assertEqual(len(PdfReader(BytesIO(pdf)).pages), 2)

    def test_sin_imagenes_validas_devuelve_vacio(self):
        self.assertEqual(pdf_gen.generate_documentacion_pdf([], id_documento=1), b"")


if __name__ == "__main__":
    unittest.main()
