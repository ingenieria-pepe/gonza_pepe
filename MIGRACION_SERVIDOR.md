# 🍌 Pipeline Banana Almar — Guía de migración al servidor

Este documento explica **qué es este proyecto, cómo funciona y cómo dejarlo corriendo solo
en la PC-servidor** (la que tiene UPS, BIOS que prende sola, etc.), para que deje de depender
de la laptop personal.

> **TL;DR / apurado:**
> 1. Copiá esta carpeta entera al servidor (a donde quieras, p. ej. `C:\poronga`).
> 2. Abrí PowerShell **como Administrador** y corré `setup_servidor.ps1`.
> 3. Listo: corre solo **miércoles 12:00 y viernes 19:00**.
>
> Ya **no** hace falta Excel instalado ni auto-login (ver §6 y §12).

---

## 0. Estado actual (04/08/2026)

**Instalado y corriendo en esta PC:**

| Ítem | Valor |
|---|---|
| Equipo | `DESKTOP-NVE8NNB` |
| Carpeta | `C:\Users\User\Desktop\poronga_servidor` |
| Tarea programada | `Cepea_ActualizarPrecios_Almar` — Mié 12:00 + Vie 19:00 |
| Corre como | `DESKTOP-NVE8NNB\User`, **LogonType S4U** (con o sin sesión iniciada) |
| Lector de `.xlsx` | **ImportExcel 7.8.10** (EPPlus) — sin Excel instalado |
| WhatsApp | `enabled: true`, 3 números, canal Whapi `DAREDL-9FA6E` (remitente `59892284457`) |

Antes de esto el pipeline había quedado mudo desde el **24/07/2026** (última corrida en la
laptop): esta PC no tiene Excel, así que las fases `[2/6]` y `[3/6]` no podían correr.

---

## 1. Qué hace este sistema

Es un **pipeline semanal** que:

1. Baja precios de banana de 4 mercados (Brasil, Ecuador, Paraguay, +clima).
2. Procesa las **cargas/compras de Almar** del año (planilla que vos editás).
3. Calcula indicadores (score de oportunidad de compra, zona estacional, spread, forecast).
4. Inyecta todo en los **dashboards HTML** (los `index_*.html`).
5. Manda **alertas y un resumen semanal por WhatsApp** (vía Whapi.cloud) a los números configurados.

Todo esto lo dispara **una tarea programada de Windows** dos veces por semana.
Hoy corre en la laptop; el objetivo es moverlo al servidor que está siempre prendido.

---

## 2. Requisitos del servidor

| Requisito | Detalle | Obligatorio |
|---|---|---|
| **Windows 10/11** (o Server) | Con Task Scheduler | ✅ |
| **PowerShell 5.1+** | Viene con Windows | ✅ |
| **Módulo `ImportExcel`** | Lee los `.xlsx` (Cepea + cargas) sin Excel. Lo instala solo el setup. Ver §6. | ✅ |
| **Internet** | Sin proxy que bloquee las fuentes (§8) | ✅ |
| Permisos de admin | Solo para *instalar* la tarea (una vez) | ✅ (setup) |
| ~~Microsoft Excel~~ | **Ya no hace falta** (§6) | ❌ |
| ~~Auto-login~~ | **Ya no hace falta**: la tarea corre S4U (§5) | ❌ |

> ✅ El pipeline es **headless**: no necesita Office ni una sesión de escritorio abierta.
> Alcanza con que la PC esté prendida y con internet a la hora del disparo.

---

## 3. Instalación paso a paso (en el servidor)

### 3.1 Copiar la carpeta
Copiá **toda esta carpeta** al servidor. La ruta ya **no está hardcodeada**: el script
detecta solo dónde está parado (`$PSScriptRoot`), así que podés ponerla donde quieras:

```
C:\poronga\           ← recomendado (corto y sin espacios)
D:\banana\poronga\    ← o donde te quede cómodo
```

Podés renombrar la carpeta a `poronga` si querés; no afecta nada.

### 3.2 Correr el instalador
1. Abrí **PowerShell como Administrador** (click derecho → *Ejecutar como administrador*).
2. Permití scripts en esta sesión y corré el setup:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& "C:\poronga\setup_servidor.ps1"
```

El instalador:
- Verifica PowerShell, **ImportExcel** (lo instala si falta), internet y la config de WhatsApp.
- Copia `ImportExcel` a los paths de módulos de **PS 5.1** y **AllUsers**, así lo ve
  el PowerShell que ejecuta la tarea sin importar el perfil.
- Registra la tarea programada **`Cepea_ActualizarPrecios_Almar`** (Mié 12:00 + Vie 19:00),
  con **LogonType S4U** (corre con o sin sesión iniciada). Si S4U falla, cae a Interactive.
- Es **idempotente**: podés correrlo las veces que quieras.

### 3.3 Probar
```powershell
Start-ScheduledTask -TaskName 'Cepea_ActualizarPrecios_Almar'
```
o correr el pipeline a mano y ver toda la salida en pantalla:
```powershell
& "C:\poronga\actualizar_precios.ps1"
```
Mirá que termine sin errores rojos y que llegue (o no, según ventana de silencio) el WhatsApp.

---

## 4. Cómo funciona (la lógica, por dentro)

El corazón es **`actualizar_precios.ps1`**. Corre en fases:

| Fase | Qué hace | Fuente / salida |
|---|---|---|
| `[1/6]` Cepea | Baja el `.xlsx` semanal de precios Brasil (Nanica 1ª productor, Norte SC) | `hfbrasil.org.br` → `fuentes/precios_banana_SC_2023-2026.xlsx` |
| `[2/6]` Parseo | Lee el xlsx con **ImportExcel** y arma la serie de precios + promedios mensuales | → objeto en memoria |
| `[3/6]` Cargas | Lee `fuentes/cargas 2026.xlsx` con **ImportExcel** (tus compras por productor) | → métricas Almar |
| `[clima]` | Clima actual + pronóstico 7 días de las zonas productoras | `api.open-meteo.com` |
| `[pro]` | Histórico diario + correlación clima↔precio + forecast 4 semanas | `power.larc.nasa.gov` (NASA POWER), fallback Open-Meteo, cache en `fuentes/clima_archive_cache/` |
| `[py]` | Precio banana Carape en Mercado de Abasto Asunción | `preciosdelagro.com` → `fuentes/precios_py_cache.json` |
| `[4/6]` Sidecar | Escribe todo a `fuentes/precios_cepea.json` | JSON |
| `[5/6]` Inyección | Mete el JSON dentro de los HTML (entre `/*__CEPEA_JSON__*/` y `/*__END__*/`) | `index.html`, `index_brasil.html`, `index_paraguay_bolivia.html` |
| `[ec]` Ecuador | Precio FOB Ecuador (scraping público, sin login) | `tridge.com` → `fuentes/precios_ecuador.json` → `index_ecuador.html` |
| `[6/6]` + `[WA]` | Evalúa alertas y manda WhatsApp (resumen semanal, movimientos de precio, clima severo, etc.) | `gate.whapi.cloud` |

Detalles clave:
- **Anti-suspensión:** al arrancar llama a `SetThreadExecutionState` para que Windows no se
  duerma a mitad de la corrida (fix histórico de la laptop; en el servidor con UPS no molesta).
- **Ruta portable:** `$base = $PSScriptRoot` — se adapta sola a la ubicación de la carpeta.
- **Resumen semanal:** se dispara los **miércoles y viernes**, o si pasaron **≥3 días** sin
  mandar uno. Hay una **ventana de silencio de 6 h** (`min_silence_hours`) para no spamear.
- **Estado:** `fuentes/state_whatsapp.json` y `state_alertas.json` recuerdan qué se mandó y
  cuándo. **Viajan con la carpeta**, así que al mudarte NO se re-dispara todo de golpe.

---

## 5. Sesión de usuario — ya no hace falta auto-login

La tarea está registrada con **`LogonType S4U`**: *“Ejecutar tanto si el usuario inició sesión
como si no”*, **sin guardar la contraseña**. Como el pipeline ya no abre Excel, no necesita
escritorio: corre igual con la PC prendida y nadie logueado.

Requisitos que quedan:
- La PC **prendida** (o que despierte: la tarea tiene `WakeToRun`).
- **Internet** a la hora del disparo.
- Si el disparo se pierde (PC apagada), `StartWhenAvailable` la corre apenas vuelve.

> **Auto-login** (`netplwiz`) ya **no** es necesario. Si igual lo querés activar por otros
> motivos, no molesta.

---

## 6. Lectura de `.xlsx` — ImportExcel (sin Excel)

El script leía los 2 `.xlsx` (Cepea y cargas) con **Excel vía COM**, lo que obligaba a tener
Office instalado + sesión de escritorio. **Desde el 04/08/2026 usa `ImportExcel` (EPPlus)**:

```powershell
Install-Module ImportExcel -Scope CurrentUser -Force   # el setup lo hace solo
```

Qué cambió en el código (`actualizar_precios.ps1`):

| Antes (COM) | Ahora (ImportExcel) |
|---|---|
| `New-Object -ComObject Excel.Application` | `Open-ExcelPackage -Path $xlsx` |
| `$wb.Worksheets.Item(1)` | `$pkg.Workbook.Worksheets \| Select-Object -First 1` |
| `$ws.UsedRange.Rows.Count` | `$ws.Dimension.End.Row` |
| `$ws.Cells.Item($r,$c).Text` | `$ws.Cells[$r,$c].Text` |
| `$excel.Quit()` + `ReleaseComObject` | `Close-ExcelPackage $pkg -NoSave` |

Se verificó **paridad de datos** contra la última corrida con Excel: mismas 297 operaciones,
21 semanas, 15 productores, y la misma serie Cepea.

> ⚠️ **Ojo con el encoding al editar el `.ps1`:** tiene que quedar **UTF-8 CON BOM**. Si se
> guarda sin BOM, Windows PowerShell 5.1 lo lee como ANSI, rompe los emojis del script y
> falla el parseo antes de arrancar.

---

## 7. Configuración de WhatsApp (`config/whatsapp.json`)

```json
{
  "enabled": true,
  "phones": ["59899244062", "554799028111", "59896663167"],
  "token": "····",                 // token de Whapi.cloud (sensible, no compartir)
  "min_silence_hours": 6,          // ventana anti-spam por tipo de alerta
  "alerts": { "criticas_compra": true, "movimientos_precio": true,
              "clima_severo": true, "resumen_semanal": true, "precio_py": true }
}
```

- **Números:** internacional, solo dígitos, **sin `+`**.
- ⚠️ **Quirk Brasil:** los números de Brasil van **sin el “9” extra** del celular
  (así está cargado `554799028111`). Si agregás uno nuevo de Brasil y no llega, probá sin el 9.
- **Apagar WhatsApp:** poné `"enabled": false` y el pipeline sigue corriendo sin mandar nada.
- **Rotar token:** si Whapi lo regenera, reemplazá `token` en este archivo. El número remitente
  está atado al *channel* del token (no hay QR ni reconexión).
- El token viaja dentro de esta carpeta: **tratala como sensible** (no la subas a nada público).

---

## 8. Fuentes de datos (para whitelist de firewall)

| País / dato | Host | Notas |
|---|---|---|
| 🇧🇷 Cepea (precio Brasil) | `www.hfbrasil.org.br` | xlsx semanal, publica **viernes** tarde |
| 🌤️ Clima actual + forecast | `api.open-meteo.com` | gratis, sin key |
| 🌡️ Clima histórico | `power.larc.nasa.gov` | NASA POWER (fallback: `archive-api.open-meteo.com`) |
| 🇵🇾 Carape (precio Paraguay) | `preciosdelagro.com` | datos SIMA-MAG |
| 🇪🇨 FOB Ecuador | `www.tridge.com` | público, sin login; rezago ~2 semanas |
| 📱 WhatsApp | `gate.whapi.cloud` | gateway de mensajes |

Si el servidor tiene firewall corporativo, habilitá salida **HTTPS (443)** a esos hosts.

---

## 9. Estructura de la carpeta

```
poronga_servidor/
├─ actualizar_precios.ps1     ← script principal (PORTABLE, ya parcheado)
├─ setup_servidor.ps1         ← instalador de la tarea (NUEVO, correr en el server)
├─ MIGRACION_SERVIDOR.md      ← este documento
├─ README.txt                 ← notas originales del proyecto
├─ index*.html                ← dashboards (se auto-actualizan en cada corrida)
├─ config/
│   └─ whatsapp.json          ← token + números Whapi
├─ fuentes/                   ← DATOS VIVOS del pipeline
│   ├─ cargas 2026.xlsx       ← ✍️ TUS compras del año (lo editás vos)
│   ├─ precios_*.json         ← sidecars que se inyectan en los HTML
│   ├─ state_*.json           ← memoria de qué WhatsApp se mandó (viaja con la carpeta)
│   └─ clima_archive_cache/   ← cache histórico de clima
├─ guia_corte/                ← control de calidad del dedo (no lo usa el pipeline)
└─ archivo/                   ← histórico / referencia (no lo usa el pipeline)
```

---

## 10. Mantenimiento y uso diario

- **Cargar compras:** editás `fuentes/cargas 2026.xlsx` como siempre; la próxima corrida lo levanta.
- **Ver dashboards:** abrí los `index_*.html` en el navegador del servidor (o compartí la carpeta).
- **Forzar una corrida:** `Start-ScheduledTask -TaskName 'Cepea_ActualizarPrecios_Almar'`.
- **Ver la última corrida:** `last_run.log` (stdout de la última) y `alertas.log` (histórico de alertas).
- **Cambiar horarios:** editá los triggers en el Task Scheduler, o cambiá `setup_servidor.ps1` y recorré el setup.

---

## 11. Troubleshooting

| Síntoma | Causa probable | Solución |
|---|---|---|
| La fase `[2/6]` o `[3/6]` falla | Falta el módulo `ImportExcel` en el PowerShell que corre la tarea | `Install-Module ImportExcel -Scope CurrentUser -Force` y recorrer `setup_servidor.ps1` |
| El `.ps1` no arranca: *“literal de hash incompleto”*, emojis rotos | El archivo quedó guardado **sin BOM** y PS 5.1 lo lee como ANSI | Reguardarlo como **UTF-8 con BOM** (§6) |
| Un scraping falla con *“Referencia a objeto no establecida”* (NullReference) | `Invoke-WebRequest` sin `-UseBasicParsing` en una PC sin Internet Explorer | Agregar `-UseBasicParsing` a esa llamada (§12) |
| La tarea existe pero “nunca corrió” headless | Quedó registrada como Interactive y no hay login | Recorrer `setup_servidor.ps1` como admin (registra S4U) |
| `Register-ScheduledTask` da error de permisos | PowerShell sin admin | Reabrir PowerShell **como Administrador** y recorrer `setup_servidor.ps1` |
| No llega WhatsApp | `enabled:false`, token vencido, o ventana de silencio (6 h) | Revisar `whatsapp.json`; si es Brasil, probar **sin el 9** |
| No baja Cepea | Firewall / host caído / aún no publicaron (antes del viernes) | Ver §8; reintentar el viernes a la tarde |
| Los HTML no se actualizan | Falló una fase previa antes de la inyección `[5/6]` | Correr a mano y leer el error en pantalla |
| Mensajes con caracteres raros (mojibake) | Encoding | Ya está resuelto: el script fuerza UTF-8 al mandar |

---

## 12. Qué cambió respecto de la laptop

**Migración original:**
- ✅ **Ruta portable:** `actualizar_precios.ps1` ya **no** apunta a `C:\Users\Usuario\Desktop\poronga`;
  usa `$PSScriptRoot` (funciona en cualquier ruta/PC).
- ✅ **Nuevo `setup_servidor.ps1`:** registra la tarea con los mismos horarios y settings.
- ✅ **Nuevo `MIGRACION_SERVIDOR.md`:** este documento.

**Puesta en marcha en `DESKTOP-NVE8NNB` (04/08/2026):**
- ✅ **Adiós Excel COM** → `ImportExcel`/EPPlus. El pipeline es headless (§6). Paridad de
  datos verificada contra la última corrida con Excel.
- ✅ **Adiós auto-login** → tarea con `LogonType S4U`, corre con o sin sesión iniciada (§5).
- ✅ **Fix scraping Paraguay:** `Invoke-WebRequest` a `preciosdelagro.com` no llevaba
  `-UseBasicParsing`. En la laptop andaba porque tenía el motor de Internet Explorer; en esta
  PC (Win 11 sin IE) tiraba `NullReferenceException` y el precio PY quedaba **pegado al cache
  viejo** en silencio (el `catch` lo tapaba). Con el flag vuelve a traer dato fresco.
- ✅ **`setup_servidor.ps1`** ahora verifica/instala `ImportExcel` en vez de Excel, y lo copia
  a los paths de PS 5.1 y AllUsers.

Todo lo demás (lógica de score, alertas, dashboards, fuentes, config, datos) es **idéntico**.

---

*Generado para Almar S.R.L. · Cualquier duda o para migrar a ImportExcel (headless), pedímelo.*
