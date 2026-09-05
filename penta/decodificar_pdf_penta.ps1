# ============================================================
#  Decodificador de PDFs de Penta Transaction
#  (desglose_operadorLocal_UYimport_*.pdf)
#
#  Los PDFs guardan el texto en UTF-16BE con las fuentes subset
#  desplazadas +28 sobre el codigo de glifo. Leidos crudos, los
#  numeros salen como letras. Este script deshace el corrimiento.
#
#  Glifos que NO siguen el +28:
#    0x62='$'  0x74='%'  0x0267='a'  0x0273='i'  0x0278='o'  0x026D='e'
#
#  Uso:  .\decodificar_pdf_penta.ps1
#        .\decodificar_pdf_penta.ps1 -Dir "C:\ruta\con\pdfs"
#        .\decodificar_pdf_penta.ps1 > salida.txt
#
#  Guardado en el proyecto el 03/09/2026 (venia de %TEMP%).
# ============================================================

param([string]$Dir)

$ErrorActionPreference = 'Stop'
if (-not $Dir) { $Dir = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Users\Usuario\Desktop\poronga\penta' } }
$dir = $Dir

function Try-Inflate { param([byte[]]$d, [int]$off)
    if ($d.Length -le $off) { return $null }
    try { $ms=New-Object System.IO.MemoryStream(,([byte[]]$d[$off..($d.Length-1)]))
          $ds=New-Object System.IO.Compression.DeflateStream($ms,[System.IO.Compression.CompressionMode]::Decompress)
          $o=New-Object System.IO.MemoryStream; $ds.CopyTo($o); $ds.Dispose(); $ms.Dispose()
          if ($o.Length -eq 0) { return $null }
          return $o.ToArray() } catch { return $null }
}

function Expand-Flate { param([byte[]]$d)
    # Cabecera zlib valida: metodo deflate (nibble bajo = 8) y checksum del
    # par de bytes divisible por 31. NO alcanza con mirar si el byte 0 es 0x78:
    # Penta emite tambien 0x48/0x68 (ventanas mas chicas) segun el reporte.
    $esZlib = ($d.Length -gt 2) -and (($d[0] -band 0x0F) -eq 8) -and (((([int]$d[0] -shl 8) -bor [int]$d[1]) % 31) -eq 0)
    $orden = if ($esZlib) { @(2,0) } else { @(0,2) }
    foreach ($off in $orden) {
        $r = Try-Inflate $d $off
        if ($r) { return $r }
    }
    return $null
}

# glifos del subset que no siguen el +28
$ESP = @{ 0x62='$'; 0x74='%'; 0x0267=[char]0xE1; 0x0273=[char]0xED; 0x0278=[char]0xF3; 0x026D=[char]0xE9 }

function Decodificar { param([int[]]$cods)
    $sb = New-Object System.Text.StringBuilder
    for ($i=0; $i -lt $cods.Count; $i+=2) {
        if ($i+1 -ge $cods.Count) { break }
        $u = ($cods[$i] -shl 8) -bor $cods[$i+1]
        if ($ESP.ContainsKey($u)) { [void]$sb.Append($ESP[$u]); continue }
        $v = $u + 28
        if ($v -ge 32 -and $v -le 126) { [void]$sb.Append([char]$v) } else { [void]$sb.Append('?') }
    }
    $sb.ToString()
}

function Bytes-DeLiteral { param([string]$lit)
    $out = New-Object System.Collections.ArrayList
    for ($i=0; $i -lt $lit.Length; $i++) {
        $ch = $lit[$i]
        if ($ch -eq '\') { $i++
            if ($i -ge $lit.Length) { break }
            $nx = $lit[$i]
            if ($nx -match '[0-7]') { $oct="$nx"
                while ($oct.Length -lt 3 -and ($i+1) -lt $lit.Length -and $lit[$i+1] -match '[0-7]') { $i++; $oct+=$lit[$i] }
                [void]$out.Add([int][Convert]::ToInt32($oct,8))
            } else { [void]$out.Add([int][char]$nx) }
        } else { [void]$out.Add([int][char]$ch) }
    }
    return $out
}

foreach ($f in (Get-ChildItem $dir -Filter *.pdf | Sort-Object Name)) {
    $bytes=[System.IO.File]::ReadAllBytes($f.FullName)
    $latin=[System.Text.Encoding]::GetEncoding(28591)
    $raw=$latin.GetString($bytes)

    # Juntar TODOS los streams de texto, no solo el primero: los reportes de
    # varias paginas traen un content stream por pagina.
    $paginas = New-Object System.Collections.ArrayList
    $idx=0
    while ($true) {
        $s=$raw.IndexOf('stream',$idx); if ($s -lt 0) { break }
        # 'endstream' tambien contiene 'stream' — saltarlo o el offset queda corrido
        if ($s -ge 3 -and $raw.Substring($s-3,3) -eq 'end') { $idx=$s+6; continue }
        $e=$raw.IndexOf('endstream',$s); if ($e -lt 0) { break }
        $ini=$s+6; while ($ini -lt $raw.Length -and ($raw[$ini] -eq "`r" -or $raw[$ini] -eq "`n")) { $ini++ }
        $len=$e-$ini
        if ($len -gt 0) {
            $c=New-Object byte[] $len; [Array]::Copy($bytes,$ini,$c,0,$len)
            $p=Expand-Flate $c
            if ($p) { $t=$latin.GetString($p); if ($t -match 'T[jJ]') { [void]$paginas.Add($t) } }
        }
        $idx=$e+9
    }
    if ($paginas.Count -eq 0) { Write-Host "$($f.Name): sin stream de texto" -ForegroundColor Red; continue }

    Write-Host "==========================================================" -ForegroundColor Cyan
    # OJO: cada elemento es un content stream, no necesariamente una pagina.
    # Un reporte de 1 pagina puede venir partido en varios bloques, y el corte
    # puede separar una etiqueta de su valor ("Kgs. Brutos" en un bloque y el
    # numero en el siguiente). Al leer, empalmar bloques consecutivos.
    Write-Host " $($f.Name)   ($($paginas.Count) bloques)" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    $np = 0
    foreach ($target in $paginas) {
        $np++
        if ($paginas.Count -gt 1) { Write-Host "  ---- bloque $np ----" -ForegroundColor DarkGray }
        foreach ($bt in [regex]::Matches($target,'(?s)BT(.*?)ET')) {
            $body=$bt.Groups[1].Value
            $acc = New-Object System.Collections.ArrayList
            foreach ($sm in [regex]::Matches($body,'\(((?:[^()\\]|\\.)*)\)')) {
                foreach ($b in (Bytes-DeLiteral $sm.Groups[1].Value)) { [void]$acc.Add($b) }
            }
            if ($acc.Count -eq 0) { continue }
            $fm=[regex]::Match($body,'(/F\d+)')
            $txt = if ($fm.Groups[1].Value -eq '/F1') { -join ($acc | ForEach-Object { [char]$_ }) } else { Decodificar $acc }
            $txt = $txt.Trim()
            if ($txt -ne '') { Write-Host "  $txt" }
        }
    }
    Write-Host ""
}
