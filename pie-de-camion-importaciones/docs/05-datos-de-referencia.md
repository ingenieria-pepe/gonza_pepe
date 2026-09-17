# Datos de referencia

Todo esto está también en `datos/*.csv` — separador `;`, UTF-8 con BOM, así que
abren derecho en Excel en español.

---

## 1. Productores (los proveedores)

57 productores en uso. Las **iniciales** no son decorativas: son el prefijo del
`codigo_importador_camion` que identifica cada camión (`FH-044` = Fischer,
camión 44) y lo que se imprime en las etiquetas de pallet.

`datos/productores.csv`

| Productor | Ini. | Productor | Ini. | Productor | Ini. |
|---|---|---|---|---|---|
| Ulgo | HG | Marconi Kons | MK | Chicolandia |  |
| Exoticos PY |  | Ivo Zimerman | IZ | Josemar Provesi | JP |
| Claudia | CH | Banana MG | MG | Cebolla | CE |
| Gilson | GT | A Confirmar |  | Abacaxi | AB |
| Jaime | JM | Paraguay | PY | AgroBianvirc | BRSP |
| Papa | PA | Paraguay EC | PYE | Cobalchini | CB |
| Boniato | BO | Paraguay OP | PYO | Junkes | JS |
| Sidnei | SR | Paraguay MS | PYM | Wagner Schveitzer | WC |
| Benini | BN | Paraguay GM | GM | Banana Combinada |  |
| Valdemar | VH | Paraguay DF | DF | BAHIA | BA |
| Valdemar Ita | VA | Jorge Marangoni | JM | Banana SP | BRSP |
| Adriano | AD | Paraguay HF | HF | Bahia + Exoticos | BA |
| Varios | VA | Paraguay SF | SF | Marnei Meurer | MM |
| Nordeste | ND | Bolivia Tuli | BT | Cassio Hauck |  |
| Corupá | CP | João Claudio Winter | JW | Aldo Corupa | AC |
| Jhony Viera | JV | Osnildo Stein | ST | Alexandre Wilbert | AW |
| Muller | MU | Zapellini | ZP | Vinicios Bonkoski | VB |
| Sergio | SG | Fischer | FH | Furlani | FU |
| Vitor | VM | Tureck | TK | Airton Curuca |  |

Se ven tres tipos de entrada mezclados, y es intencional:

- **Productores de verdad** — nombres de personas o empresas de Santa Catarina /
  Paraná (Fischer, Tureck, Zapellini, Junkes, Marnei Meurer, Corupá, Aldo
  Corupa, Wagner Schveitzer, Osnildo Stein, João Claudio Winter…).
- **Orígenes usados como productor** — `Paraguay XX`, `BAHIA`, `Banana SP`,
  `Banana MG`, `Bolivia Tuli`. Cuando la compra es a un origen y no a un
  productor identificado.
- **Productos usados como productor** — `Papa`, `Boniato`, `Cebolla`,
  `Abacaxi`. Herencia del Excel viejo, donde la columna se usaba para agrupar.

`Varios` y `A Confirmar` son los comodines.

> **Ojo con las iniciales duplicadas:** `Jaime` y `Jorge Marangoni` son los dos
> `JM`; `Valdemar Ita` y `Varios` son los dos `VA`; `AgroBianvirc` y `Banana SP`
> los dos `BRSP`. Las iniciales **no son una clave única** — sirven para leer el
> código a ojo, no para identificar en la base.

---

## 2. Transportistas

27 en uso (`datos/transportistas.csv`):

CMCN · Amaro · Balbiani · Cigliuti · Cordenonsi · El Palomar · Pradera ·
Transzanini · Gral · Aotrans · Sergio Nava · Marvel · K2 · Costa Rica ·
Schwanck · Silvio · Tottal Brasil · Trans America · Transitex · Ruiz · Viana ·
Realeza · Azzolini · VI-MA · Coopecarga · Chabat · Transporte Carneiro

---

## 3. Fronteras

`datos/fronteras.csv`

| Frontera | Nota |
|---|---|
| **Río Branco** | la de Brasil (Jaguarão) |
| **Rivera** | la de Brasil (Santana do Livramento) |
| **Chuy** | la de Brasil (Chuí) |
| **Salto** | la de Argentina — paso obligado para Paraguay |
| **Montevideo** | puerto, para lo que llega por mar |

---

## 4. Estados de una carga

`datos/estados-de-carga.csv` — ver [`02-plan-de-cargas.md`](02-plan-de-cargas.md)
para el ciclo completo.

---

## 5. Checklist de fotos del pie de camión

`datos/fotos-obligatorias-pie-de-camion.csv` — las 21 fotos en orden canónico,
con el slug estable, la etiqueta del formulario y el título que aparece en el
informe PDF. Ver [`01-pie-de-camion.md`](01-pie-de-camion.md) §3.

---

## 6. Categorías de fruta

`datos/categorias-de-fruta.csv` — 44 categorías, cada una con su ícono y las
palabras que mapean a ella.

**De dónde salen:** el ERP contable no tiene un campo de categoría usable (sus
códigos jerárquicos ponen todo lo vendible en el mismo grupo). Pero la
**descripción del artículo siempre empieza con el tipo de producto** — `"Banana
Brasil"`, `"Kiwi Chile"`, `"Cebolla Blanca"` — así que la categoría se deriva de
la primera palabra.

Eso además filtra sola la basura contable (DEUDORES, MUEBLES, REDONDEOS) y los
no vendibles (BINS, Pallets): no matchean ninguna categoría y quedan fuera del
picker.

La categoría es lo que agrupa los **requisitos del agrónomo** y lo que define el
ícono que se ve en las listas.

Decisiones de agrupación que no son obvias:

- **Cebollín va dentro de Cebolla** — en el picker es la misma familia.
- **Nectarines van con Durazno** — la ficha técnica de los agrónomos los agrupa
  (misma especie, *Prunus persica*), y comparten requisitos de ingreso.
- **Piña acepta `abacaxi` y `ananá`** — según quién cargó el artículo.
- **Mandioca acepta `yuca`**; **Zapallo acepta `cabutiá` y `calabaza`**.
- **Zucchini va con Pepino** (el alargado), pero **Zapallito** (el redondo
  verde) tiene ícono propio.

---

## 7. Orígenes y sus abreviaturas

`datos/origenes-abreviaturas.csv` · código en `codigo/frontend/src/shared/origen.ts`

En el celular del vendedor la descripción se trunca y quedaba «Banana P…» /
«Banana Ec…»: imposible saber qué banana es, que es justo lo que hay que saber —
el precio de la de Brasil y la de Ecuador no tienen nada que ver. Y no es sólo
la banana: hay **16 orígenes en uso**, con 67 artículos de Brasil, 33 de Chile y
30 de Ecuador.

Acortar la palabra no alcanzaba: el origen está **en el medio** del nombre y el
truncado corta por el final. Por eso el origen se extrae del texto y va adelante
como etiqueta, donde nunca se corta.

| Origen | Sigla | | Origen | Sigla |
|---|---|---|---|---|
| Brasil | `BR` | | Perú | `PER` |
| Paraguay | `PY` | | España | `ESP` |
| Bolivia | `BOL` | | Italia | `ITA` |
| Ecuador | `ECU` | | Grecia | `GRE` |
| Chile | `CHI` | | Egipto | `EGI` |
| Colombia | `COL` | | China | `CHN` |
| México | `MEX` | | Uruguay / Nacional | `UY` |
| Argentina | `ARG` | | Importado (sin país) | `IMP` |

> **Las abreviaturas no son ISO a propósito.** Son las que no se confunden de un
> vistazo a las 3 de la mañana: `BO`/`BR` se parecen demasiado, así que Bolivia
> es `BOL`; `CL`/`CO`/`CN` son las tres C, así que van `CHI`/`COL`/`CHN`. Vale
> más un carácter de más que un error de origen.

`Uruguay` y `Nacional` son lo mismo para el vendedor: lo que decide el precio es
de dónde vino, no cómo lo escribió quien cargó el artículo. `Importado` no dice
de dónde, pero distingue del nacional — que es la diferencia de IVA.

---

## 8. Clasificación operativa de banana por origen

La que conoce el operario en el depósito (viene del sistema de conteo de
cámaras). No es la identidad contable del artículo, es cómo se le habla:

```
Brasil · Brasil OK · Brasil Fibra
Paraguay · Paraguay Primera · Paraguay Segunda
Ecuador · Ecuador Bonita · Ecuador Pepe · Ecuador Bagno
Bolivia
```

Y como artículos: `Banana Brasil Ok`, `Banana Brasil Fibra`, `Banana Paraguay`,
`Banana Paraguay Pepe`, `Banana Ecuador`, `Banana Ecuador Pepe`,
`Banana Bolivia`, `Banana Bolivia Suprema`, `Banana Bolivia Beefrut`,
`Banana Bolivia Porvenir`, `Palta Brasil`, `Palta Perú`, `Palta México`.

**Embalaje por país** — importa para el proceso de maduración:

| País | Embalaje |
|---|---|
| Brasil, Paraguay, Bolivia | **madera** (cajón) |
| Ecuador | **cartón** |

---

## 9. Catálogo de productos (código → producto → origen)

`datos/catalogo-productos.csv` — **51 artículos** con su código, su descripción
real y el país de origen (33 lo dicen en el nombre). Es lo que hace legible todo
lo demás: los códigos sueltos no significan nada sin esto.

Sale de cruzar cuatro mapeos del sistema (dashboard de stock, mapeos del sistema
de conteo de cámaras, alias de supermercado). **No es el maestro completo** — ese
vive en el ERP y no está en este paquete —, pero cubre lo que efectivamente se
mueve.

Lo que dice del negocio, mirando la columna de origen:

| Origen | Productos en el catálogo |
|---|---|
| **Brasil** | banana (3 tipos), palta (5 calibres), jengibre, cúrcuma, lima, mango, papaya, coco, uva (blanca / negra / rosada), melón valenciano |
| **Ecuador** | banana (Super, Bonita), piña (5 calibres), plátano |
| **Paraguay** | banana Primera y Segunda |
| **Bolivia** | banana Tuly |
| **Chile** | kiwi |
| **Perú** | arándanos |
| **España** | ciruela |

Detalles del catálogo que valen la pena:

- **La banana lleva sufijo de color** (`-1` … `-7`) y ese es el artículo que se
  vende. `010101-4` = Banana Brasil Color 4.
- **Paraguay separa Primera (`010401`) y Segunda (`010402`)**; Brasil separa
  normal / OK / Fibra (`010101` / `010103` / `010102`).
- **Ecuador Pepe y Ecuador Bagno no tienen código propio**: los tres convergen a
  `010701`. Bolivia Tuly / Suprema / DFC también comparten `010703`.
- **La ciruela no separa calibre** en el ERP: los calibres 45/50/55/60 caen todos
  en `961401`. La palta y la piña sí: cada calibre es un artículo.

---

## 10. Ranking de ventas por artículo

`datos/ranking-ventas-por-articulo.csv` — los 99 códigos más vendidos, medidos
como **cantidad de pedidos que incluyeron ese código** (frecuencia, no volumen),
sobre los últimos 120 días al 15/07/2026. Es lo que ordena el picker del
tomador: familias más vendidas primero, y dentro de cada familia los productos
por ventas.

Es un **reconocimiento fijo**: no se recalcula por request. Para refrescarlo hay
que re-correr el reconocimiento y re-ejecutar la siembra de la migración 0050.

Cruzado contra el catálogo de la sección anterior, el top dice bastante del
negocio:

| # | Código | Producto | Origen | Pedidos |
|---|---|---|---|---|
| 1 | `010101-4` | Banana Color 4 | **Brasil** | 3.764 |
| 2 | `010701-4` | Banana Color 4 | **Ecuador** | 3.653 |
| 3 | `600101` | Palta Cal. 60 | **Brasil** | 2.261 |
| 4 | `010101-5` | Banana Color 5 | **Brasil** | 1.754 |
| 5 | `890501` | Arándanos | **Perú** | 1.658 |
| 6 | `010401-4` | Banana Color 4 | **Paraguay** | 1.509 |
| 7 | `090901` | Jengibre | **Brasil** | 1.111 |
| 8 | `0802363` | (kiwi, calibre sin mapear) | Chile | 1.099 |
| 9 | `970101` | Maní tostado | — | 1.027 |
| 10 | `010701-5` | Banana Color 5 | **Ecuador** | 823 |

> **Los tres orígenes de banana ocupan 4 de los 6 primeros puestos**, y en el
> mismo color: el 4. Es el corazón del negocio.

59 de los 99 códigos tienen descripción (los que están en el catálogo); el resto
queda con el código pelado en vez de un nombre inventado. El sufijo `-N` es el
color de maduración.

---

## 11. Columnas de las planillas maestras

`datos/planilla-BR-columnas.csv` y `datos/planilla-OTROS-columnas.csv` — el
mapeo índice-de-columna → campo de la base, para cada uno de los dos Excel.
Sirve si hay que rearmar el parser o comparar contra otra planilla.
