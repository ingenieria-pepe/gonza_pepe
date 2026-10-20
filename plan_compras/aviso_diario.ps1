# ==========================================================================
#  plan_compras\aviso_diario.ps1  -  "Venta al mediodia": WhatsApp diario a Gonzalo
# ==========================================================================
#  [19/10/2026] Gonzalo: "activa un mensaje de WhatsApp a mi numero terminado en 8111 todos los dias ... me tendria que llegar al
#  medio dia, asi me ordena cuando estoy en los bananales y no tengo que esperar a llegar de noche".
#  Lunes a sabado 12:00 (tarea programada de la laptop "Poronga_Aviso_Diario"). Lee Aloha (aloha_datos.ps1, solo GET), regenera el
#  plan (generar_datos.ps1) y manda: venta de ayer contra el mismo dia de la semana pasada, venta de la semana hasta ayer, semana
#  estimada con los dias reales (reparto por dia de 16 semanas), camara de hoy por origen, descargas de hoy segun el plan y cierre
#  estimado del sabado contra el objetivo. Solo cajas, sin precios.
#
#    powershell -ExecutionPolicy Bypass -File plan_compras\aviso_diario.ps1            (manda)
#    powershell -ExecutionPolicy Bypass -File plan_compras\aviso_diario.ps1 -Dry       (solo imprime)
#
#  Destinatario: config\whatsapp.json > phones_diario (lista) o, si no esta, el telefono de phones que termina en -Sufijo (8111).
# ==========================================================================
param([switch]$Dry, [string]$Sufijo = '8111', [switch]$SinActualizar, [string]$Fecha = '')
$ErrorActionPreference = 'Stop'
$aqui = $PSScriptRoot; $repo = Split-Path $aqui -Parent
$log = Join-Path $repo 'fuentes\aviso_diario.log'
function Log($s) { $l = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $s"; Write-Host $l; try { Add-Content -Path $log -Value $l -Encoding UTF8 } catch {} }
try {
    if (-not $SinActualizar) {
        & (Join-Path $aqui 'aloha_datos.ps1') *> $null
        & (Join-Path $aqui 'generar_datos.ps1') *> $null
    }
    $hoy = $(if ($Fecha) { ([DateTime]$Fecha).Date } else { (Get-Date).Date })
    $DOW = @('dom', 'lun', 'mar', 'mié', 'jue', 'vie', 'sáb')
    $SH = @{ 1 = 0.239; 2 = 0.112; 3 = 0.155; 4 = 0.189; 5 = 0.215; 6 = 0.089 }
    $fI = { param($n) ([int][math]::Round([double]$n)).ToString('N0', [Globalization.CultureInfo]'es-UY') }
    $av = Get-Content (Join-Path $repo 'fuentes\aloha_ventas.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $lun = $hoy.AddDays(-((([int]$hoy.DayOfWeek) + 6) % 7)); $lunAnt = $lun.AddDays(-7)
    $semA = @($av.semanas | Where-Object { [string]$_.semana_lunes -eq $lun.ToString('yyyy-MM-dd') }) | Select-Object -First 1
    $semP = @($av.semanas | Where-Object { [string]$_.semana_lunes -eq $lunAnt.ToString('yyyy-MM-dd') }) | Select-Object -First 1
    $diasA = @(); if ($semA -and $semA.PSObject.Properties.Name -contains 'dias') { $diasA = @($semA.dias) }
    $diasP = @(); if ($semP -and $semP.PSObject.Properties.Name -contains 'dias') { $diasP = @($semP.dias) }
    $L = @("*🍌 Venta al mediodía · $($DOW[[int]$hoy.DayOfWeek]) $($hoy.ToString('dd/MM'))*", '')
    # ayer (si ayer fue domingo, el sabado)
    $ayer = $hoy.AddDays(-1); if ($ayer.DayOfWeek -eq [DayOfWeek]::Sunday) { $ayer = $ayer.AddDays(-1) }
    $todos = @($av.semanas | Where-Object { $_.PSObject.Properties.Name -contains 'dias' } | ForEach-Object { @($_.dias) })
    $dAy = @($todos | Where-Object { [string]$_.fecha -eq $ayer.ToString('yyyy-MM-dd') }) | Select-Object -First 1
    $dAyP = @($todos | Where-Object { [string]$_.fecha -eq $ayer.AddDays(-7).ToString('yyyy-MM-dd') }) | Select-Object -First 1
    if ($dAy) { $L += "*$($DOW[[int]$ayer.DayOfWeek]) $($ayer.ToString('dd')):* $(& $fI $dAy.madera_bo) cajas" + $(if ($dAyP) { " ($($DOW[[int]$ayer.DayOfWeek]) pasado $(& $fI $dAyP.madera_bo))" } else { '' }) }
    # semana hasta ayer y estimada
    $hechos = @($diasA | Where-Object { ([DateTime]$_.fecha).Date -lt $hoy })
    if ($hechos.Count) {
        $suma = ($hechos | Measure-Object madera_bo -Sum).Sum; $sumS = 0.0; foreach ($d in $hechos) { $sumS += $SH[[int]$d.dow] }
        $nd = $hechos.Count; $sumP = 0; foreach ($d in $diasP | Select-Object -First $nd) { $sumP += [int]$d.madera_bo }
        $L += "*Semana hasta ayer:* $(& $fI $suma)" + $(if ($sumP) { " (pasada $(& $fI $sumP))" } else { '' })
        if ($sumS -gt 0) { $L += "*Semana estimada:* $(& $fI ([math]::Round(($suma / $sumS) / 100) * 100))" }
    } elseif ($semP) { $L += "*Semana pasada:* $(& $fI ([int]$semP.venta_cajas.BR + [int]$semP.venta_cajas.PY + [int]$semP.venta_cajas.BO)) cajas" }
    $hoyD = @($diasA | Where-Object { [string]$_.fecha -eq $hoy.ToString('yyyy-MM-dd') }) | Select-Object -First 1
    if ($hoyD -and [int]$hoyD.madera_bo -gt 0) { $L += "Hoy hasta ahora: $(& $fI $hoyD.madera_bo)" }
    $L += ''
    # camara
    $ac = Get-Content (Join-Path $repo 'fuentes\aloha_camaras.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $fc = @(); foreach ($s in $ac.sedes.PSObject.Properties) { if ($s.Value.contado_hasta) { $fc += [DateTime]$s.Value.contado_hasta } }; $fcU = ($fc | Sort-Object | Select-Object -Last 1)
    $tot = [int]$ac.porOrigen.BR + [int]$ac.porOrigen.PY + [int]$ac.porOrigen.BO
    $L += "*Cámara* $(if ($fcU) { $DOW[[int]$fcU.DayOfWeek] + ' ' + $fcU.ToString('dd HH:mm') }): *$(& $fI $tot)*"
    $L += "🇧🇷 $(& $fI $ac.porOrigen.BR) · 🇵🇾 $(& $fI $ac.porOrigen.PY) · 🇧🇴 $(& $fI $ac.porOrigen.BO)"
    # plan: descargas de hoy y cierre del sabado (misma cuenta que el mensaje de cargas)
    $tt = [IO.File]::ReadAllText((Join-Path $repo 'actualizar_precios.ps1'), [Text.Encoding]::UTF8)
    $i0 = $tt.IndexOf('function Get-DescargasSemanaTexto {'); $i1 = $tt.IndexOf('Write-Host "[WA] Evaluando alertas WhatsApp..."'); Invoke-Expression $tt.Substring($i0, $i1 - $i0)
    $msgSem = Get-DescargasSemanaTexto -Path (Join-Path $aqui 'plan_compras.json') -Lunes $lun -Hoy $hoy
    $lineas = @($msgSem -split "`n")
    $iHoy = [array]::IndexOf($lineas, "*$((@{1='Lun';2='Mar';3='Mié';4='Jue';5='Vie';6='Sáb';0='Dom'})[[int]$hoy.DayOfWeek]) $($hoy.ToString('dd'))*")
    if ($iHoy -ge 0) { $hoyDesc = @(); for ($k = $iHoy + 1; $k -lt $lineas.Count -and $lineas[$k].Trim(); $k++) { $hoyDesc += ($lineas[$k] -replace '^\S+\s', '') }; $L += ''; $L += "*Descargan hoy ($($hoyDesc.Count)):* " + ($hoyDesc -join ', ') }
    $cierre = @($lineas | Where-Object { $_ -match '^\*Cierre s' }) | Select-Object -First 1
    $falta = @($lineas | Where-Object { $_ -match '^Falta|^Bajo el objetivo' }) | Select-Object -First 1
    $J = Get-Content (Join-Path $aqui 'plan_compras.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cierre) { $L += ''; $L += ($cierre -replace ' cajas', ''); if ($falta) { $L += $falta }; $L += "Objetivo: $(& $fI $J.minimos.TODO)" }
    $txt = ($L -join "`n")
    Write-Host $txt
    if ($Dry) { Log 'aviso diario (dry): no se manda'; return }
    $wa = Get-Content (Join-Path $repo 'config\whatsapp.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $phones = @(); if ($wa.PSObject.Properties.Name -contains 'phones_diario' -and $wa.phones_diario) { $phones = @($wa.phones_diario) } else { $phones = @($wa.phones | Where-Object { (([string]$_) -replace '[^\d]', '').EndsWith($Sufijo) }) }
    if (-not $phones.Count) { throw "sin destinatario (phones_diario ni telefono terminado en $Sufijo)" }
    $hdr = @{ 'Authorization' = "Bearer $($wa.token)" }
    foreach ($p in $phones) {
        $ph = ([string]$p) -replace '[^\d]', ''
        $b = [Text.Encoding]::UTF8.GetBytes((@{ to = $ph; body = $txt } | ConvertTo-Json -Compress))
        $ok = $false
        for ($i = 1; $i -le 3 -and -not $ok; $i++) { try { Invoke-RestMethod -Uri 'https://gate.whapi.cloud/messages/text' -Method Post -Headers $hdr -Body $b -ContentType 'application/json; charset=utf-8' -TimeoutSec 90 | Out-Null; $ok = $true } catch { if ($i -lt 3) { Start-Sleep -Seconds 5 } } }
        Log ("aviso diario a ...{0}: {1}" -f $ph.Substring($ph.Length - 4), $(if ($ok) { 'OK' } else { 'FALLO' }))
    }
} catch { Log "aviso diario FALLO: $($_.Exception.Message)"; throw }
