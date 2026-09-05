# ==========================================================================
#  setup_servidor.ps1  —  Instalador del pipeline banana Almar en un servidor
# ==========================================================================
#  Que hace:
#    1. Verifica requisitos (PowerShell, modulo ImportExcel, internet).
#    2. Registra la tarea programada "Cepea_ActualizarPrecios_Almar"
#       (miercoles 12:00 + viernes 19:00), con los mismos settings que la laptop.
#    3. Deja todo listo para que corra solo.
#
#  Como se usa (EN EL SERVIDOR, una sola vez):
#    - Click derecho sobre este archivo -> "Ejecutar con PowerShell como admin"
#      o desde una consola PowerShell ELEVADA (como administrador):
#         Set-ExecutionPolicy -Scope Process Bypass -Force
#         & "<esta-carpeta>\setup_servidor.ps1"
#
#  Es idempotente: se puede correr varias veces sin romper nada.
# ==========================================================================

$ErrorActionPreference = 'Stop'
$TASK_NAME  = 'Cepea_ActualizarPrecios_Almar'
$base       = $PSScriptRoot
$scriptMain = Join-Path $base 'actualizar_precios.ps1'

function Line { param($c='DarkGray') Write-Host ('-' * 68) -ForegroundColor $c }
function Titulo { param($t) Write-Host "`n$t" -ForegroundColor Cyan; Line }

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Instalador servidor - Pipeline banana Almar" -ForegroundColor Cyan
Write-Host "  Carpeta: $base" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# --- 0) Sanity: existe el script principal al lado -------------------------
if (-not (Test-Path $scriptMain)) {
    Write-Host "ERROR: no encuentro actualizar_precios.ps1 en esta carpeta." -ForegroundColor Red
    Write-Host "       Corre este setup DENTRO de la carpeta del proyecto." -ForegroundColor Red
    exit 1
}

# --- 1) Requisitos --------------------------------------------------------
Titulo "[1/4] Verificando requisitos"
$okTodo = $true

# PowerShell
$psv = $PSVersionTable.PSVersion
Write-Host ("  PowerShell {0}  ->  OK" -f $psv) -ForegroundColor Green

# Admin?
$esAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($esAdmin) { Write-Host "  Permisos admin       ->  OK" -ForegroundColor Green }
else {
    Write-Host "  Permisos admin       ->  FALTA (registrar la tarea puede fallar)" -ForegroundColor Yellow
    Write-Host "     Reabri PowerShell como Administrador si el paso [3] falla." -ForegroundColor Yellow
}

# Lector de xlsx: modulo ImportExcel (reemplaza a Excel COM, corre headless)
$mod = Get-Module -ListAvailable -Name ImportExcel | Select-Object -First 1
if (-not $mod) {
    Write-Host "  ImportExcel          ->  NO instalado, intento instalarlo..." -ForegroundColor Yellow
    try {
        Install-Module ImportExcel -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        $mod = Get-Module -ListAvailable -Name ImportExcel | Select-Object -First 1
    } catch {
        Write-Host "     Fallo la instalacion automatica: $($_.Exception.Message)" -ForegroundColor Red
    }
}
if ($mod) {
    Write-Host ("  ImportExcel {0}     ->  OK (lee .xlsx sin Excel instalado)" -f $mod.Version) -ForegroundColor Green
} else {
    $okTodo = $false
    Write-Host "  ImportExcel          ->  FALTA" -ForegroundColor Red
    Write-Host "     El pipeline lee los .xlsx (Cepea + cargas) con este modulo." -ForegroundColor Red
    Write-Host "     Instalalo a mano:  Install-Module ImportExcel -Scope CurrentUser -Force" -ForegroundColor Red
}

# El modulo tiene que estar visible para el MISMO PowerShell que corre la tarea
# (Windows PowerShell 5.1 usa Documents\WindowsPowerShell\Modules; pwsh 7 usa
#  Documents\PowerShell\Modules). Si esta solo en uno, se copia al otro.
$ps51Mods = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
if ($mod -and -not (Test-Path (Join-Path $ps51Mods 'ImportExcel'))) {
    try {
        if (-not (Test-Path $ps51Mods)) { New-Item -ItemType Directory -Path $ps51Mods -Force | Out-Null }
        Copy-Item (Split-Path $mod.ModuleBase -Parent) -Destination $ps51Mods -Recurse -Force -ErrorAction Stop
        Write-Host "  ImportExcel copiado tambien a Windows PowerShell 5.1" -ForegroundColor DarkGray
    } catch {
        Write-Host "  No pude copiar ImportExcel a PS 5.1: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Internet a las fuentes clave
$hosts = 'www.hfbrasil.org.br','api.open-meteo.com','power.larc.nasa.gov',
         'preciosdelagro.com','www.tridge.com','gate.whapi.cloud'
$netOk = 0
foreach ($h in $hosts) {
    try {
        if (Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction Stop) { $netOk++ }
    } catch {
        # Test-Connection puede fallar por ICMP bloqueado; probamos TCP 443
        try { $t = Test-NetConnection -ComputerName $h -Port 443 -WarningAction SilentlyContinue
              if ($t.TcpTestSucceeded) { $netOk++ } } catch {}
    }
}
if ($netOk -ge 4) { Write-Host ("  Internet fuentes     ->  OK ({0}/{1} alcanzables)" -f $netOk,$hosts.Count) -ForegroundColor Green }
else { Write-Host ("  Internet fuentes     ->  PARCIAL ({0}/{1}) - revisar firewall" -f $netOk,$hosts.Count) -ForegroundColor Yellow }

# --- 2) Config WhatsApp ---------------------------------------------------
Titulo "[2/4] Config WhatsApp (Whapi)"
$waPath = Join-Path $base 'config\whatsapp.json'
if (Test-Path $waPath) {
    try {
        $wa = Get-Content $waPath -Raw | ConvertFrom-Json
        $nPhones = @($wa.phones).Count
        $tokenOk = -not [string]::IsNullOrWhiteSpace($wa.token)
        Write-Host ("  enabled = {0} | numeros = {1} | token = {2}" -f `
            $wa.enabled, $nPhones, ($(if($tokenOk){'cargado'}else{'FALTA'}))) -ForegroundColor $(if($tokenOk -and $nPhones -gt 0){'Green'}else{'Yellow'})
    } catch { Write-Host "  No pude leer whatsapp.json - revisalo a mano" -ForegroundColor Yellow }
} else {
    Write-Host "  No existe config\whatsapp.json - los avisos WA quedaran apagados" -ForegroundColor Yellow
}

# --- 3) Registrar tarea programada ----------------------------------------
Titulo "[3/4] Registrando tarea programada '$TASK_NAME'"
try {
    # La tarea corre correr_servidor.ps1 (04/09/2026): si la carpeta es un clon
    # git hace pull antes de correr el pipeline, asi con pushear a GitHub desde
    # la laptop alcanza. Ese wrapper es el que escribe last_run.log.
    $wrapper = Join-Path $base 'correr_servidor.ps1'
    if (-not (Test-Path $wrapper)) { throw "falta correr_servidor.ps1 al lado de este setup" }
    $cmd     = "& '{0}'" -f $wrapper
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"{0}`"" -f $cmd) `
        -WorkingDirectory $base

    $trigFri = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday    -At '7:00PM'
    $trigWed = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Wednesday -At '12:00PM'

    $settings = New-ScheduledTaskSettingsSet `
        -WakeToRun `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
        -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 10) `
        -MultipleInstances IgnoreNew

    # Ya no hace falta Excel COM (ni escritorio ni auto-login): se lee con ImportExcel.
    # Por eso se registra con LogonType S4U = "ejecutar este con o sin sesion iniciada",
    # sin guardar contrasena. Si S4U falla (requiere admin), cae a Interactive.
    $userId = "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME
    $modo = 'S4U (corre con o sin sesion iniciada)'
    try {
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
        Register-ScheduledTask -TaskName $TASK_NAME `
            -Action $action -Trigger @($trigFri, $trigWed) `
            -Settings $settings -Principal $principal `
            -Description 'Pipeline banana Almar: baja precios Cepea/Ecuador/PY + clima y manda alertas WhatsApp. Mie 12:00 y Vie 19:00.' `
            -Force | Out-Null
    } catch {
        $modo = 'Interactive (solo con el usuario logueado)'
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TASK_NAME `
            -Action $action -Trigger @($trigFri, $trigWed) `
            -Settings $settings -Principal $principal `
            -Description 'Pipeline banana Almar: baja precios Cepea/Ecuador/PY + clima y manda alertas WhatsApp. Mie 12:00 y Vie 19:00.' `
            -Force | Out-Null
    }

    Write-Host "  Tarea registrada OK." -ForegroundColor Green
    Write-Host "  Disparos: Miercoles 12:00  y  Viernes 19:00" -ForegroundColor Green
    Write-Host "  Corre como: $userId - $modo" -ForegroundColor Green
} catch {
    Write-Host "  ERROR registrando la tarea: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  -> Reabri PowerShell COMO ADMINISTRADOR y volve a correr este setup." -ForegroundColor Red
}

# --- 4) Prueba opcional ---------------------------------------------------
Titulo "[4/4] Listo"
Write-Host "  Para probar UNA corrida ahora mismo:" -ForegroundColor White
Write-Host "     Start-ScheduledTask -TaskName '$TASK_NAME'" -ForegroundColor Gray
Write-Host "  o correr el pipeline a mano y ver la salida:" -ForegroundColor White
Write-Host "     & `"$scriptMain`"" -ForegroundColor Gray
Write-Host ""
Write-Host "  Ya NO hace falta Excel ni auto-login: los .xlsx se leen con ImportExcel" -ForegroundColor Green
Write-Host "  y la tarea corre con o sin sesion iniciada. Solo tiene que estar" -ForegroundColor Green
Write-Host "  la PC prendida y con internet a la hora del disparo." -ForegroundColor Green
Line
