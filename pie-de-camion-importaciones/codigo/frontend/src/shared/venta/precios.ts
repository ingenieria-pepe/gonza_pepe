// Escalonado del precio en el tomador (pedido del dueño 13/08): los botones
// −/+ mueven DE A $50, con dos paradas especiales:
//  · el PRECIO BASE: si el paso lo cruzaría, primero se clava ahí (en ambos
//    sentidos — de 725 con base 750, "+" va a 750, no a 775);
//  · los límites duros −10%/+20%: el paso se recorta hasta clavarse exacto en
//    el borde (nunca lo pasa, nunca lo saltea).
export const PASO_PRECIO = 50;

export interface LimitesPrecio {
  min: number;
  max: number;
}

// Límite duro del tomador: de −10% a +20% del precio base (asimétrico a
// propósito: para arriba hay más margen que para abajo).
export const PCT_MIN = -10;
export const PCT_MAX = 20;

/** Rango permitido a partir del precio base. ceil/floor hacia ADENTRO del
 *  rango: un precio clampeado nunca queda "fuera de rango" por redondeo (con
 *  bases chicas, round podía dar −11,8%). null = sin base ⇒ sin límites. */
export function limitesDeBase(base: number | null | undefined): LimitesPrecio | null {
  if (!base || base <= 0) return null;
  return {
    min: Math.ceil(base * (1 + PCT_MIN / 100)),
    max: Math.floor(base * (1 + PCT_MAX / 100)),
  };
}

/** Próximo precio al tocar −/+ : actual ± $50, parando en el base si el paso
 *  lo cruza, y recortado al rango permitido. Sin límites (descuento / sin
 *  base) devuelve el paso pelado. */
export function escalonarPrecio(
  actual: number,
  dir: 1 | -1,
  lim: LimitesPrecio | null,
  base?: number | null,
): number {
  let paso = Math.round(actual + dir * PASO_PRECIO);
  if (base != null && base > 0) {
    const b = Math.round(base);
    // Cruzar el base de largo no: primero se para ahí. (Desde el base exacto
    // sí se sigue de a $50 — si no, no te podrías mover nunca.)
    if (dir === 1 && actual < b && paso > b) paso = b;
    if (dir === -1 && actual > b && paso < b) paso = b;
  }
  if (!lim) return paso;
  return Math.min(lim.max, Math.max(lim.min, paso));
}
