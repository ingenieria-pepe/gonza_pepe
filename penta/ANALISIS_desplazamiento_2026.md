# Por qué se cayó Brasil — análisis ene-ago 2026

**Fecha:** 03/09/2026 · **actualizado 04/09/2026 — versión 3, con los 4 orígenes**
**Fuentes:** `detalle_UYimport_2026-8-5-92812.xlsx` (BR+PY+BO) y
`detalle_UYimport_2026-8-5-10711.xlsx` (Ecuador), ambos Penta ene-ago 2026 con
`Importador` y `Fecha` por fila; 3 PDFs de ranking; 2 PDFs viejos de Brasil;
`fuentes\uy_import_agg.json` (2024-2026) para la comparación interanual.
**Cobertura: completa.** Brasil + Ecuador + Paraguay + Bolivia, 637 registros.

> **Historial de versiones — importante, porque las conclusiones cambiaron dos veces.**
>
> - **v1 (03/09)**: dedujo may-ago por **resta** entre el acumulado ene-ago y el detalle
>   ene–11may, y sólo tenía 3 orígenes. Conclusión: *"Ciro Gentile se descolgó, Almar
>   aguantó"*.
> - **v2 (04/09 mañana)**: llegó el detalle ene-ago con importador y fecha. Las
>   estimaciones por resta resultaron correctas en los agregados (Brasil 1.699 estimado
>   vs 1.698 real), pero **se movieron los dos y Almar más que Ciro**. También concluyó
>   que faltaban 542 t/mes y que *"el mercado se achicó 16%"*.
> - **v3 (04/09 tarde)**: llegó Ecuador. Con la comparación **interanual** (no contra el
>   semestre anterior), **el "mercado se achicó" resultó FALSO**: la caída may-ago es
>   estacional y pasa todos los años. Ver sección 1b.
>
> La lección: comparar un semestre contra el anterior sin mirar la norma estacional
> produce hallazgos falsos. Es el **mismo error** que tenía el forecast del Cepea
> (sección 6). Contra el año anterior, no contra el período anterior.

---

## 1. El hallazgo principal: se movieron todos, y Almar más que nadie

Con el detalle por importador y mes, el balance may-ago contra ene-abr (t **netas**/mes):

| Importador | Δ Brasil | Δ Paraguay | Δ Bolivia | **Neto** | % de la pérdida BR tapada con PY |
|---|---:|---:|---:|---:|---:|
| **ALMAR** | −376 | **+255** | −151 | **−272** | **68%** |
| CIRO GENTILE | −312 | +161 | −46 | −197 | 52% |
| GARMIN | −67 | +24 | 0 | −42 | 36% |
| EXPERTEX | −20 | +30 | 0 | +10 | — |
| ALBEZ | −44 | +28 | 0 | −17 | 64% |
| MARAMA | −5 | +18 | 0 | +12 | — |

**Corrige la versión anterior.** Con sólo los PDFs parecía que Ciro Gentile se
descolgaba y Almar aguantaba. Con el detalle real: **los dos se mudaron a Paraguay**,
y en toneladas absolutas **Almar movió más** (+255 contra +161).

Brasil por importador, t netas/mes:

| Importador | ene-abr | may-ago | var |
|---|---:|---:|---:|
| **ALMAR** | 1.337 | 962 | −28% |
| CIRO GENTILE | 581 | 269 | **−54%** |
| GARMIN | 466 | 399 | −14% |
| EXPERTEX | 47 | 27 | −43% |
| ALBEZ | 44 | 0 | −100% |
| **TOTAL** | **2.516** | **1.698** | **−33%** |

## 1b. El mercado NO se achicó — la caída de may-ago es estacional

⚠️ **Esta sección corrige la v2, que afirmaba lo contrario.** Mercado uruguayo,
4 orígenes, t netas/mes:

| | 2024 | 2025 | 2026 |
|---|---:|---:|---:|
| ene-abr | 4.912 | 4.995 | **5.069** |
| may-ago | 4.114 | 4.156 | **4.081** |
| *caída may-ago* | *−16,2%* | *−16,8%* | *−19,5%* |

La caída de may-ago **pasa todos los años**, y en nivel absoluto 2026 está clavado con
2024 y 2025 (~4.100 t/mes). **El consumo de Uruguay está plano.** No hubo destrucción
de mercado y no faltan 542 t/mes: era el artefacto de comparar contra el semestre
anterior en vez de contra la norma estacional.

## 1c. La historia real: Brasil perdió un tercio y se lo repartieron tres

May-ago 2026 contra **may-ago 2025** (la comparación que corresponde):

| Origen | 2025 | 2026 | cambio |
|---|---:|---:|---:|
| **Brasil** | 2.964 | 1.698 | **−1.266** |
| Paraguay | 184 | 931 | **+747** |
| Ecuador | 1.008 | 1.245 | **+237** |
| Bolivia | 0 | 206 | **+206** |
| | | | **+1.190** |

Brasil perdió 1.266 t/mes; los otros tres se repartieron 1.190. El neto da −76 y el
mercado total se movió −75. **Cierra al kilo.** Redistribución de origen limpia, sin
caída de consumo.

Dos cosas para notar: **Bolivia es un origen nuevo** (0 t/mes en 2024 y 2025, 206 en
2026), y **Ecuador creció 24%** contra 2025, lejos de perder.

## 1d. Participación de mercado y ranking (4 orígenes)

| Origen | %ene-abr | %may-ago |
|---|---:|---:|
| Brasil | 49,6% | 41,6% |
| Ecuador | 33,4% | 30,5% |
| Paraguay | 8,5% | **22,8%** |
| Bolivia | 8,5% | 5,0% |

Por importador (t netas/mes, los 4 orígenes sumados):

| Importador | ene-abr | may-ago | var |
|---|---:|---:|---:|
| **ALMAR** | **2.565** | **2.023** | **−21%** |
| CIRO GENTILE | 1.212 | 921 | −24% |
| GARMIN | 466 | 424 | **−9%** |
| PROEXUR | 351 | 262 | −25% |
| LINA FRESH | 144 | 164 | **+14%** |
| EXPERTEX | 89 | 100 | +12% |
| HENDERSON | 83 | 69 | −18% |
| JEMI | 65 | 35 | −46% |

**Almar es prácticamente la mitad del mercado uruguayo de banana: 50,6% → 49,6%.**
Cayó 21% pero el mercado cayó 19,5% por estacionalidad, así que la participación quedó
igual. Garmin fue el más resistente (−9%); Ciro el que más perdió de los grandes.

**PROEXUR, LINA FRESH y HENDERSON sólo operan Ecuador** — no aparecen en ningún otro
origen. Son competencia en ese carril únicamente.

## 1e. Cartera de Almar por origen (t netas/mes)

| Origen | ene-abr | may-ago | cambio |
|---|---:|---:|---:|
| Brasil | 1.337 | 962 | −376 |
| Ecuador | 819 | 549 | −270 |
| Paraguay | 183 | 438 | **+255** |
| Bolivia | 225 | 74 | −151 |
| **TOTAL** | **2.565** | **2.023** | **−542** |

## 1f. El timing del cambio de Almar parece una decisión, no una deriva

Paraguay, Almar, t netas por mes:

| ene | feb | mar | abr | may | jun | jul | ago |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 280 | 430 | 23 | **0** | **417** | 367 | 518 | 451 |

Marzo y abril en cero y mayo de vuelta en 417. No es gradual, es un interruptor.
**Pendiente de confirmar con Gonzalo:** ¿decisión comercial propia, o Paraguay no
tenía fruta en marzo-abril?

---

## 2. No fue por precio

Era la hipótesis obvia: Paraguay se comió a Brasil porque estaba más barato.
**Los datos la matan.** El FOB por kilo no se movió en ninguno de los dos:

| Origen   | ene-abr 26 | may-ago 26 | 2025 may-ago | 2024 may-ago |
|----------|-----------:|-----------:|-------------:|-------------:|
| Brasil   | 0,532 | **0,525** | 0,527 | 0,666 |
| Paraguay | 0,525 | **0,520** | 0,554 | 0,563 |
| Bolivia  | 0,614 | **0,616** | — | — |

Brasil y Paraguay están prácticamente al mismo precio (medio centavo de diferencia)
y ninguno se movió. El desplazamiento **no fue arbitraje de precio** — fue
disponibilidad, calidad, logística o relación comercial. No lo podemos distinguir
con estos datos.

Ojo con el contrasentido que queda planteado: el Cepea de agosto se derrumbó
(fruta brasileña *barata*) y sin embargo Uruguay compró **33% menos** Brasil.
Si sobrara fruta buena y barata, la compra tendría que haber subido. Que baje
sugiere que lo que sobra en Brasil no es fruta exportable.

---

## 2b. ⚠️ La "trampa 2" de Ecuador era un FALSO POSITIVO

La regla documentada decía: *"en las filas de origen Ecuador, `Kgs. Netos` repite el
valor de `U$S FOB`; detección `abs(kg - fob) < 0,01`; fix: derivar de
`Cantidad Comercial × 19,5`"*. **Está mal.**

En el extracto de Ecuador ene-ago 2026, 143 de 237 filas dan `kg == fob`. Pero:

| | filas "sanas" | filas "sospechosas" |
|---|---:|---:|
| ratio kgNeto/kgBruto | 0,9208 | **0,9149** |
| USD/kg | 1,0166 | **1,0000** |

**El ratio neto/bruto es el mismo en los dos grupos (~0,92)**, o sea el `kgNeto` de las
filas marcadas es un peso real, no un monto en dólares pegado por error. Lo que pasa es
que **Ecuador se declara a exactamente 1,00 USD/kg**, así que el FOB coincide
numéricamente con los kilos y la heurística marca corrupción donde no la hay.

Control sobre el histórico: el USD/kg implícito de Ecuador en `uy_import_agg.json` da
**0,984 (2024) · 0,997 (2025) · 0,983 (2026)** — consistente. Los datos viejos tampoco
estaban distorsionados, aunque el 58% de los registros de Ecuador figuren como
`derivado=true`.

**Regla nueva:** no aplicar ninguna corrección a Ecuador. Si hace falta validar, usar el
ratio `kgNeto/kgBruto` (debe dar ~0,92), no la comparación contra el FOB.

---

## 2c. ✅ LA CAUSA: problemas de calidad en Brasil

**Dato del terreno, aportado por Gonzalo el 04/09/2026:**

> *"Ciro tuvo problemas de calidad en Brasil y ahí salió para Paraguay en busca
> de calidad."*

Esto cierra la paradoja de la sección 2. El Cepea se derrumbó (fruta brasileña
*barata*) y sin embargo Uruguay compró un tercio menos. **Con calidad se explica
solo:** zafra grande de fruta mala → el precio interno se cae porque sobra volumen,
pero el volumen *exportable* no aparece. Precio y calidad se mueven en direcciones
opuestas, y por eso el precio no explicaba nada.

**Matiz importante:** no fue sólo Ciro. Cayeron **todos** en Brasil, y Almar se movió
a Paraguay incluso más que él (+255 vs +161 t/mes). O sea el fenómeno no es "Ciro tuvo
un problema" sino **"Brasil tuvo un problema"** — Ciro lo sintió más fuerte (−54% de su
volumen brasileño contra −28% de Almar), quizás por comprar a otros productores o por
reaccionar más tarde.

### El clima corrobora: verano 2026 fue el más caluroso de la serie

Temperatura máxima media en Norte SC (Luiz Alves, NASA POWER):

| mes | 2023 | 2024 | 2025 | **2026** |
|---|---:|---:|---:|---:|
| ene | 27,8 | 28,5 | 28,8 | **30,6** |
| feb | 29,0 | 29,7 | 29,6 | **30,8** |
| mar | 28,6 | 29,6 | 29,1 | **29,9** |
| abr | 25,3 | 28,4 | 26,9 | **28,9** |

**Enero a abril de 2026 son los cuatro máximos históricos de la serie**, con enero y
abril ~2 °C por encima de cualquier año previo. Después mayo se desploma a 22,2 contra
un promedio de 25 — verano récord seguido de frenazo brusco.

El timing encaja: la fruta cosechada may-ago se llenó en feb-jun. Y el calor en
desarrollo es el mecanismo que ya estaba identificado como **riesgo #1** en la guía de
corte: acelera el desarrollo, baja la materia seca y **acorta la vida verde**.

**Descartada la lluvia** como vía alternativa (hongos por exceso de humedad). La ventana
de llenado feb-jun de 2026 fue de las más **secas**:

| año | acumulado feb-jun | semanas >40 mm |
|---|---:|---:|
| 2023 | 604 mm | 6 |
| 2024 | 623 mm | 7 |
| 2025 | 454 mm | 4 |
| **2026** | **469 mm** | **3** |

⚠️ **Cuánto peso darle:** es consistente, no probado. El clima explica sólo el 12% de la
varianza en el modelo del dashboard (r²=0,117) y no hay ningún dato de calidad medido
que cierre la cadena calor → fruta mala → menos exportable. Lo que sí está: el verano
2026 fue anómalo de verdad, y el momento coincide con el dato del terreno.

### Implicancia comercial: sería una señal anticipada

Si el calor de verano predice mala calidad en el invierno siguiente, eso es una **señal
de compra con 3-4 meses de anticipación**: se sabría en marzo que la fruta de mayo-agosto
va a venir floja, y se podría mover volumen a Paraguay *antes* que la competencia en vez
de al mismo tiempo.

Para poder confirmarlo hace falta lo que hoy no existe: **registro numérico de calidad
por lote** (ver el hilo de trazabilidad / vida verde, pendiente). Almar ya mide las
variables de entrada correctas — temperatura de pulpa, calibre, longitud, temperatura del
día de corte, lluvia de la semana — pero las guarda como **fotos**, no como números, así
que no se pueden correlacionar con nada.

---

## 3. Paraguay: volvió a 2024, no es nuevo

El salto de Paraguay parece espectacular contra 2025, pero 2025 fue el año raro:

| Paraguay may-ago (t/mes netas) | 2024 | 2025 | 2026 |
|--------------------------------|-----:|-----:|-----:|
|                                | 866  | 184  | **931** |

Paraguay no "conquistó" nada nuevo: **recuperó el nivel de 2024** después de un 2025
en que casi desapareció. Lo verdaderamente anómalo fue 2025, no 2026.

(El 931 es el dato real del detalle ene-ago; la primera versión estimaba 953 por resta.)

---

## 4. Cuidado — el Cepea no lo mueve Uruguay

Uruguay importa ~2.000–3.500 t/mes de Brasil. Brasil produce del orden de 580.000 t/mes.
Uruguay es **menos del 1%** del mercado brasileño. Que Almar o Ciro compren menos
**no puede** mover el precio Cepea. Las dos cosas pasan al mismo tiempo, pero la flecha
causal no va de Uruguay hacia Brasil. Si hay una causa común (una zafra brasileña
grande y de mala calidad, por ejemplo), esto es consistente — pero no está probado acá.

---

## 5. Agosto 2026 rompió el patrón estacional

Agosto siempre cierra más arriba de como abre. 2026 hizo lo contrario, y por lejos:

| Año  | ago 1ª-2ª sem | ago 3ª-4ª sem | delta | set promedio |
|------|--------------:|--------------:|------:|-------------:|
| 2023 | 1,56 | 1,68 | **+7%**  | 1,30 |
| 2024 | 1,92 | 2,18 | **+14%** | 2,20 |
| 2025 | 1,71 | 1,83 | **+7%**  | 2,06 |
| 2026 | 1,40 | 1,05 | **−25%** | ? |

Y contra el baseline estacional, agosto cerró **29% abajo** (1,23 vs 1,72) — el mayor
desvío negativo del año.

---

## 6. ⚠️ El pronóstico del dashboard para setiembre está casi seguro alto

Esto es lo más accionable de todo. El dashboard hoy pronostica:

| Semana | Predicción |
|--------|-----------:|
| 04/09  | R$ 1,81 |
| 11/09  | R$ 1,84 |
| 18/09  | R$ 1,81 |
| 25/09  | R$ 1,83 |

**El último dato real es 0,99.** El modelo está implicando un salto del +83% en una semana.

La causa: la regresión clima→precio tiene **r² = 0,117** (explica el 12% de la varianza),
así que el script le da peso 0,12 al clima y **0,88 al promedio histórico del mes**
(setiembre = 1,86). El modelo **no tiene ningún término que mire el precio actual**.
Es incapaz de reaccionar a que el mercado está 29% abajo de lo normal *ahora mismo*.

Con el precio arrancando setiembre en 0,99 y agosto habiendo caído 25%, tomar 1,81
como referencia de compra es un riesgo real de sobrepagar.

### ✅ ARREGLADO el 03/09/2026 — anclaje al precio actual

Implementado en `actualizar_precios.ps1`. Cómo funciona:

1. **Serie de desvío**: para cada semana, `precio ÷ promedio histórico de su mes`.
   1,0 = el mercado está justo en su norma estacional. Hoy: **0,617** (61,7% de la norma).
2. **phi = persistencia del desvío**, estimado por AR(1) sobre `(desvío − 1)` con los
   propios datos. Salió **0,8135 con r² = 0,66** — los desvíos son fuertemente
   persistentes, lo que justifica arrastrarlos.
3. **Factor de anclaje**: `1 + (desvío_actual − 1) × phi^k`, con k = semanas adelante.
   Decae hacia 1 a medida que se aleja el horizonte (reversión a la media).
4. Se aplica multiplicando la predicción que ya existía. **Si el mercado está en su
   norma (desvío = 1) el factor es 1 y el comportamiento es idéntico al anterior.**

Efecto sobre setiembre 2026:

| Semana | Antes | Después | factor |
|--------|------:|--------:|-------:|
| 04/09  | 1,81 | **1,25** | 0,689 |
| 11/09  | 1,84 | **1,37** | 0,747 |
| 18/09  | 1,81 | **1,44** | 0,794 |
| 25/09  | 1,83 | **1,52** | 0,832 |

**Backtest walk-forward** (cada semana pronostica usando sólo el pasado; baseline, phi
y desvío recalculados en cada paso; 510 pronósticos):

| Horizonte | MAE sin | MAE con | mejora | RMSE mejora |
|-----------|--------:|--------:|-------:|------------:|
| 1 semana  | 0,347 | **0,213** | **−38,7%** | −34,1% |
| 2 semanas | 0,372 | **0,302** | −18,8% | −16,2% |
| 3 semanas | 0,390 | **0,361** | −7,5%  | −5,2%  |
| 4 semanas | 0,400 | **0,395** | −1,2%  | +1,0%  |

A 1 semana gana en el **73%** de las semanas. A 4 semanas queda neutro (RMSE 1% peor):
esperable, porque a ese horizonte la reversión ya ocurrió y el estacional solo es tan
bueno como cualquier otra cosa. No justifica complicarlo más.

Campos nuevos en el JSON por si hay que auditarlo: `pred_sin_ancla`, `factor_ancla`,
`desvio_actual`, `phi_desvio`.

✅ **Ya corrido y aplicado** (03/09, con WhatsApp temporalmente en `enabled:false` y
la config restaurada byte a byte después). El dashboard muestra 1,25 → 1,52 para
setiembre. En esa corrida apareció además que `hfbrasil.org.br` empezó a devolver
**403 al UA pelado** y el script moría en el paso 1: arreglado con `$UA_BROWSER` +
`$HDR_BROWSER`. Tridge (Ecuador) también da 403 pero es Cloudflare y no lo arreglan
los headers — sigue trabado.

---

## 7. Dos problemas de datos encontrados de paso

- **Luiz Alves y Guaramirim son la misma serie.** 192/192 semanas idénticas, y los
  archivos de cache difieren *sólo* en el timestamp. **No es bug del código**: NASA POWER
  tiene grilla de ~55×69 km y los dos pueblos están a 28 km, así que caen en la misma
  celda y la API devuelve lo mismo. El dashboard muestra 2 regiones BR pero informa 1.
  Si se quieren señales separadas hay que usar Open-Meteo (~11 km) para esas dos;
  si no, conviene fusionarlas en una sola "Norte SC" y no aparentar dos.
- **Fechas duplicadas**: `2024-01-05` y `2026-06-26` aparecen dos veces, tanto en la
  serie de precios como en la de clima. Poco impacto, pero ensucia promedios.

---

## 8. Qué falta para cerrar esto

**El análisis de importaciones está CERRADO.** Los 4 orígenes, con importador y mes.
Pendientes que quedan, todos de interpretación o de otras fuentes:

1. ~~Ecuador ene-ago 2026~~ — **resuelto el 04/09**. No absorbió nada: creció 24% contra
   2025 y la caída del semestre es estacional.
2. ~~Paraguay y Bolivia por importador~~ — **resuelto el 04/09**.
3. ~~Detalle mensual xlsx ene-ago~~ — **resuelto el 04/09**.
4. **Confirmar con Gonzalo el corte de Paraguay en marzo-abril** (sección 1f):
   ¿decisión comercial propia o Paraguay no tenía fruta?
5. ~~Por qué Brasil perdió un tercio~~ — **respondido el 04/09** con dato del terreno:
   **problemas de calidad en Brasil** (sección 2c). Corroborado por el clima: verano
   2026 fue el más caluroso de la serie. Falta *medir* la calidad para cerrarlo.
6. **Bolivia como origen nuevo** (0 → 206 t/mes): entender quién lo abrió y por qué.
   Almar y Ciro Gentile ya operan ahí.
7. **Registro numérico de calidad por lote** — es lo que falta para convertir la
   hipótesis del calor en una señal de compra anticipada. Ver hilo de trazabilidad /
   vida verde.

---

## 9. ⚠️ Trampa nueva: cultura es-UY rompe los CSV

Esta máquina está en cultura **es-UY** (separador decimal = coma). `Export-Csv`
escribe los doubles con coma (`90159,99`) y al releerlos con cultura invariante esa
coma se interpreta como separador de miles: **90.159,99 kg → 9.015.999 kg**, inflado
~100×. Pasó el 04/09 y dio un primer cruce por importador completamente falso
(ALMAR/Paraguay enero daba 9.206 t cuando el total del mes fue 519 t).

**Regla:** para análisis, leer el xlsx **directo** (el XML de xlsx siempre usa punto
decimal, o sea `InvariantCulture` es lo correcto ahí) y no pasar por CSV. Si hay que
usar CSV sí o sí, exportar e importar con la misma cultura explícita.

---

## Nota técnica sobre el decodificador

`penta\decodificar_pdf_penta.ps1` (rescatado de `%TEMP%` y corregido el 03/09/2026):

- Los PDFs de Penta guardan texto en UTF-16BE con las fuentes subset desplazadas **+28**.
  Excepciones que no siguen el +28: `0x62='$'`, `0x74='%'`, `0x0267='á'`, `0x0273='í'`,
  `0x0278='ó'`, `0x026D='é'`.
- **Bug corregido 1:** la detección de zlib estaba hardcodeada a que el primer byte fuera
  `0x78`. Penta también emite `0x48` y `0x68` (ventanas más chicas). Ahora valida la
  cabecera zlib de verdad (nibble bajo = 8 y `(b0<<8|b1) % 31 == 0`) y prueba los dos
  offsets. Por esto los 2 PDFs viejos daban "sin stream de texto".
- **Bug corregido 2:** cortaba en el primer content stream. Los reportes vienen partidos
  en varios bloques; ahora los procesa todos.
- **Al leer la salida:** el corte entre bloques puede separar una etiqueta de su valor
  (p. ej. "Kgs. Brutos" en un bloque y el número en el siguiente). Empalmar bloques
  consecutivos al transcribir.
