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
    # [19/10/2026] Gonzalo: "lunes por un lado, martes por otro... hasta terminar la semana": un renglon por dia ya vendido de la
    # semana, cada uno contra el mismo dia de la semana pasada, y el acumulado. El lunes muestra la semana anterior entera (cierre).
    $todos = @($av.semanas | Where-Object { $_.PSObject.Properties.Name -contains 'dias' } | ForEach-Object { @($_.dias) })
    $hechos = @($diasA | Where-Object { ([DateTime]$_.fecha).Date -le $hoy -and [int]$_.madera_bo -gt 0 } | Sort-Object fecha)   # [19/10/2026] la UAM vende de 3 a 11: a las 12 el dia de hoy ya esta completo
    $esCierre = $false
    if (-not $hechos.Count -and $diasP.Count) { $hechos = @($diasP | Sort-Object fecha); $esCierre = $true }
    if ($hechos.Count) {
        $L += $(if ($esCierre) { "*Semana del $(([DateTime]$hechos[0].fecha).ToString('dd/MM')) (cerrada)*" } else { '*Venta por día*' })
        $suma = 0; $sumP = 0; $sumS = 0.0
        foreach ($d in $hechos) {
            $fd = ([DateTime]$d.fecha).Date; $p = @($todos | Where-Object { [string]$_.fecha -eq $fd.AddDays(-7).ToString('yyyy-MM-dd') }) | Select-Object -First 1
            $L += "$($DOW[[int]$fd.DayOfWeek]) $($fd.ToString('dd')): $(& $fI $d.madera_bo)" + $(if ($p) { "  (pasado $(& $fI $p.madera_bo))" } else { '' })
            $suma += [int]$d.madera_bo; if ($p) { $sumP += [int]$p.madera_bo }; $sumS += $SH[[int]$d.dow]
        }
        if ($hechos.Count -gt 1) { $L += "*Total: $(& $fI $suma)*" + $(if ($sumP) { "  (pasada $(& $fI $sumP))" } else { '' }) }   # con un solo dia el total repetia el numero
        if (-not $esCierre -and $sumS -gt 0 -and $sumS -lt 0.99) { $L += "*Semana estimada:* $(& $fI ([math]::Round(($suma / $sumS) / 100) * 100))" }
    }
    $hoyD = @($diasA | Where-Object { [string]$_.fecha -eq $hoy.ToString('yyyy-MM-dd') }) | Select-Object -First 1
    # (hoy ya va en la lista: la UAM cierra a las 11)
    $L += ''
    # camara
    $ac = Get-Content (Join-Path $repo 'fuentes\aloha_camaras.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $fc = @(); foreach ($s in $ac.sedes.PSObject.Properties) { if ($s.Value.contado_hasta) { $fc += [DateTime]$s.Value.contado_hasta } }; $fcU = ($fc | Sort-Object | Select-Object -Last 1)
    $tot = [int]$ac.porOrigen.BR + [int]$ac.porOrigen.PY + [int]$ac.porOrigen.BO
    $L += "*Cámara* $(if ($fcU) { $DOW[[int]$fcU.DayOfWeek] + ' ' + $fcU.ToString('dd HH:mm') }): *$(& $fI $tot)*"
    $L += "🇧🇷 $(& $fI $ac.porOrigen.BR)"; $L += "🇵🇾 $(& $fI $ac.porOrigen.PY)"; $L += "🇧🇴 $(& $fI $ac.porOrigen.BO)"   # [20/10/2026] un origen por renglon (Gonzalo)
    # [20/10/2026] Gonzalo: "ya tenes mensajes los miercoles y los viernes, no se puede duplicar la info": el diario queda solo con la
    # venta por dia y la camara. Descargas y cierre del sabado van en el aviso del miercoles y el mensaje de cargas del viernes.
    # [20/10/2026] Gonzalo: "las descargas de manana? ... inclui-las": solo el proximo dia con descargas (manana, o el primero que tenga),
    # sin el cierre del sabado (ese va en los mensajes del miercoles y el viernes).
    $tt = [IO.File]::ReadAllText((Join-Path $repo 'actualizar_precios.ps1'), [Text.Encoding]::UTF8)
    $i0 = $tt.IndexOf('function Get-DescargasSemanaTexto {'); $i1 = $tt.IndexOf('Write-Host "[WA] Evaluando alertas WhatsApp..."'); Invoke-Expression $tt.Substring($i0, $i1 - $i0)
    $NOMD = @{1='Lun';2='Mar';3='Mié';4='Jue';5='Vie';6='Sáb';0='Dom'}; $semMsgs = @{}
    for ($dd = 1; $dd -le 10; $dd++) {
        $dx = $hoy.AddDays($dd); if ($dx.DayOfWeek -eq [DayOfWeek]::Sunday) { continue }
        $lw = $dx.AddDays(-((([int]$dx.DayOfWeek) + 6) % 7)); $k = $lw.ToString('yyyy-MM-dd')
        if (-not $semMsgs.ContainsKey($k)) { $semMsgs[$k] = @((Get-DescargasSemanaTexto -Path (Join-Path $aqui 'plan_compras.json') -Lunes $lw -Hoy $hoy) -split "`n") }
        $ls = $semMsgs[$k]; $i = [array]::IndexOf($ls, "*$($NOMD[[int]$dx.DayOfWeek]) $($dx.ToString('dd'))*"); $px = @()
        if ($i -ge 0) { for ($q = $i + 1; $q -lt $ls.Count -and $ls[$q].Trim(); $q++) { $px += ($ls[$q] -replace '^\S+\s', '') } }
        if ($px.Count) { $L += ''; $L += "*Descargan $(if ($dd -eq 1) { 'mañana' } else { '' }) $($DOW[[int]$dx.DayOfWeek]) $($dx.ToString('dd')) ($($px.Count)):*".Replace('  ', ' ').Replace('* ', '*'); $L += $px; break }   # [22/10/2026] Gonzalo: un productor por renglon (antes iban seguidos con comas)
    }
    $txt = ($L -join "`n")
    # [22/10/2026] Gonzalo: "dale" (no mandar con datos viejos): si Aloha no se leyo en las ultimas 24 horas, en vez del aviso va una linea
    $vencX = Get-PlanVencido -Path (Join-Path $aqui 'plan_compras.json')
    if ($vencX -and -not $Fecha) { Log "aviso diario NO SALE: $vencX"; $txt = "⚠️ No salió el aviso del mediodía: $vencX. Revisemos Aloha." }
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
