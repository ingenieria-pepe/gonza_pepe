/** El ORIGEN del producto, adelante y abreviado (dueño 3/09).
 *
 *  En el celular del vendedor la descripción se trunca y quedaba «Banana P…» /
 *  «Banana Ec…»: imposible saber qué banana es, que es justo lo que hay que
 *  saber — el precio de la de Brasil y la de Ecuador no tiene nada que ver.
 */
import { describe, expect, it } from "vitest";
import { partirOrigen } from "./origen";

describe("Origen del producto", () => {
  it("saca el origen del medio del nombre y lo devuelve aparte", () => {
    // El caso de la captura: «Banana Ecuador Bonita Color 4» se truncaba en
    // «Banana Ec…» justo antes de lo que importa.
    expect(partirOrigen("Banana Ecuador Bonita Color 4")).toEqual({
      origen: "ECU", resto: "Banana Bonita Color 4",
    });
    expect(partirOrigen("Palta Brasil x 4 kg")).toEqual({
      origen: "BR", resto: "Palta x 4 kg",
    });
  });

  it("Bolivia es BOL y no BO: BO y BR se parecen demasiado a las 3 AM", () => {
    expect(partirOrigen("Banana Bolivia Suprema Color 2").origen).toBe("BOL");
    expect(partirOrigen("Banana Brasil Fibra").origen).toBe("BR");
  });

  it("las tres C se distinguen entre sí", () => {
    expect(partirOrigen("Kiwi Chile Calibre 18").origen).toBe("CHI");
    expect(partirOrigen("Banana Colombia").origen).toBe("COL");
    expect(partirOrigen("Ajo China").origen).toBe("CHN");
  });

  it("Nacional y Uruguay son lo mismo para el vendedor", () => {
    expect(partirOrigen("Esparrago Nacional 350 grs").origen).toBe("UY");
    expect(partirOrigen("Frutilla CHICA Uruguay").origen).toBe("UY");
  });

  it("«importado» distingue del nacional aunque no diga de dónde", () => {
    // Es la diferencia de IVA: 10% nacional vs 22% importado con RUT.
    expect(partirOrigen("Palta HASS Importada x 2 (Super)").origen).toBe("IMP");
    expect(partirOrigen("Uva Blanca import.  8 Kilos (Super)").origen).toBe("IMP");
  });

  it("sin origen reconocible NO inventa una sigla", () => {
    expect(partirOrigen("Mango Tomy")).toEqual({ origen: null, resto: "Mango Tomy" });
    expect(partirOrigen("Melon Cantalup")).toEqual({ origen: null, resto: "Melon Cantalup" });
  });

  it("si sacar el origen deja el nombre vacío, se conserva el original", () => {
    // Mejor un nombre raro que una fila sin texto.
    expect(partirOrigen("Nacional")).toEqual({ origen: "UY", resto: "Nacional" });
  });

  it("no matchea palabras que sólo CONTIENEN el país", () => {
    // «Chilena» no es «Chile»; sin el borde de palabra, cualquier cosa matchea.
    expect(partirOrigen("Aji Chilena picante").origen).toBeNull();
  });

  it("aguanta vacío y nulo sin romper la fila", () => {
    expect(partirOrigen(null)).toEqual({ origen: null, resto: "" });
    expect(partirOrigen("")).toEqual({ origen: null, resto: "" });
  });
});
