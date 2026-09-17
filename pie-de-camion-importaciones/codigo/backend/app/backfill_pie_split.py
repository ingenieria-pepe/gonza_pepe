"""Backfill: migra los pies de camión VIEJOS al modelo PARTIDO (informe de datos +
fotos-PDF aparte). Los viejos tenían las fotos embebidas en el informe Y guardadas
individuales (doble). Este script regenera el informe SIN fotos y arma el fotos-PDF
desde las fotos individuales, deja ambos en S3, y así quedan igual que los nuevos.

    python -m app.backfill_pie_split

Idempotente: sólo toca pies con fotos individuales que TODAVÍA no tienen fotos_pdf.
NO borra las fotos individuales (eso es un paso aparte, cuando esté verificado).
"""
from app.core import s3
from app.pg import fetch_all
from app.modules.piedecamion.router import regenerar_pie_split


def main() -> int:
    rows = fetch_all("""
        SELECT DISTINCT p.id
        FROM ext.pie_de_camion p
        JOIN ext.pie_de_camion_foto f ON f.pie_camion_id = p.id
        WHERE p.fotos_pdf_blob IS NULL AND p.fotos_pdf_s3_key IS NULL
        ORDER BY p.id
    """)
    print(f"{len(rows)} pies a migrar al modelo partido")
    ok = 0
    for r in rows:
        pid = r["id"]
        try:
            datos_pdf, fotos_pdf = regenerar_pie_split(pid)
            s3.offload_pdf("pie_de_camion", pid, datos_pdf, "piedecamion")
            if fotos_pdf:
                s3.offload_pdf(
                    "pie_de_camion", pid, fotos_pdf, "piedecamion_fotos",
                    blob_col="fotos_pdf_blob", s3_col="fotos_pdf_s3_key",
                )
            ok += 1
            print(f"  pie {pid}: OK (datos {len(datos_pdf)}b, fotos {len(fotos_pdf) if fotos_pdf else 0}b)")
        except Exception as e:  # noqa: BLE001
            print(f"  pie {pid}: FALLO {e}")
    print(f"{ok}/{len(rows)} migrados")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
