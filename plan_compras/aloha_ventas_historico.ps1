# ==========================================================================
#  plan_compras\aloha_ventas_historico.ps1  -  serie larga de venta semanal de banana desde la API de Aloha (12/10/2026)
# ==========================================================================
#  Baja de Aloha (GET /stock/ventas-presentacion, el mismo informe que aloha_datos.ps1) la venta de banana por
#  semana (lunes a sabado) y por origen BR/PY/BO/EC, para TODAS las semanas completas desde que la API tiene datos
#  (semana del lunes 30/06/2025: antes de eso devuelve 0, el historial de Macrosoft no esta en la API), y la deja en
#
#    fuentes\aloha_ventas_historico.json   { generado, desde, ultima_semana, mapeo, agrupaciones_otras,
#                                            semanas: [ { semana_lunes, hasta, anio, iso_anio, iso_semana,
#                                                         BR, PY, BO, EC, otras, madera_bo, total,
#                                                         descartes: { BR, PY, BO, EC, total }, leido } ] }
#  descartes = cajas descartadas en la semana por origen (movimientos.descartes del ERP, en positivo).
#
#  Solo cajas (present): sin importes ni kilos (Gonzalo: "eso dejalo para adm, vamos a las cajas en bruto").
#  madera_bo = BR + PY + BO (lo que cuenta para el stock minimo); total = BR + PY + BO + EC; "otras" son agrupaciones
#  que empiezan con "Banana" pero no caen en los 4 origenes (Banana Colombia) y NO entran en total. "Banana San Pablo"
#  (Banana Brasil San Pablo, madera 22 kg / carton 20 kg, vendida jul-dic 2025) cuenta como BR.
#
#  Incremental: lee el JSON previo y solo pide a la API las semanas que faltan mas las ultimas -Refrescar (4) semanas
#  completas, por si el ERP ajusta ventas hacia atras. Con -Todo baja todo de nuevo. La semana en curso no se incluye
#  (esta en aloha_ventas.json con la marca parcial).
#
#  Uso:  powershell -ExecutionPolicy Bypass -File plan_compras\aloha_ventas_historico.ps1 [-Refrescar 4] [-Todo]
#  Login con config\aloha.json (gitignored), igual que aloha_datos.ps1 y el paso 3b. Solo GET (y el POST de
#  login/logout): no modifica nada en Aloha. No escribe credenciales en el log. Si config\aloha.json no esta o
#  enabled=false, sale sin error y sin tocar el JSON.
# ==========================================================================
param(
    [string]$Desde = '2025-06-30',   # primer lunes con ventas en la API (sondeo 12/10/2026)
    [int]$Refrescar = 4,             # semanas completas recientes que se vuelven a pedir aunque ya esten
    [switch]$Todo,                   # ignorar el JSON previo y bajar todo
    [string]$Salida = ''             # carpeta de salida; vacio = fuentes\ del repo
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$base    = Split-Path $PSScriptRoot -Parent
$fuentes = if ($Salida) { $Salida } else { Join-Path $base 'fuentes' }
$cfgPath = Join-Path $base 'config\aloha.json'
$outPath = Join-Path $fuentes 'aloha_ventas_historico.json'
$UA      = 'poronga/1.0'
$ahora   = Get-Date
$hoy     = $ahora.Date

function Log { param([string]$t, [string]$c = 'Gray') Write-Host "[aloha-hist] $t" -ForegroundColor $c }

if (-not (Test-Path $cfgPath)) { Log "sin config\aloha.json: no se actualiza aloha_ventas_historico.json" 'DarkYellow'; exit 0 }
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($cfg.PSObject.Properties['enabled'] -and -not $cfg.enabled) { Log "aloha deshabilitado en config\aloha.json" 'DarkYellow'; exit 0 }
if ([string]::IsNullOrWhiteSpace([string]$cfg.url)) { Log "config\aloha.json sin url" 'DarkYellow'; exit 0 }
$apiBase = ([string]$cfg.url).TrimEnd('/')

function Origen-De { param([string]$t)
    if ($t -match '(?i)bras|san pablo') { return 'BR' }; if ($t -match '(?i)parag') { return 'PY' }
    if ($t -match '(?i)boliv') { return 'BO' }; if ($t -match '(?i)ecuad') { return 'EC' }; return $null }
function Num { param($v) if ($null -eq $v -or "$v" -eq '') { return 0.0 }; return [double]$v }
function R0 { param($v) return [int][math]::Round((Num $v), 0) }
function LunesDe { param([DateTime]$d) return $d.Date.AddDays(-(([int]$d.DayOfWeek + 6) % 7)) }
function IsoSemana { param([DateTime]$lunes)   # semana ISO: la del jueves de esa semana
    $jue = $lunes.AddDays(3); $cal = [Globalization.CultureInfo]::InvariantCulture.Calendar
    return @{ anio = $jue.Year; n = $cal.GetWeekOfYear($jue, [Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday) } }

# ---- semanas previas (JSON existente)
$previas = @{}; $prev = $null
if (-not $Todo -and (Test-Path $outPath)) {
    try {
        $prev = Get-Content $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($s in @($prev.semanas)) { if ($s -and $s.semana_lunes) { $previas[[string]$s.semana_lunes] = $s } }
        Log "JSON previo: $($previas.Count) semanas (hasta $($prev.ultima_semana))"
    } catch { Log "no pude leer el JSON previo ($($_.Exception.Message)): se baja todo" 'DarkYellow'; $previas = @{}; $prev = $null }
}

# ---- que semanas pedir: desde $Desde hasta la ultima semana completa (sabado ya pasado)
$desdeD = LunesDe ([DateTime]::ParseExact($Desde, 'yyyy-MM-dd', $null))
$lunesActual = LunesDe $hoy
$ultimaCompleta = if ($lunesActual.AddDays(5) -lt $hoy) { $lunesActual } else { $lunesActual.AddDays(-7) }
$pendientes = @(); $d = $desdeD
while ($d -le $ultimaCompleta) {
    $k = $d.ToString('yyyy-MM-dd')
    if ($Todo -or -not $previas.ContainsKey($k) -or $d -gt $ultimaCompleta.AddDays(-7 * $Refrescar)) { $pendientes += $d }
    $d = $d.AddDays(7)
}
Log "semanas completas $($desdeD.ToString('yyyy-MM-dd')) a $($ultimaCompleta.ToString('yyyy-MM-dd')): $($pendientes.Count) a pedir, $($previas.Count) previas"
if (-not $pendientes.Count) { Log "nada que pedir"; exit 0 }

# ---- login
$loginJson  = @{ username = [string]$cfg.username; password = [string]$cfg.password } | ConvertTo-Json -Compress
$loginBytes = [System.Text.Encoding]::UTF8.GetBytes($loginJson)
$login = Invoke-RestMethod -Uri "$apiBase/auth/login" -Method Post -Body $loginBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 -UserAgent $UA
if ($login.debe_cambiar_password) { throw "el usuario de Aloha tiene la clave inicial: cambiarla en Aloha" }
if ([string]::IsNullOrWhiteSpace([string]$login.token)) { throw "login sin token (usuario/clave incorrectos?)" }
$hdr = @{ Authorization = "Bearer $($login.token)" }
Log "login OK ($apiBase)" 'Green'

function Get-Aloha { param([string]$ruta, [hashtable]$qs = @{})
    $q = @(); foreach ($k in $qs.Keys) { if ($null -ne $qs[$k] -and "$($qs[$k])" -ne '') { $q += "$k=$([uri]::EscapeDataString([string]$qs[$k]))" } }
    $uri = "$apiBase$ruta" + $(if ($q.Count) { '?' + ($q -join '&') } else { '' })
    $wr = Invoke-WebRequest -Uri $uri -Headers $hdr -TimeoutSec 90 -UserAgent $UA -UseBasicParsing
    $txt = [System.Text.Encoding]::UTF8.GetString($wr.RawContentStream.ToArray())
    return ($txt | ConvertFrom-Json)
}

$mapeo = @{ BR = @{}; PY = @{}; BO = @{}; EC = @{} }; $otrasAg = @{}
if ($prev) {
    foreach ($o in 'BR', 'PY', 'BO', 'EC') { foreach ($a in @($prev.mapeo.$o)) { if ($a) { $mapeo[$o][[string]$a] = 1 } } }
    foreach ($a in @($prev.agrupaciones_otras)) { if ($a) { $otrasAg[[string]$a] = 1 } }
}
$nuevas = @{}; $errores = 0
try {
    foreach ($lunes in $pendientes) {
        $sabado = $lunes.AddDays(5)
        try {
            $v = Get-Aloha '/stock/ventas-presentacion' @{ desde = $lunes.ToString('yyyy-MM-dd'); hasta = $sabado.ToString('yyyy-MM-dd'); incluir_sin_ventas = 'true' }
        } catch { $errores++; Log "  sem $($lunes.ToString('yyyy-MM-dd')): ERROR $($_.Exception.Message)" 'Red'; continue }
        $c = @{ BR = 0.0; PY = 0.0; BO = 0.0; EC = 0.0; otras = 0.0 }; $dsc = @{ BR = 0.0; PY = 0.0; BO = 0.0; EC = 0.0 }
        foreach ($f in @($v.filas)) {
            $ag = [string]$f.agrupacion
            if (-not ($ag -match '(?i)^banana')) { continue }
            $o = Origen-De $ag
            if ($o) {
                $c[$o] += Num $f.present; $mapeo[$o][$ag] = 1
                if ($f.movimientos) { $dsc[$o] += -(Num $f.movimientos.descartes) }   # el ERP los trae negativos; aca cajas descartadas en positivo
            } else { $c.otras += Num $f.present; $otrasAg[$ag] = 1 }
        }
        $iso = IsoSemana $lunes
        $fila = [ordered]@{
            semana_lunes = $lunes.ToString('yyyy-MM-dd'); hasta = $sabado.ToString('yyyy-MM-dd'); anio = $lunes.Year
            iso_anio = [int]$iso.anio; iso_semana = [int]$iso.n
            BR = (R0 $c.BR); PY = (R0 $c.PY); BO = (R0 $c.BO); EC = (R0 $c.EC); otras = (R0 $c.otras)
        }
        $fila.madera_bo = $fila.BR + $fila.PY + $fila.BO
        $fila.total = $fila.BR + $fila.PY + $fila.BO + $fila.EC
        $fila.descartes = [ordered]@{ BR = (R0 $dsc.BR); PY = (R0 $dsc.PY); BO = (R0 $dsc.BO); EC = (R0 $dsc.EC) }
        $fila.descartes.total = $fila.descartes.BR + $fila.descartes.PY + $fila.descartes.BO + $fila.descartes.EC
        $fila.leido = $ahora.ToString('yyyy-MM-dd HH:mm')
        $nuevas[$fila.semana_lunes] = $fila
        Log ("  sem {0} (ISO {1}-{2:00}): BR {3} · PY {4} · BO {5} · EC {6} · total {7}{8} · descartes {9}" -f $fila.semana_lunes, $fila.iso_anio, $fila.iso_semana, $fila.BR, $fila.PY, $fila.BO, $fila.EC, $fila.total, $(if ($fila.otras) { " · otras $($fila.otras)" } else { '' }), $fila.descartes.total)
    }
} finally { try { Invoke-RestMethod -Uri "$apiBase/auth/logout" -Method Post -Headers $hdr -TimeoutSec 15 -UserAgent $UA | Out-Null } catch {} }

# ---- unir previas + nuevas y guardar
$todas = @{}
foreach ($k in $previas.Keys) { $todas[$k] = $previas[$k] }
foreach ($k in $nuevas.Keys) { $todas[$k] = $nuevas[$k] }
$lista = @($todas.Keys | Sort-Object | ForEach-Object { $todas[$_] })
$doc = [ordered]@{
    generado = $ahora.ToString('yyyy-MM-dd HH:mm')
    fuente = 'Aloha API GET /stock/ventas-presentacion (present = cajas vendidas; semana lunes a sabado; solo semanas completas)'
    nota = 'La API tiene ventas desde la semana del 30/06/2025 (antes devuelve 0). madera_bo = BR+PY+BO; total = BR+PY+BO+EC; otras = agrupaciones Banana sin origen (no entran en total); descartes = cajas descartadas en la semana (positivo).'
    desde = $desdeD.ToString('yyyy-MM-dd'); ultima_semana = $ultimaCompleta.ToString('yyyy-MM-dd')
    semanas_total = $lista.Count; semanas_bajadas = $nuevas.Count; errores = $errores
    mapeo = [ordered]@{ BR = @($mapeo.BR.Keys | Sort-Object); PY = @($mapeo.PY.Keys | Sort-Object); BO = @($mapeo.BO.Keys | Sort-Object); EC = @($mapeo.EC.Keys | Sort-Object) }
    agrupaciones_otras = @($otrasAg.Keys | Sort-Object)
    semanas = $lista
}
$json = $doc | ConvertTo-Json -Depth 6 -Compress
Set-Content -Path $outPath -Value $json -Encoding UTF8
Log "OK aloha_ventas_historico.json: $($lista.Count) semanas ($($nuevas.Count) bajadas ahora, $errores errores), $([int]($json.Length / 1KB)) KB" 'Green'
