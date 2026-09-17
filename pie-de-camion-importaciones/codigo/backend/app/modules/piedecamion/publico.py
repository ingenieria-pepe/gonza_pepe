"""QR de la etiqueta de pallet.

El QR codifica SOLO el código (texto plano) — NO un link ni el dominio. Si un
externo lo escanea con la cámara del celular ve el código y nada más (ni URL para
entrar ni el informe). El escaneo útil se hace DESDE Aloha (logueado): el tab QR de
Consulta lee el código y busca el pie de camión con permiso.
"""
from app.core.qr import qr_svg


__all__ = ["qr_svg"]
