/** Origen de un producto, para que quepa en el celular.
 *
 * En el celular del vendedor la descripción se trunca y quedaba «Banana P…» /
 * «Banana Ec…»: imposible saber qué banana es, que es JUSTO lo que hay que
 * saber — el precio de la de Brasil y la de Ecuador no tiene nada que ver
 * (dueño 3/09). Y no es sólo la banana: hay 16 orígenes en uso, con 67
 * artículos de Brasil, 33 de Chile y 30 de Ecuador.
 *
 * Acortar la palabra no alcanzaba: el origen está en el MEDIO del nombre y el
 * truncado corta por el final, así que igual se perdía. Por eso el origen sale
 * del texto y va adelante como etiqueta — al frente nunca lo corta.
 *
 * Las abreviaturas NO son ISO a propósito: son las que no se confunden de un
 * vistazo a las 3 de la mañana. `BO`/`BR` se parecen demasiado, así que
 * Bolivia es `BOL`; `CL`/`CO`/`CN` son las tres C, así que van `CHI`/`COL`/
 * `CHN`. Vale más un carácter de más que un error de origen — el melón del
 * 3/09 costó cuatro conteos.
 */
export const ORIGENES: [RegExp, string][] = [
  [/\bbrasil\b/i, "BR"],
  [/\bparaguay\b/i, "PY"],
  [/\bbolivia\b/i, "BOL"],
  [/\becuador\b/i, "ECU"],
  [/\bchile\b/i, "CHI"],
  [/\bcolombia\b/i, "COL"],
  [/\bmexico\b|\bméxico\b/i, "MEX"],
  [/\bargentina\b/i, "ARG"],
  [/\bper[uú]\b/i, "PER"],
  [/\bespa[nñ]a\b/i, "ESP"],
  [/\bitalia\b/i, "ITA"],
  [/\bgrecia\b/i, "GRE"],
  [/\begipto\b/i, "EGI"],
  [/\bchina\b/i, "CHN"],
  // Uruguay aparece como «Uruguay» y como «Nacional»: es lo mismo para el
  // vendedor y se muestra igual, porque lo que decide el precio es de dónde
  // vino, no cómo lo escribió quien cargó el artículo.
  [/\buruguay\b/i, "UY"],
  [/\bnacional(es)?\b/i, "UY"],
  // «Importado/a» no dice de dónde, pero distingue del nacional — que es la
  // diferencia de IVA (10% vs 22% con RUT).
  [/\bimportad[oa]s?\b/i, "IMP"],
  [/\bimport\.?\b/i, "IMP"],
];

export interface ConOrigen {
  /** Sigla para la etiqueta, o null si el nombre no dice el origen. */
  origen: string | null;
  /** El nombre sin la palabra del origen, colapsando los espacios que quedan. */
  resto: string;
}

/** Parte una descripción en (origen, resto). Si no hay origen reconocible
 *  devuelve el nombre intacto: nunca inventa una sigla. */
export function partirOrigen(descripcion: string | null | undefined): ConOrigen {
  const d = (descripcion ?? "").trim();
  if (!d) return { origen: null, resto: "" };
  for (const [re, sigla] of ORIGENES) {
    if (re.test(d)) {
      const resto = d.replace(re, " ").replace(/\s{2,}/g, " ").trim();
      // Si sacar el origen deja el nombre vacío («Nacional» a secas) se
      // conserva el original: es mejor un nombre raro que una fila sin texto.
      return { origen: sigla, resto: resto || d };
    }
  }
  return { origen: null, resto: d };
}
