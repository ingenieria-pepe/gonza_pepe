<!-- Copia del handoff que escribio el Claude del servidor (Uruguay) el 04/10/2026 para la sesion 'Corte de Banana' de Aloha. Gonzalo lo dejo en Descargas y pidio publicarlo aca. Se omitio una sola linea (ver mas abajo). -->

# Handoff — Control de corte de banana (04/10/2026)

Contexto para la sesión «Corte de Banana». Otra sesión trabajó sobre tu feature hoy.
Todo quedó en ramas propias, **nada mergeado**. Leé esto antes de tocar `cortes.py`,
`corte_reader.py`, `CorteTab.tsx` o `ControlCorteModal.tsx`.

---

## 1. Lo que cambió (3 ramas, ninguna mergeada)

### `Ingenieria/corte-contexto-y-matcheo` (nacida de `origin/main`)
PRs: back [#486 → main](https://github.com/Bananubis/back-almar-erp/pull/486),
front [#448 → main](https://github.com/Bananubis/front-almar-erp/pull/448).

- **back `pie_por_etiqueta`**: se fueron los dos `… or candidatos`. La placa y la
  fecha del QR ahora **descartan** en vez de desempatar. Si el ticket contradice al
  registro del camión no se sugiere nada y el operario elige a mano.
  Era la causa de las tres placas y la fecha que salieron mal, y del corte de
  SUPREMA del 25/09 que quedó en el pie #249 (del 17/09).
- **front `CorteTab`**: el análisis ahora manda `pie_camion_id` cuando el camión ya
  está elegido (por el QR o a mano), así `_contexto_pie` corre de verdad.
  Ojo: va con spread condicional, porque hay un test que exige que la clave **no**
  esté cuando todavía no hay camión (`not.toHaveProperty("pie_camion_id")`).

### `Ingenieria/corte-contexto-y-matcheo-testing` (nacida de `origin/testing`)
Los mismos dos commits cherry-pickeados. PRs: back [#487 → testing](https://github.com/Bananubis/back-almar-erp/pull/487),
front [#449 → testing](https://github.com/Bananubis/front-almar-erp/pull/449).
Ver §3 sobre por qué hace falta una rama aparte.

### `Ingenieria/cortes-contexto-producto-mover` (nacida de `origin/main`)
Sin PR todavía. Tres commits:

1. **`_contexto_pie` enriquecido.** Antes mandaba 3 cosas (código de camión,
   exportador, 6 temperaturas). Ahora manda además: `productor` (que **no** es el
   exportador — el pie tiene las dos columnas y se mandaba la equivocada bajo la
   etiqueta «Productor / proveedor»), `marca`, `fecha_carga`, `fecha_descarga`,
   `dias_transito` ya calculado, `gradiente_pulpa` ya resuelto, `calibre_pie`,
   `longitud_pie`, `peso_caja_pie`, y `corona_pie`/`quemada_pie`/`rameada_pie`.
   Las etiquetas nuevas están en `corte_reader._contexto`.
   `_num()` recorta los ceros de los `numeric` (venían `39.00` y le sugerían a la
   IA dos decimales que nadie midió).
2. **`elegirPie` trae la fruta del camión.** Sólo el camino del ticket
   (`aplicarTicket`) lo hacía; elegir el camión a mano dejaba `producto` en Banana,
   así que una palta elegida a mano se analizaba con la guía UAM y se guardaba como
   Banana. Mismo modo de falla que PYMS022. Hay un cartel nuevo para el caso
   residual (fruta pisada a mano, o lectura ya hecha).
3. **Mover un corte al pie correcto** (mig **0228**). `PATCH /pie-camion/{pdc_id}/cortes/{corte_id}`
   con `{pie_camion_id}`. Columnas nuevas `movido_de_pie_id` / `movido_en` /
   `movido_por_usuario_id`. Reenvía **los dos** pies a maduración. Front: «Mover a
   otro camión» en cada corte del Historial.
   `SelectorPie` se movió a `components/SelectorPie.tsx` — estaba dentro de
   `CorteTab`, que ya importa de `ControlCorteModal`, así que usarlo desde el modal
   cerraba un ciclo de imports.

---

## 2. Cosas que creías y ya no son así

- **El botón «Corte» del Historial ya no analiza.** Tiene 0 llamadas a
  `analizarCorte` en `origin/main` **y** en `origin/testing`: el commit `de64d18` lo
  convirtió en visor. El hallazgo «el botón del Historial no manda `producto`» es
  viejo. Sobrevive sólo en `Ingenieria/pizarron-stock-testing`, que es una rama
  vieja — si leés el worktree `AlohaProd/front-almar-erp` vas a ver el código de
  antes y te vas a confundir.
- **`dedos_cortados` ya no default 3.** Es `Field(default=None)` en el back y el
  front manda `null`. Ese hallazgo está resuelto desde antes.
- **El webhook de cortes a maduración ya está en `main`** (34 menciones en
  `webhook.py`), y `crear_corte` hace `background_tasks.add_task(webhook.enviar_corte, pdc_id)`.

## Datos que NO existen (no los busques)

- **No hay columna `cinta`** en ninguna tabla de `ext`. El prompt UAM pide la semana
  de cinta («cuando puedas, pedí la semana de cinta del lote») y es el único dato de
  la lista que la IA va a seguir teniendo que pedir. Para mandarla hace falta una
  migración que la cargue en el pie.
- **No hay número de lote ni identificador de pallet** en `ext.pie_de_camion`. Sólo
  `palet_rating` y `palet_comentario`, que son calificaciones de cómo venían los
  pallets. El pedido «lote y pallet desde el registro del camión» no se puede
  cumplir con los valores: lo único autoritativo del registro es la identidad del
  camión (código de importador, placa, fecha), y eso es lo que se hizo manda.
- `corona` / `quemada` / `rameada` son `Literal["Regular","Buena","Muy buena"]`:
  **calificaciones**, no texto libre. Mandarles "sana" da 422.

---

## 3. Trampas del repo (me costaron tiempo, te las ahorro)

- **`main` y `testing` están DIVERGIDAS.** `testing` tiene 38 commits (back) / 47
  (front) que `main` no tiene, y `main` tiene 13 / 23 que `testing` no.
  Una rama nacida de `main` **no sirve** para un PR a `testing`: arrastra los
  commits de main que testing no tiene (trabajo de Lucas y de Coru29).
  Y **no sale CONFLICTING** — sale `MERGEABLE`, nada avisa. Lo que delata es el
  tamaño: 29 y 76 archivos cambiados cuando el cambio propio eran 2.
  Chequeá `gh pr view <n> --json changedFiles,commits` recién creado el PR.
  La salida es la hija: `git switch -c <rama>-testing origin/testing` + cherry-pick.
- **La ventana del reloj.** Entre las 21:00 y las 03:20 UY el gate de tests del
  deploy falla sin que nada esté roto: el runner de CI (UTC) y `CURRENT_DATE` de
  Postgres ya están en «mañana» mientras la app corta en hora de Uruguay. El PR
  #181 de Lucas lo arregla y sigue abierto. **No mergees en esa ventana**, y de
  03:20 a 06:00 el deploy cae sobre la operativa.
- **Tests en esta PC Windows**: `TEST_PG_PORT=55432` (container `aloha-test-pg`),
  venv por worktree + `pip install tzdata`. Fallos **preexistentes** que no son
  tuyos: back 18 (tests de scripts `.sh` y export/restore), front 10 (el choque de
  mayúsculas `EvidenciasDescarte.tsx` / `evidenciasDescarte.ts`, que rompe
  `MovimientoManualModal`). Para juzgar tsc:
  `npx tsc -b | grep "error TS" | grep -v MovimientoManualModal`.
- **La migración 0227 está tomada** por `Coru29/inv-ciclico` sin commitear. Por eso
  la de mover es la **0228**. El runner ordena por nombre y no exige contigüidad.
- Los `.ps1` que escribas para parchear: guardalos con BOM o corrélos con `pwsh`,
  no con `powershell.exe` — PS 5.1 lee UTF-8 sin BOM como ANSI y te rompe los
  acentos de los here-strings.

---

## 4. Reglas del proyecto que aplican acá

- **Nunca prod.** Ninguna escritura contra Macrosoft prod ni BDEspejo.
- **No `git push` sin pedido**, y **CONSULTAR SIEMPRE antes de mergear** a `testing`
  o `main`. Orden pedido por el dueño: `testing` back → `testing` front → `main`
  back → `main` front, esperando el deploy de cada uno.
- **NUNCA `Co-Authored-By`** ni ningún trailer de autoría en los commits.
- Una rama que absorbió `testing` queda **inhabilitada** para `main`.
- Feature nueva ⇒ tests nuevos, y la suite completa del repo tocado verde antes de
  commitear (el deploy tiene gate de CI).

---

## 5. Lo que queda abierto

**Del pedido original, sin hacer:**
- **Cerrar el ciclo en cámara**: cámara asignada, fecha de gas, fecha en que rompió
  solo, color al despacho y merma por lote. Los cortes ya viajan a maduración; falta
  la vuelta, y eso vive en **CloudPepeV2**, no en Aloha. Es un proyecto aparte.
- **Semana de cinta**: necesita migración (ver §2).

**Hallazgos del review del 29/09 que siguen vivos:**
- El código que transcribe la IA se usa aunque reporte **confianza baja**
  (`_sugerir` en `cortes.py` sólo chequea `visible` y `codigo`).
- Cambiar la foto o la fruta después de analizar deja el puntaje viejo y lo guarda
  como `lectura_fuente='manual'`.
- `analisis_ia` / `lectura_modelo` los manda el navegador al guardar: la «lectura
  original de la IA» no la garantiza el server.
- Opus 5 sin `effort`, con thinking dentro de `max_tokens` 8000; `stop_reason:
  max_tokens` cae como JSON inválido. Timeouts: Cloudflare 100 s < httpx 120 s <
  nginx 150 s.
- (dato de seguridad omitido en el repo público: una URL de la cámara en vivo responde sin credenciales; está en el original que tiene Gonzalo)
  credenciales**.

**Dato de negocio sin resolver:** el corte de SUPREMA del 25/09 **sigue guardado en
el pie equivocado** (#249). Con la mig 0228 ya se puede mover desde el Historial,
pero hay que hacerlo a mano cuando salga a prod.
