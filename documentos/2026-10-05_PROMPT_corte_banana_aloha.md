<!-- Copia del documento que escribio el Claude del servidor (Uruguay) el 05/10/2026 para la sesion 'Corte de Banana' de Aloha. Reemplaza al handoff del 04/10 (todo mergeado y deployado). Gonzalo lo dejo en Descargas y pidio publicarlo; se copia tal cual (el propio documento omite la direccion de la camara). -->

Trabajé sobre el control de corte de banana la noche del 04 al 05/10/2026. **Todo
está mergeado y deployado en `testing` y en `main`**, y las ramas ya se borraron.
Esto reemplaza el handoff anterior (`HANDOFF_corte_banana_2026-10-04.md`), que decía
"nada mergeado" y quedó viejo.

Leé esto antes de tocar `cortes.py`, `corte_reader.py`, `CorteTab.tsx`,
`ControlCorteModal.tsx` o `SelectorPie.tsx`.

---

## Qué está en producción ahora (9 PR, todos los deploys verdes)

**Back** — `#486`/`#487` (matcheo), `#488`/`#489` (contexto + mover):

1. **`pie_por_etiqueta` ya no elige un camión que el ticket contradice.** Se fueron
   los dos `… or candidatos`: la placa y la fecha del QR ahora **descartan** en vez
   de desempatar. Si ninguna coincide, no se sugiere nada y el operario elige a
   mano. Era la causa de las tres placas y la fecha que salieron mal, y del corte de
   SUPREMA del 25/09 que quedó en el pie #249 (del 17/09).

2. **`_contexto_pie` manda mucho más.** Antes: código de camión, exportador y las 6
   temperaturas. Ahora además: `productor` (que **no** es el exportador — el pie
   tiene las dos columnas y se mandaba la equivocada bajo la etiqueta «Productor /
   proveedor»), `marca`, `fecha_carga`, `fecha_descarga`, `dias_transito` ya
   calculado, `gradiente_pulpa` ya resuelto, `calibre_pie`, `longitud_pie`,
   `peso_caja_pie`, y `corona_pie`/`quemada_pie`/`rameada_pie`. Las etiquetas están
   en `corte_reader._contexto`. `_num()` recorta los ceros de los `numeric` (venían
   `39.00` y sugerían dos decimales que nadie midió).

3. **Mover un corte al pie correcto — mig 0228, ya aplicada en prod.**
   `PATCH /pie-camion/{pdc_id}/cortes/{corte_id}` con `{pie_camion_id}`. Columnas
   `movido_de_pie_id` / `movido_en` / `movido_por_usuario_id`. Valida que el corte
   sea de ese pie, que el destino exista, que no esté anulado y que no sea el mismo.
   Reenvía **los dos** pies a maduración. `movido_de_pie_id` va **sin FK** a
   propósito: es auditoría y sobrevive al borrado del pie (el FK de `pie_camion_id`
   es `ON DELETE CASCADE`). **No hay DELETE** y fue decisión explícita: borrar un
   corte destruye evidencia de una descarga.
   La migración es la **0228** y no la 0227 porque esa la tiene `Coru29/inv-ciclico`
   sin commitear.

**Front** — `#448`/`#449`, `#450`/`#451`, `#452`:

4. **`CorteTab` manda `pie_camion_id` al analizar** cuando el camión ya está elegido.
   Antes `_contexto_pie` nunca corría por la pestaña. Va con **spread condicional**:
   hay un test que exige que la clave NO esté cuando todavía no hay camión.

5. **`elegirPie` trae la fruta del camión.** Sólo el ticket lo hacía; elegir el
   camión a mano dejaba `producto` en Banana, así que una palta elegida a mano se
   analizaba con la guía UAM y se guardaba como Banana — el modo de falla de
   PYMS022. Hay un cartel nuevo para cuando la fruta elegida no es la del camión.

6. **«Mover a otro camión»** en cada corte del Historial, con el selector de pie, y
   el corte movido dice de dónde vino.

7. **`SelectorPie` salió a `components/SelectorPie.tsx`.** Estaba dentro de
   `CorteTab`, que ya importa `Lectura` de `ControlCorteModal`, así que usarlo desde
   el modal cerraba un **ciclo de imports**. `tsc` pasaba igual (ESM lo tolera) pero
   es frágil, y ahora lo usan dos pantallas.

---

## Hallazgos de la memoria que quedaron VIEJOS

- **El botón «Corte» del Historial no analiza.** Tiene 0 llamadas a `analizarCorte`
  en `main` y en `testing` desde `de64d18`: es un visor. El hallazgo «no manda
  `producto`» ya no aplica. ⚠️ Sobrevive sólo en la rama
  `Ingenieria/pizarron-stock-testing` — si leés el worktree
  `AlohaProd/front-almar-erp` vas a ver el código de antes y te vas a confundir.
- **`dedos_cortados` ya no es default 3.** Es `Field(default=None)` y el front manda
  `null`.

## Datos que NO existen (no los busques)

- **No hay columna `cinta`** en ninguna tabla de `ext`. El prompt UAM pide la semana
  de cinta («cuando puedas, pedí la semana de cinta del lote») y es el único dato de
  la lista original que la IA va a seguir pidiendo. Mandarla necesita una migración.
- **No hay número de lote ni identificador de pallet** en `ext.pie_de_camion`; sólo
  `palet_rating` y `palet_comentario`, que son calificaciones de cómo venían los
  pallets. El pedido «lote y pallet desde el registro del camión» no se puede
  cumplir con los valores: lo único autoritativo del registro es la identidad del
  camión (código de importador, placa, fecha), y eso ya es lo que manda.
- `corona` / `quemada` / `rameada` son `Literal["Regular","Buena","Muy buena"]`:
  **calificaciones**, no texto libre. Mandarles "sana" da 422.

---

## Trampas del repo que me costaron tiempo

- **`main` y `testing` están DIVERGIDAS.** Una rama nacida de `main` **no sirve** para
  un PR a `testing`: arrastra los commits de main que testing no tiene (trabajo de
  Lucas y de Coru29). Y **no sale CONFLICTING**, sale `MERGEABLE` — nada avisa. Lo
  que delata es el tamaño: 29 y 76 archivos cambiados cuando el cambio propio eran 2.
  Chequeá `gh pr view <n> --json changedFiles,commits` recién creado el PR.
  La salida es la hija: `git switch -c <rama>-testing origin/testing` + cherry-pick.
- **Trabajo apilado:** si tenés dos tandas que tocan los mismos archivos, cuando
  mergeás la primera la segunda necesita `git merge origin/<base>` y resolver. A la
  hija se le mergea `origin/testing`; a la madre, `origin/main`. Nunca cruzado.
- **`src/shared/coloresTailwind.test.ts` no lo dispara ningún módulo.** Usé
  `pepe-azul` y la paleta lo llama **`blue`** (`blue`, `blue-dark`, `blue-light`,
  `yellow`, `yellow-soft`, `surface`, `border`). Tailwind no avisa: no genera la
  clase y el botón sale **invisible**. Me tiró rojo el gate del deploy. Corré
  `npx vitest run` completo antes de commitear front, no sólo el módulo.
- **La ventana del reloj:** entre las 21:00 y las 00:00 UY el gate del deploy falla
  sin que nada esté roto (el runner en UTC ya está en «mañana» mientras la app corta
  en hora de Uruguay). Pasada la medianoche UY se cierra sola. El PR #181 de Lucas lo
  arregla y sigue abierto.
- **Tests en la PC Windows de Ingeniería:** `TEST_PG_PORT=55432` (container
  `aloha-test-pg`), venv por worktree + `pip install tzdata`. Fallos **preexistentes
  que no son tuyos**: back 18 (tests de scripts `.sh` y export/restore), front 10 (el
  choque de mayúsculas `EvidenciasDescarte.tsx` / `evidenciasDescarte.ts`, que rompe
  `MovimientoManualModal`). Para juzgar tsc:
  `npx tsc -b | grep "error TS" | grep -v MovimientoManualModal`.
- Los `.ps1` que escribas para parchear: corrélos con `pwsh`, no con
  `powershell.exe` — PS 5.1 lee UTF-8 sin BOM como ANSI y te rompe los acentos.

---

## Reglas del proyecto

- **Nunca prod.** Ninguna escritura contra Macrosoft prod ni BDEspejo.
- **No `git push` sin pedido**, y **CONSULTAR SIEMPRE antes de mergear** a `testing`
  o `main`. Orden que pide el dueño: `testing` back → `testing` front → `main` back
  → `main` front, esperando el deploy de cada uno.
- **NUNCA `Co-Authored-By`** ni ningún trailer de autoría en los commits.
- Una rama que absorbió `testing` queda **inhabilitada** para `main`.
- `delete_branch_on_merge=false`: las ramas se borran a mano, al final.
- Feature nueva ⇒ tests nuevos, y la suite **completa** del repo tocado verde antes
  de commitear.

---

## Lo que queda abierto

**Del pedido original:**
- **Cerrar el ciclo en cámara**: cámara asignada, fecha de gas, fecha en que rompió
  solo, color al despacho y merma por lote. Los cortes ya viajan a maduración por el
  webhook; falta la vuelta, y eso vive en **CloudPepeV2**, no en Aloha. Es un
  proyecto aparte, no un fix.
- **Semana de cinta**: necesita migración (ver arriba).

**Hallazgos del review del 29/09 que siguen vivos:**
- El código que transcribe la IA se usa aunque reporte **confianza baja** (`_sugerir`
  sólo chequea `visible` y `codigo`).
- Cambiar la foto o la fruta después de analizar deja el puntaje viejo y lo guarda
  como `lectura_fuente='manual'`.
- `analisis_ia` / `lectura_modelo` los manda el navegador al guardar: la «lectura
  original de la IA» no la garantiza el server.
- Opus 5 sin `effort`, thinking dentro de `max_tokens` 8000; `stop_reason:
  max_tokens` cae como JSON inválido. Timeouts: Cloudflare 100 s < httpx 120 s <
  nginx 150 s.
- **Seguridad:** el vivo de la cámara del carrito responde **200 sin usuario ni
  clave**, y `snapshot.jpg` tampoco pide login. La dirección exacta no va en este
  archivo a propósito; está en la memoria privada
  (`project_control_corte_banana`). Ojo que el `<img>` del vivo va directo del
  navegador a una app que corre en la laptop de recepción, por túnel: Aloha sólo
  guarda la URL en el setting `CORTE_CAMARA_URL`. O sea que ocultarla del lado de
  Aloha **no alcanza** — el endpoint sigue abierto para quien ya la tenga. El
  arreglo real es poner auth en la app de la laptop o cerrar el túnel al público.

**Dato de negocio sin resolver:** el corte de SUPREMA del 25/09 **sigue guardado en
el pie equivocado (#249)**. Con la 0228 ya en prod se puede mover a mano desde el
Historial de ese pie; hay que hacerlo.
