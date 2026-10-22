# ==========================================================================
#  plan_compras\aloha_datos.ps1  -  lector de SOLO LECTURA de la API de Aloha (11/10/2026)
# ==========================================================================
#  Baja de Aloha (https://aloha.somospepe.com/api) lo que Gonzalo venia mandando en fotos del ERP y
#  lo deja como sidecars JSON en fuentes\, para que el plan de compras (generar_datos.ps1) y el
#  pipeline (actualizar_precios.ps1) lo consuman sin cargar nada a mano:
#
#    fuentes\aloha_ventas.json    venta real por semana (lunes a sabado) y por origen BR/PY/BO/EC
#                                 en cajas (present), kilos y $ -> GET /stock/ventas-presentacion
#    fuentes\aloha_stock.json     stock actual del ERP por producto (= la captura diaria del stock)
#                                 -> GET /stock/dashboard/actual
#    fuentes\aloha_camaras.json   conteo de camaras por sede (ZAC y CR) y por origen, con la hora del
#                                 conteo y las temperaturas -> GET /stock/mapa-camaras?sede=
#    fuentes\aloha_pizarron.json  lotes en camara (pie de camion, productor, ingreso, dias de frio)
#                                 -> GET /pizarron?ubicacion=ZAC|CR
#
#  Uso:  powershell -ExecutionPolicy Bypass -File plan_compras\aloha_datos.ps1 [-Semanas 16]
#  Login con config\aloha.json (gitignored), igual que el paso 3b del pipeline. Solo hace GET
#  (y el POST de login/logout): no modifica nada en Aloha. No escribe credenciales en el log.
#  Si config\aloha.json no esta o enabled=false, sale sin error y sin tocar los sidecars.
# ==========================================================================
param(
    [int]$Semanas = 16,          # semanas de venta hacia atras (lunes a sabado), incluida la actual
    [int]$DiasSemanas = 3,       # en las ultimas N semanas, ademas, la venta POR DIA (lun a sab; una llamada por dia)
    [string]$Salida = ''         # carpeta de salida; vacio = fuentes\ del repo
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$base    = Split-Path $PSScriptRoot -Parent
$fuentes = if ($Salida) { $Salida } else { Join-Path $base 'fuentes' }
$cfgPath = Join-Path $base 'config\aloha.json'
$UA      = 'poronga/1.0'
$ahora   = Get-Date
$hoy     = $ahora.Date

function Log { param([string]$t, [string]$c = 'Gray') Write-Host "[aloha] $t" -ForegroundColor $c }

if (-not (Test-Path $cfgPath)) { Log "sin config\aloha.json: no bajo nada" 'DarkYellow'; exit 0 }
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cfg.enabled) { Log "config\aloha.json con enabled=false: no bajo nada" 'DarkYellow'; exit 0 }
$apiBase = ([string]$cfg.url).TrimEnd('/')
# [22/10/2026] TOKEN DE INTEGRACION "poronga" (Uruguay; el servidor daba 401 con la clave vieja del usuario Admin): si config\aloha.json
#     trae "token", se entra con Authorization: Bearer <token> a las rutas /integraciones/poronga/... (solo lectura, mismas respuestas),
#     sin login ni logout. Sin token, todo como antes (login con username/password; la laptop entra con gpepe). El token nunca se imprime.
$tokAloha = $(if ($cfg.PSObject.Properties.Name -contains 'token') { ([string]$cfg.token).Trim() } else { '' })
$usaToken = -not [string]::IsNullOrWhiteSpace($tokAloha)
$prefijo  = $(if ($usaToken) { '/integraciones/poronga' } else { '' })
if ([string]::IsNullOrWhiteSpace($apiBase) -or (-not $usaToken -and ([string]::IsNullOrWhiteSpace([string]$cfg.username) -or [string]::IsNullOrWhiteSpace([string]$cfg.password)))) {
    throw "config\aloha.json incompleto (url y token, o url, username y password)"
}
if (-not (Test-Path $fuentes)) { New-Item -ItemType Directory -Path $fuentes | Out-Null }

# ---- origen a partir de un texto (agrupacion del ERP, pais de la camara, producto del pizarron)
function Origen-De { param([string]$t)
    if ($null -eq $t) { return $null }
    if ($t -match '(?i)bras|san pablo')   { return 'BR' }   # "Banana San Pablo" = Banana Brasil San Pablo (12/10/2026)
    if ($t -match '(?i)parag')  { return 'PY' }
    if ($t -match '(?i)boliv')  { return 'BO' }
    if ($t -match '(?i)ecuad')  { return 'EC' }
    return $null
}
function Es-Banana { param([string]$a, [string]$b) return (("$a $b") -match '(?i)banana|bonita') }
function Num { param($v) if ($null -eq $v -or "$v" -eq '') { return 0.0 }; return [double]$v }
function R0 { param($v) return [math]::Round((Num $v), 0) }
function Fecha-Corta { param($s) if ($null -eq $s -or "$s" -eq '') { return $null }; try { return ([DateTime]$s).ToString('yyyy-MM-dd HH:mm') } catch { return [string]$s } }

# ---- login (o token de integracion)
if ($usaToken) {
    $hdr = @{ Authorization = "Bearer $tokAloha" }
    Log "token de integracion poronga ($apiBase$prefijo), sin login" 'Green'
} else {
    $loginJson  = @{ username = [string]$cfg.username; password = [string]$cfg.password } | ConvertTo-Json -Compress
    $loginBytes = [System.Text.Encoding]::UTF8.GetBytes($loginJson)
    $login = Invoke-RestMethod -Uri "$apiBase/auth/login" -Method Post -Body $loginBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 -UserAgent $UA
    if ($login.debe_cambiar_password) { throw "el usuario de Aloha tiene la clave inicial: cambiarla en Aloha" }
    if ([string]::IsNullOrWhiteSpace([string]$login.token)) { throw "login sin token (usuario/clave incorrectos?)" }
    $hdr = @{ Authorization = "Bearer $($login.token)" }
    Log "login OK ($apiBase)" 'Green'
}

# GET con decodificacion UTF-8 explicita (Invoke-RestMethod de PS 5.1 a veces lee los acentos como latin-1)
# [22/10/2026] con token: prefijo /integraciones/poronga; 401 = token invalido o revocado (mensaje claro); 429 (mas de 120 lecturas
# por minuto) = se espera 60 s y se reintenta UNA vez; pausa corta entre GETs para no llegar al limite.
function Get-Aloha { param([string]$ruta, [hashtable]$qs = @{})
    $q = @(); foreach ($k in $qs.Keys) { if ($null -ne $qs[$k] -and "$($qs[$k])" -ne '') { $q += "$k=$([uri]::EscapeDataString([string]$qs[$k]))" } }
    $uri = "$apiBase$prefijo$ruta" + $(if ($q.Count) { '?' + ($q -join '&') } else { '' })
    if ($usaToken) { Start-Sleep -Milliseconds 550 }
    for ($intento = 1; $intento -le 2; $intento++) {
        try {
            $wr = Invoke-WebRequest -Uri $uri -Headers $hdr -TimeoutSec 90 -UserAgent $UA -UseBasicParsing
            $txt = [System.Text.Encoding]::UTF8.GetString($wr.RawContentStream.ToArray())
            return ($txt | ConvertFrom-Json)
        } catch {
            $cod = $null; try { $cod = [int]$_.Exception.Response.StatusCode } catch {}
            if ($cod -eq 401 -and $usaToken) { throw "token de Aloha invalido o revocado: crear otro en Aloha -> Configuracion -> Parametros -> Integraciones -> Servidor de reportes (poronga) y cargarlo con cargar_token_aloha.ps1" }
            if ($cod -eq 429 -and $intento -eq 1) { Log "  429 (limite de lecturas por minuto): espero 60 s y reintento una vez" 'DarkYellow'; Start-Sleep -Seconds 60; continue }
            throw
        }
    }
}
function Guardar { param([string]$nombre, $obj)
    $p = Join-Path $fuentes $nombre
    $json = $obj | ConvertTo-Json -Depth 14 -Compress
    Set-Content -Path $p -Value $json -Encoding UTF8
    Log "OK $nombre ($([int]($json.Length / 1KB)) KB)" 'Green'
}

$resumenFinal = @()
try {
    # ======================================================================
    # 1) VENTAS por semana (lunes a sabado) y por origen
    # ======================================================================
    Log "ventas: $Semanas semanas (lunes a sabado) de /stock/ventas-presentacion..."
    $lunesActual = $hoy.AddDays(-(([int]$hoy.DayOfWeek + 6) % 7))
    $listaSemanas = @(); $mapeo = @{ BR = @{}; PY = @{}; BO = @{}; EC = @{} }; $ignoradas = @{}
    for ($i = $Semanas - 1; $i -ge 0; $i--) {
        $lunes = $lunesActual.AddDays(-7 * $i); $sabado = $lunes.AddDays(5)
        $hasta = if ($sabado -gt $hoy) { $hoy } else { $sabado }
        if ($hasta -lt $lunes) { continue }
        $v = Get-Aloha '/stock/ventas-presentacion' @{ desde = $lunes.ToString('yyyy-MM-dd'); hasta = $hasta.ToString('yyyy-MM-dd'); incluir_sin_ventas = 'true' }
        $porO = [ordered]@{}
        foreach ($o in 'BR', 'PY', 'BO', 'EC') { $porO[$o] = [ordered]@{ present = 0.0; kilos = 0.0; venta = 0.0; stock_inicial = 0.0; stock = 0.0; ingresos = 0.0; importacion = 0.0; descartes = 0.0; plaza_viajes = 0.0; agrupaciones = @() } }
        foreach ($f in @($v.filas)) {
            $ag = [string]$f.agrupacion
            if (-not ($ag -match '(?i)^banana')) { $ignoradas[$ag] = 1; continue }
            $o = Origen-De $ag
            if (-not $o) { $ignoradas[$ag] = 1; continue }
            $mapeo[$o][$ag] = 1
            $x = $porO[$o]
            $x.present += Num $f.present; $x.kilos += Num $f.kilos; $x.venta += Num $f.venta
            $x.stock_inicial += Num $f.stock_inicial; $x.stock += Num $f.stock; $x.ingresos += Num $f.ingresos
            if ($f.movimientos) { $x.importacion += Num $f.movimientos.importacion; $x.descartes += Num $f.movimientos.descartes; $x.plaza_viajes += Num $f.movimientos.plaza_viajes }
            $x.agrupaciones += $ag
        }
        $fila = [ordered]@{
            semana_lunes = $lunes.ToString('yyyy-MM-dd'); hasta = $hasta.ToString('yyyy-MM-dd')
            dias_contados = [int](($hasta - $lunes).TotalDays + 1); parcial = ($sabado -gt $hoy)   # 'dias' (array por dia) solo en las ultimas $DiasSemanas semanas
            venta_cajas = [ordered]@{ BR = (R0 $porO.BR.present); PY = (R0 $porO.PY.present); BO = (R0 $porO.BO.present); EC = (R0 $porO.EC.present) }
        }
        $fila.venta_cajas.total = $fila.venta_cajas.BR + $fila.venta_cajas.PY + $fila.venta_cajas.BO + $fila.venta_cajas.EC
        $fila.venta_cajas.madera = $fila.venta_cajas.BR + $fila.venta_cajas.PY
        foreach ($o in 'BR', 'PY', 'BO', 'EC') {
            $x = $porO[$o]
            $fila[$o] = [ordered]@{ present = (R0 $x.present); kilos = (R0 $x.kilos); venta = (R0 $x.venta); stock_inicial = (R0 $x.stock_inicial); stock = (R0 $x.stock)
                                    ingresos = (R0 $x.ingresos); importacion = (R0 $x.importacion); descartes = (R0 $x.descartes); plaza_viajes = (R0 $x.plaza_viajes) }
        }
        $fila.total_todo_present = (R0 $v.totales.present)
        $fila.stock_al = [string]$v.stock_al
        # Venta por dia en las ultimas $DiasSemanas semanas (regla de Gonzalo: lun+mar+mie x2 ~ semana; el plan
        # estima la semana en curso con los dias ya vendidos). Lunes a sabado, dia sin venta = 0; en la semana en
        # curso solo hasta hoy. Mismo endpoint con desde = hasta = el dia.
        if ($i -lt $DiasSemanas) {
            $dias = @()
            for ($d = $lunes; $d -le $hasta -and $d -le $sabado; $d = $d.AddDays(1)) {
                $vd = Get-Aloha '/stock/ventas-presentacion' @{ desde = $d.ToString('yyyy-MM-dd'); hasta = $d.ToString('yyyy-MM-dd'); incluir_sin_ventas = 'true' }
                $dO = @{ BR = 0.0; PY = 0.0; BO = 0.0; EC = 0.0 }
                foreach ($f in @($vd.filas)) {
                    $ag = [string]$f.agrupacion
                    if (-not ($ag -match '(?i)^banana')) { continue }
                    $o = Origen-De $ag; if (-not $o) { continue }
                    $dO[$o] += Num $f.present
                }
                $dias += [ordered]@{ fecha = $d.ToString('yyyy-MM-dd'); dow = ((([int]$d.DayOfWeek + 6) % 7) + 1)
                                     BR = (R0 $dO.BR); PY = (R0 $dO.PY); BO = (R0 $dO.BO); EC = (R0 $dO.EC)
                                     madera_bo = (R0 ($dO.BR + $dO.PY + $dO.BO)); total = (R0 ($dO.BR + $dO.PY + $dO.BO + $dO.EC)) }
            }
            $fila.dias = $dias
        }
        $listaSemanas += $fila
        Log ("  sem {0} a {1}{2}: BR {3} · PY {4} · BO {5} · EC {6} cajas" -f $fila.semana_lunes, $fila.hasta, $(if ($fila.parcial) { ' (parcial)' } else { '' }), $fila.venta_cajas.BR, $fila.venta_cajas.PY, $fila.venta_cajas.BO, $fila.venta_cajas.EC)
    }
    $ventas = [ordered]@{
        generado = $ahora.ToString('yyyy-MM-dd HH:mm'); fuente = 'Aloha API GET /stock/ventas-presentacion (present = cajas vendidas; semana lunes a sabado)'
        semanas_pedidas = $Semanas
        mapeo = [ordered]@{ BR = @($mapeo.BR.Keys | Sort-Object); PY = @($mapeo.PY.Keys | Sort-Object); BO = @($mapeo.BO.Keys | Sort-Object); EC = @($mapeo.EC.Keys | Sort-Object) }
        agrupaciones_ignoradas = @($ignoradas.Keys | Sort-Object)
        semanas = $listaSemanas
    }
    Guardar 'aloha_ventas.json' $ventas
    $resumenFinal += "ventas: $($listaSemanas.Count) semanas"

    # ======================================================================
    # 2) STOCK actual del ERP (dashboard)
    # ======================================================================
    Log "stock: /stock/dashboard/actual..."
    $d = Get-Aloha '/stock/dashboard/actual'
    $lineas = @(); $stockO = [ordered]@{ BR = 0.0; PY = 0.0; BO = 0.0; EC = 0.0 }; $detalle = [ordered]@{}
    foreach ($l in @($d.lineas)) {
        $o = $null
        if (([string]$l.producto) -match '(?i)^banana') { $o = Origen-De ([string]$l.producto) }
        $lineas += [ordered]@{ clave = [string]$l.clave; producto = [string]$l.producto; codigo = [string]$l.codigo_representativo; stock_actual = (R0 $l.stock_actual); origen = $o }
        if ($o) { $stockO[$o] += Num $l.stock_actual; $detalle[[string]$l.clave] = (R0 $l.stock_actual) }
    }
    $stock = [ordered]@{
        generado = $ahora.ToString('yyyy-MM-dd HH:mm'); fuente = 'Aloha API GET /stock/dashboard/actual (= captura diaria del stock del ERP, cajas listas para vender)'
        generado_en_api = (Fecha-Corta $d.generado_en); macrosoft_actualizado_en = (Fecha-Corta $d.macrosoft_actualizado_en); stock_actual_fuente = [string]$d.stock_actual_fuente
        porOrigen = [ordered]@{ BR = (R0 $stockO.BR); PY = (R0 $stockO.PY); BO = (R0 $stockO.BO); EC = (R0 $stockO.EC) }
        detalle_banana = $detalle
        lineas = $lineas
    }
    $stock.porOrigen.total = $stock.porOrigen.BR + $stock.porOrigen.PY + $stock.porOrigen.BO + $stock.porOrigen.EC
    Guardar 'aloha_stock.json' $stock
    $resumenFinal += "stock: BR $($stock.porOrigen.BR) · PY $($stock.porOrigen.PY) · BO $($stock.porOrigen.BO) · EC $($stock.porOrigen.EC)"

    # ======================================================================
    # 3) CAMARAS por sede y por origen (conteo fisico)
    # ======================================================================
    Log "camaras: /stock/mapa-camaras (ZAC y CR)..."
    $sedes = [ordered]@{}; $camO = [ordered]@{ BR = 0.0; PY = 0.0; BO = 0.0; EC = 0.0 }
    foreach ($sede in 'ZAC', 'CR') {
        try {
            $m = @(Get-Aloha '/stock/mapa-camaras' @{ sede = $sede })
            $cams = @(); $sO = [ordered]@{ BR = 0.0; PY = 0.0; BO = 0.0; EC = 0.0 }; $otros = 0.0; $fechas = @()
            foreach ($c in $m) {
                $prods = @()
                foreach ($p in @($c.productos)) {
                    $esB = Es-Banana ([string]$p.nombre) ([string]$p.descripcion)
                    $o = if ($esB) { Origen-De ([string]$p.pais) } else { $null }
                    if (-not $o -and $esB) { $o = Origen-De ([string]$p.descripcion) }
                    if ($o) { $sO[$o] += Num $p.cantidad } else { $otros += Num $p.cantidad }
                    $prods += [ordered]@{ nombre = [string]$p.nombre; descripcion = [string]$p.descripcion; cantidad = (R0 $p.cantidad); pais = [string]$p.pais; origen = $o; banana = $esB }
                }
                if ($c.contado_en) { $fechas += [string]$c.contado_en }
                $cams += [ordered]@{ numero = $c.numero; etiqueta = [string]$c.etiqueta; tipo = [string]$c.tipo; es_vacia = [bool]$c.es_vacia; total = (R0 $c.total)
                                     contado_en = (Fecha-Corta $c.contado_en); contado_por = [string]$c.contado_por
                                     temp_setpoint = $c.temp_setpoint; temp_aire = $c.temp_aire; temp_critica = $c.temp_critica; productos = $prods }
            }
            $fechasOrd = @($fechas | Sort-Object)
            $sedes[$sede] = [ordered]@{
                camaras = $cams.Count; contado_desde = (Fecha-Corta $(if ($fechasOrd.Count) { $fechasOrd[0] } else { $null })); contado_hasta = (Fecha-Corta $(if ($fechasOrd.Count) { $fechasOrd[-1] } else { $null }))
                porOrigen = [ordered]@{ BR = (R0 $sO.BR); PY = (R0 $sO.PY); BO = (R0 $sO.BO); EC = (R0 $sO.EC) }
                otros_cajas = (R0 $otros); total_cajas = (R0 (($m | ForEach-Object { Num $_.total } | Measure-Object -Sum).Sum))
                detalle = $cams
            }
            foreach ($o in 'BR', 'PY', 'BO', 'EC') { $camO[$o] += $sO[$o] }
            Log ("  {0}: {1} camaras, banana BR {2} · PY {3} · BO {4} · EC {5} (contado hasta {6})" -f $sede, $cams.Count, (R0 $sO.BR), (R0 $sO.PY), (R0 $sO.BO), (R0 $sO.EC), $sedes[$sede].contado_hasta)
        } catch {
            $sedes[$sede] = [ordered]@{ error = ($_.Exception.Message -replace '\s+', ' ') }
            Log "  $sede : no disponible ($($_.Exception.Message))" 'DarkYellow'
        }
    }
    # Ultimo cierre (12/10/2026): stock del ERP al cierre del sabado de la ultima semana completa, segun /stock/ventas-presentacion
    # (campo stock, stock_al = sabado 23:59). Coincide con el conteo fisico del sabado (10/10: 27.462 vs 27.488) y, a diferencia del
    # mapa de camaras, no cambia cuando el lunes ya se vendio parte: el plan lo usa como conteo de referencia fijo.
    $ultimoCierre = $null
    $cierreFila = $(if ($listaSemanas) { @($listaSemanas | Where-Object { -not $_.parcial }) | Select-Object -Last 1 } else { $null })
    if ($cierreFila) {
        $ultimoCierre = [ordered]@{
            semana_lunes = $cierreFila.semana_lunes; sabado = $cierreFila.hasta; stock_al = $cierreFila.stock_al
            porOrigen = [ordered]@{ BR = [int]$cierreFila.BR.stock; PY = [int]$cierreFila.PY.stock; BO = [int]$cierreFila.BO.stock; EC = [int]$cierreFila.EC.stock }
            madera = ([int]$cierreFila.BR.stock + [int]$cierreFila.PY.stock); madera_bo = ([int]$cierreFila.BR.stock + [int]$cierreFila.PY.stock + [int]$cierreFila.BO.stock)
            total_banana = ([int]$cierreFila.BR.stock + [int]$cierreFila.PY.stock + [int]$cierreFila.BO.stock + [int]$cierreFila.EC.stock)
            fuente = 'stock ERP al cierre del sabado (ventas-presentacion de la ultima semana completa)'
        }
        Log ("  ultimo cierre sab {0}: BR {1} · PY {2} · BO {3} · EC {4} (madera+BO {5})" -f $ultimoCierre.sabado, $ultimoCierre.porOrigen.BR, $ultimoCierre.porOrigen.PY, $ultimoCierre.porOrigen.BO, $ultimoCierre.porOrigen.EC, $ultimoCierre.madera_bo)
    }
    $camaras = [ordered]@{
        generado = $ahora.ToString('yyyy-MM-dd HH:mm'); fuente = 'Aloha API GET /stock/mapa-camaras?sede=ZAC|CR (conteo fisico por camara; banana por pais del producto)'
        porOrigen = [ordered]@{ BR = (R0 $camO.BR); PY = (R0 $camO.PY); BO = (R0 $camO.BO); EC = (R0 $camO.EC) }
        madera = (R0 ($camO.BR + $camO.PY)); carton = (R0 ($camO.BO + $camO.EC)); total_banana = (R0 ($camO.BR + $camO.PY + $camO.BO + $camO.EC))
        ultimo_cierre = $ultimoCierre
        sedes = $sedes
    }
    Guardar 'aloha_camaras.json' $camaras
    $resumenFinal += "camaras: BR $($camaras.porOrigen.BR) · PY $($camaras.porOrigen.PY) · BO $($camaras.porOrigen.BO) · EC $($camaras.porOrigen.EC)"

    # ======================================================================
    # 4) PIZARRON: lotes en camara (pie de camion, productor, ingreso, dias de frio)
    # ======================================================================
    Log "pizarron: /pizarron (ZAC y CR)..."
    $ubic = [ordered]@{}; $lotes = @()
    foreach ($u in 'ZAC', 'CR') {
        try {
            $pz = Get-Aloha '/pizarron' @{ ubicacion = $u }
            $n = 0
            foreach ($c in @($pz.camaras)) {
                foreach ($l in @($c.lotes)) {
                    $n++
                    $lotes += [ordered]@{ sede = $u; camara = $c.numero; codigo = [string]$l.codigo; pie_camion_id = $l.pie_camion_id; productor = [string]$l.productor
                                          producto = [string]$l.producto; origen = (Origen-De ([string]$l.producto)); fecha_ingreso = [string]$l.fecha_ingreso
                                          dias_frio = $l.dias_frio; cantidad = (R0 $l.cantidad); dominante = [bool]$l.dominante; fuente = [string]$l.fuente; color_ingreso = $l.color_ingreso }
                }
            }
            $ubic[$u] = [ordered]@{ camaras = @($pz.camaras).Count; lotes = $n }
            Log "  $u : $(@($pz.camaras).Count) camaras, $n lotes"
        } catch {
            $ubic[$u] = [ordered]@{ error = ($_.Exception.Message -replace '\s+', ' ') }
            Log "  $u : no disponible ($($_.Exception.Message))" 'DarkYellow'
        }
    }
    $pO = [ordered]@{}; foreach ($o in 'BR', 'PY', 'BO', 'EC') { $g = @($lotes | Where-Object { $_.origen -eq $o }); $pO[$o] = [ordered]@{ cajas = (R0 (($g | ForEach-Object { $_.cantidad } | Measure-Object -Sum).Sum)); lotes = $g.Count } }
    $porProd = @()
    foreach ($g in ($lotes | Group-Object { ((([string]$_.productor).Trim()) -replace '\s+', ' ').ToLower() } | Sort-Object Name)) {   # script block: con hashtables, -Property no agrupa; clave normalizada (espacios/mayusculas)
        $ing = @($g.Group | ForEach-Object { $_.fecha_ingreso } | Where-Object { $_ } | Sort-Object)
        $porProd += [ordered]@{ productor = ((([string](($g.Group | Select-Object -First 1).productor)).Trim()) -replace '\s+', ' '); origen = ($g.Group | Select-Object -First 1).origen; cajas = (R0 (($g.Group | ForEach-Object { $_.cantidad } | Measure-Object -Sum).Sum)); lotes = $g.Count
                                dias_frio_max = (($g.Group | ForEach-Object { Num $_.dias_frio } | Measure-Object -Maximum).Maximum)
                                ingreso_min = $(if ($ing.Count) { $ing[0] } else { $null }); ingreso_max = $(if ($ing.Count) { $ing[-1] } else { $null }) }
    }
    # FIFO (12/10/2026, Gonzalo: "dale hacemos todo eso"): lotes con mas de $fifoUmbral dias de frio. Los de mas de $fifoSinCerrar dias
    # son casi seguro lotes que no se cerraron en el pizarron al venderse (p.ej. JP011 con 340 dias) y van aparte, como sospechosos.
    # Los lotes cargados por foto vienen sin producto: el origen se infiere del codigo (PY..., ECUADOR/BONITA, BO...).
    $fifoUmbral = 14; $fifoSinCerrar = 45
    # El pizarron tambien tiene exoticos, uva, "Varios": no son banana y quedan fuera del FIFO (se cuentan en otros_productos).
    $noBananaLote = '(?i)exot|expt|uva|mission|eden|varios|^FI\d'
    function Origen-Lote { param($l) if ($l.origen) { return $l.origen }; $cod = ([string]$l.codigo).Trim()
        if ($cod -match '^(?i)PY') { return 'PY' }; if ($cod -match '(?i)ecuador|bonita') { return 'EC' }; if ($cod -match '^(?i)BO') { return 'BO' }
        if ($cod -match '^[A-Za-z]{2}\d{2,}$') { return 'BR' }   # lotes por foto sin producto: codigo de productor brasileno (FH073, CP052, JP011...)
        return $null }
    $viejos = @($lotes | Where-Object { (Num $_.dias_frio) -gt $fifoUmbral } | Sort-Object { -(Num $_.dias_frio) })
    $fifoLotes = @(); $fifoSosp = @(); $fifoOtros = 0
    foreach ($l in $viejos) {
        if (("$($l.codigo) $($l.productor) $($l.producto)") -match $noBananaLote) { $fifoOtros++; continue }
        $x = [ordered]@{ sede = $l.sede; camara = $l.camara; codigo = $l.codigo; productor = $l.productor; origen = (Origen-Lote $l); origen_inferido = (-not $l.origen)
                         dias_frio = [int](Num $l.dias_frio); cantidad = $l.cantidad; fecha_ingreso = $l.fecha_ingreso; fuente = $l.fuente }
        if ($x.dias_frio -gt $fifoSinCerrar) { $fifoSosp += $x } else { $fifoLotes += $x }
    }
    $fifoPO = [ordered]@{}
    foreach ($o in 'BR', 'PY', 'BO', 'EC', 'sin origen') {
        $g = @($fifoLotes | Where-Object { if ($o -eq 'sin origen') { -not $_.origen } else { $_.origen -eq $o } })
        $fifoPO[$o] = [ordered]@{ lotes = $g.Count; cajas = (R0 (($g | ForEach-Object { $_.cantidad } | Measure-Object -Sum).Sum)) }
    }
    $fifo = [ordered]@{
        umbral_dias = $fifoUmbral; sin_cerrar_dias = $fifoSinCerrar
        nota = 'cantidad = cajas que ENTRARON con el lote, no las que quedan; dias_frio desde fecha_ingreso. Mas de sin_cerrar_dias dias: probablemente lote sin cerrar en el pizarron, no fruta.'
        lotes = $fifoLotes; porOrigen = $fifoPO; sospechosos_sin_cerrar = $fifoSosp; sin_origen = @($lotes | Where-Object { -not (Origen-Lote $_) }).Count
        otros_productos = $fifoOtros   # lotes viejos que no son banana (exoticos, uva, Varios), excluidos de lotes[]
    }
    Log ("  FIFO: {0} lotes con mas de {1} dias ({2}); {3} sospechosos sin cerrar (>{4} dias); {5} lotes sin origen" -f $fifoLotes.Count, $fifoUmbral, (($fifoPO.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value.lotes)" }) -join ', '), $fifoSosp.Count, $fifoSinCerrar, $fifo.sin_origen)
    $pizarron = [ordered]@{
        generado = $ahora.ToString('yyyy-MM-dd HH:mm'); fuente = 'Aloha API GET /pizarron?ubicacion=ZAC|CR (lotes en camara por pie de camion)'
        ubicaciones = $ubic; porOrigen = $pO; porProductor = ($porProd | Sort-Object { -$_.cajas }); fifo = $fifo; lotes = $lotes
    }
    Guardar 'aloha_pizarron.json' $pizarron
    $resumenFinal += "pizarron: $($lotes.Count) lotes"

    # ======================================================================
    # 5) PLAN DE CARGAS (estado real de cada camion). [22/10/2026] Gonzalo: "que tenemos que corregir para que no vuelva a pasar":
    #    los mensajes cruzan cada camion dictado con Aloha (descargado / en camino / no figura) y la cuenta del sabado no cuenta dos
    #    veces lo ya descargado. Antes esto solo venia del export .xlsx del paso 3b, que en la laptop tenia 10 dias de atraso.
    # ======================================================================
    try {
        $pcR = Get-Aloha '/plan-cargas' @{ limit = 5000 }
        $pcRows = @(); foreach ($k in 'data', 'items', 'rows', 'cargas') { if ($pcR.PSObject.Properties.Name -contains $k) { $pcRows = @($pcR.$k); break } }; if (-not $pcRows.Count) { $pcRows = @($pcR) }
        $desdePc = $ahora.Date.AddDays(-45).ToString('yyyy-MM-dd')
        $pcOut = @($pcRows | Where-Object { [string]$_.fecha_carga -ge $desdePc } | ForEach-Object {
            [ordered]@{ productor = ((([string]$_.productor).Trim()) -replace '\s+', ' '); pais = [string]$_.pais_origen; status = [string]$_.status
                        carga = $(if ($_.fecha_carga) { ([string]$_.fecha_carga).Substring(0, 10) }); frontera = $(if ($_.fecha_frontera) { ([string]$_.fecha_frontera).Substring(0, 10) })
                        descarga = $(if ($_.fecha_descarga) { ([string]$_.fecha_descarga).Substring(0, 10) }); cajas_mic = [int](Num $_.cajas_mic); cajas_desc = [int](Num $_.cajas_desc); fuente = [string]$_.fuente } })
        Guardar 'aloha_plan_cargas.json' ([ordered]@{ generado = $ahora.ToString('yyyy-MM-dd HH:mm'); fuente = 'Aloha API GET /plan-cargas (cargas de los ultimos 45 dias y futuras)'; cargas = $pcOut })
        $resumenFinal += "plan-cargas: $($pcOut.Count) filas"
    } catch { Log "  plan-cargas no disponible: $($_.Exception.Message)" 'DarkYellow' }
} finally {
    if (-not $usaToken) { try { Invoke-RestMethod -Uri "$apiBase/auth/logout" -Method Post -Headers $hdr -TimeoutSec 15 -UserAgent $UA | Out-Null; Log "logout" } catch {} }
}
Log ("listo: " + ($resumenFinal -join ' | ')) 'Cyan'
