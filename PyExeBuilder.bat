@echo off
chcp 65001 >nul 2>&1
setlocal
title Python -^> EXE Derleyici
set "SELF=%~f0"
where powershell >nul 2>&1 || (echo PowerShell bulunamadı. & pause & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content -LiteralPath $env:SELF -Raw -Encoding UTF8; $i = $c.IndexOf([char]35 + '___PS___'); if($i -lt 0){ Write-Host 'Betik bölümü bulunamadı.'; exit 1 }; Invoke-Expression $c.Substring($i)"
set "PS_EXIT=%ERRORLEVEL%"
echo.
echo Kapatmak için bir tuşa basın...
pause >nul
exit /b %PS_EXIT%

#___PS___
# ============================================================
#  Python -> EXE Derleyici  (v8.8 - pencere flash fix + temizlik)
# ============================================================

try {
    $aliveFile = Join-Path $env:TEMP 'PyExeBuilder_alive.txt'
    [IO.File]::WriteAllText($aliveFile, ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "`r`n"))
} catch {}

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding  = [Text.Encoding]::UTF8 } catch {}
try { $Host.UI.RawUI.WindowTitle = 'Python -> EXE Derleyici' } catch {}

$env:PYTHONUTF8       = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONDONTWRITEBYTECODE = '1'

$MARKER = '.pyexebuilder'

# ---------- Yok sayilan klasorler ----------
$script:IgnoreBase = @('\.git','\.hg','\.svn','__pycache__','\.pytest_cache','\.mypy_cache','\.ruff_cache',
    'venv','\.venv','env','\.env','virtualenv','\.idea','\.vscode','\.vs',
    'build','dist','EXE_Cikti','PyExeBuilder_Logs','_derleme_gecici',
    'node_modules','\.tox','\.nox','\.eggs','\.gradle','\.next','\.cache')
$script:IgnoreRx   = ''
$script:RootPath   = $null

function Set-IgnoreRegex {
    param([string[]]$ExtraNames = @())
    $parts = @($script:IgnoreBase)
    foreach ($n in $ExtraNames) {
        if ($n) { $parts += [regex]::Escape($n) }
    }
    $script:IgnoreRx = '(?i)\\(' + ($parts -join '|') + ')(\\|$)'
}
Set-IgnoreRegex

function Test-Ignored {
    param([string]$FullPath)
    $rel = $FullPath
    if ($script:RootPath -and $FullPath.StartsWith($script:RootPath, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $FullPath.Substring($script:RootPath.Length)
    }
    $rel = '\' + $rel.TrimStart('\')
    return ($rel -match $script:IgnoreRx)
}

function Get-BuilderOutputNames {
    param([string]$Root)
    $names = @()
    foreach ($d in (Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName $MARKER)) { $names += $d.Name }
    }
    return $names
}

# ---------- Python literal kacisi (kod enjeksiyonunu engeller) ----------
function ConvertTo-PyLiteral {
    param([string]$S)
    if ($null -eq $S) { return '""' }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $S.ToCharArray()) {
        $code = [int]$ch
        switch ($ch) {
            '"'  { [void]$sb.Append('\"');  continue }
            '\'  { [void]$sb.Append('\\');  continue }
            "`n" { [void]$sb.Append('\n');  continue }
            "`r" { [void]$sb.Append('\r');  continue }
            "`t" { [void]$sb.Append('\t');  continue }
        }
        if ($code -lt 32 -or $code -eq 0x7F) {
            [void]$sb.AppendFormat('\x{0:x2}', $code)
        } else {
            [void]$sb.Append($ch)
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# ---------- Windows komut satiri arguman kacisi ----------
function ConvertTo-CmdArg {
    param([string]$A)
    if ($null -eq $A -or $A -eq '') { return '""' }
    if ($A -notmatch '[\s"]') { return $A }
    $b = $A -replace '(\\*)"', '$1$1\"'
    $b = $b -replace '(\\+)$', '$1$1'
    return '"' + $b + '"'
}

# ---------- Native komut sarmalayici (tamponlu) ----------
function Invoke-Native {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [string[]]$Arguments = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out  = @()
    $code = -1
    try {
        $out  = @(& $Exe @Arguments 2>&1)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        $out  = @($_.Exception.Message)
        $code = -1
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{
        Output   = $out
        ExitCode = [int]$code
    }
}

# ---------- Native komut (canli cikti + donen simge) ----------
function Invoke-NativeLive {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$Label = 'Isleniyor',
        [switch]$Quiet,
        [int]$TimeoutSeconds = 0
    )

    $outFile = Join-Path $env:TEMP ('pyexebuilder_out_' + [Guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path $env:TEMP ('pyexebuilder_err_' + [Guid]::NewGuid().ToString('N') + '.txt')

    $lines    = New-Object System.Collections.Generic.List[string]
    $exitCode = -1
    $pos      = @{ out = 0L; err = 0L }
    $partial  = @{ out = ''; err = '' }

    function _readNew {
        param([string]$Path, [string]$Key, [switch]$Flush)
        if (-not (Test-Path -LiteralPath $Path)) { return }
        try {
            $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        } catch { return }
        try {
            [void]$fs.Seek($pos[$Key], [IO.SeekOrigin]::Begin)
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            $chunk = $sr.ReadToEnd()
            $pos[$Key] = $fs.Position
            if (-not $chunk -and -not $partial[$Key]) { return }
            # Yarim kalan satiri bir sonraki turda tamamla; yalnizca TAM satirlari yayinla
            $buffer = $partial[$Key] + $chunk
            $lastNl = $buffer.LastIndexOf("`n")
            if ($lastNl -lt 0) {
                if (-not $Flush) { $partial[$Key] = $buffer; return }
                $complete = $buffer
                $partial[$Key] = ''
            } else {
                $complete = $buffer.Substring(0, $lastNl + 1)
                $partial[$Key] = $buffer.Substring($lastNl + 1)
            }
            $complete = $complete -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
            foreach ($ln in ($complete -split "`n")) {
                $t = $ln
                if ($t -match "`r") { $t = ($t -split "`r")[-1] }
                $t = $t.TrimEnd()
                if ($t -eq '') { continue }
                $lines.Add($t)
                if (-not $Quiet) {
                    Write-Host ("`r" + (' ' * 110) + "`r") -NoNewline
                    Write-Host ('   ' + $t)
                }
            }
        } finally {
            $fs.Close()
        }
    }

    try {
        $argLine = ($Arguments | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' '

        $proc = Start-Process -FilePath $Exe -ArgumentList $argLine `
                    -RedirectStandardOutput $outFile `
                    -RedirectStandardError  $errFile `
                    -NoNewWindow -PassThru
        $null = $proc.Handle   # ExitCode'un bos (null) donmemesi icin tutamaci onbellekle

        $spin     = [char[]]'|/-\'
        $i        = 0
        $start    = Get-Date
        $lastTick = Get-Date

        while (-not $proc.HasExited) {
            _readNew -Path $outFile -Key 'out'
            _readNew -Path $errFile -Key 'err'

            if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
                try { $proc.Kill() } catch {}
                break
            }
            if (-not $Quiet -and ((Get-Date) - $lastTick).TotalMilliseconds -gt 160) {
                Write-Host -NoNewline ("`r   " + $spin[$i % 4] + " " + $Label + "     ") -ForegroundColor Cyan
                $lastTick = Get-Date
                $i++
            }
            Start-Sleep -Milliseconds 150
        }

        try { $proc.WaitForExit() } catch {}

        _readNew -Path $outFile -Key 'out' -Flush
        _readNew -Path $errFile -Key 'err' -Flush

        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode) { $exitCode = 0 }

        if (-not $Quiet) {
            Write-Host ("`r" + (' ' * 110) + "`r") -NoNewline
            if ($exitCode -eq 0) {
                Write-Host ('   ' + [char]0x2713 + ' ' + $Label + ' tamamlandı.') -ForegroundColor Green
            } else {
                Write-Host ('   ' + [char]0x2717 + ' ' + $Label + ' başarısız (kod: ' + $exitCode + ').') -ForegroundColor Red
            }
        }
    } catch {
        $lines.Add($_.Exception.Message)
        $exitCode = -1
    } finally {
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Output   = @($lines)
        ExitCode = [int]$exitCode
    }
}

# ---------- Log ----------
$script:LogDir           = $null
$script:SessionLog       = $null
$script:TranscriptActive = $false
$script:ErrorLogPath     = $null

function Get-LogDirectory {
    param([string]$Root)
    $candidates = @()
    if ($Root -and (Test-Path -LiteralPath $Root)) { $candidates += (Join-Path $Root 'PyExeBuilder_Logs') }
    if ($env:TEMP)        { $candidates += (Join-Path $env:TEMP 'PyExeBuilder_Logs') }
    if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE 'PyExeBuilder_Logs') }
    foreach ($c in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $c)) { New-Item -ItemType Directory -Force -Path $c | Out-Null }
            $test = Join-Path $c ('.wtest_' + [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($test, 'x')
            Remove-Item -LiteralPath $test -Force -ErrorAction SilentlyContinue
            return $c
        } catch {}
    }
    return $null
}

function Start-Logging {
    param([string]$Root)
    $script:LogDir = Get-LogDirectory -Root $Root
    if (-not $script:LogDir) { return }
    try {
        $script:SessionLog = Join-Path $script:LogDir ('oturum_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
        Start-Transcript -Path $script:SessionLog -Force | Out-Null
        $script:TranscriptActive = $true
    } catch { $script:TranscriptActive = $false }
}

function Write-Line {
    param([string]$Text, [string]$Color)
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
    if ($script:SessionLog -and -not $script:TranscriptActive) {
        try { Add-Content -LiteralPath $script:SessionLog -Value $Text -Encoding UTF8 } catch {}
    }
}

function Save-ErrorReport {
    param([Parameter(Mandatory=$true)] $ErrorRecord, [string]$Context = '')
    $ex    = $ErrorRecord.Exception
    $inv   = $ErrorRecord.InvocationInfo
    $stack = $ErrorRecord.ScriptStackTrace
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('============================================================')
    $lines.Add(' PyExeBuilder - HATA RAPORU')
    $lines.Add(' Tarih     : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add(' Sistem    : ' + [Environment]::OSVersion.VersionString)
    $lines.Add(' PS Sürümü : ' + $PSVersionTable.PSVersion.ToString())
    if ($Context) { $lines.Add(' Bağlam    : ' + $Context) }
    $lines.Add('============================================================')
    $lines.Add('')
    $lines.Add('Mesaj         : ' + $ex.Message)
    $lines.Add('Hata Tipi     : ' + $ex.GetType().FullName)
    if ($inv -and $inv.ScriptLineNumber) { $lines.Add('Satir         : ' + $inv.ScriptLineNumber) }
    if ($inv -and $inv.Line)             { $lines.Add('Çalışan Komut : ' + $inv.Line.Trim()) }
    if ($inv -and $inv.ScriptName)       { $lines.Add('Kaynak        : ' + $inv.ScriptName) }
    try { $lines.Add('Kategori      : ' + $ErrorRecord.CategoryInfo.GetMessage()) } catch {}
    try { $lines.Add('FQID          : ' + $ErrorRecord.FullyQualifiedErrorId) } catch {}
    $lines.Add('')
    $lines.Add('--- Ayrıntılı Mesaj ---')
    $lines.Add($ex.ToString())
    if ($ex.InnerException) {
        $lines.Add(''); $lines.Add('--- İç Hata (Inner) ---'); $lines.Add($ex.InnerException.ToString())
    }
    $lines.Add(''); $lines.Add('--- Yığın İzi (Stack Trace) ---'); $lines.Add(($stack | Out-String))
    if ($ErrorRecord.TargetObject) {
        $lines.Add(''); $lines.Add('--- TargetObject ---')
        try { $lines.Add(($ErrorRecord.TargetObject | Out-String)) } catch {}
    }
    $text = ($lines -join [Environment]::NewLine)
    $fileName = 'hata_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log'
    $tryDirs  = @()
    if ($script:LogDir)   { $tryDirs += $script:LogDir }
    if ($env:TEMP)        { $tryDirs += (Join-Path $env:TEMP 'PyExeBuilder_Logs') }
    if ($env:USERPROFILE) { $tryDirs += (Join-Path $env:USERPROFILE 'PyExeBuilder_Logs') }
    $written = $null
    foreach ($d in $tryDirs) {
        try {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
            $p = Join-Path $d $fileName
            [IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding($true)))
            $written = $p
            $script:ErrorLogPath = $p
            if (-not $script:LogDir) { $script:LogDir = $d }
            break
        } catch {}
    }
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Red
    Write-Host '                         HATA OLUŞTU' -ForegroundColor Red
    Write-Host '  ============================================================' -ForegroundColor Red
    Write-Host ''
    Write-Host ('   Mesaj        : ' + $ex.Message) -ForegroundColor Red
    Write-Host ('   Hata Tipi    : ' + $ex.GetType().FullName) -ForegroundColor Yellow
    if ($inv -and $inv.ScriptLineNumber) { Write-Host ('   Satir        : ' + $inv.ScriptLineNumber) -ForegroundColor Yellow }
    if ($inv -and $inv.Line)             { Write-Host ('   Çalışan Komut: ' + $inv.Line.Trim()) -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '   --- Ayrıntılı Mesaj ---' -ForegroundColor Yellow
    Write-Host ($ex.ToString()) -ForegroundColor DarkYellow
    if ($ex.InnerException) {
        Write-Host ''; Write-Host '   --- İç Hata (Inner) ---' -ForegroundColor Yellow
        Write-Host ($ex.InnerException.ToString()) -ForegroundColor DarkYellow
    }
    if ($stack) {
        Write-Host ''; Write-Host '   --- Yığın İzi (Stack Trace) ---' -ForegroundColor Yellow
        foreach ($line in ($stack -split "`n")) { Write-Host ('   ' + $line.TrimEnd()) -ForegroundColor DarkGray }
    }
    Write-Host ''
    if ($written)            { Write-Host ('   Hata raporu : ' + $written) -ForegroundColor Cyan }
    else                     { Write-Host '   Hata raporu dosyaya YAZILAMADI.' -ForegroundColor Red }
    if ($script:SessionLog)  { Write-Host ('   Oturum logu : ' + $script:SessionLog) -ForegroundColor Cyan }
    if ($script:LogDir)      { Write-Host ('   Log klasörü : ' + $script:LogDir) -ForegroundColor DarkCyan }
}

function Write-Header {
    param([string]$Text)
    Clear-Host
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * [Math]::Max(10, $Text.Length))) -ForegroundColor DarkCyan
    Write-Host ''
}

# ---------- Menu ----------
function Show-Menu {
    param(
        [string]   $Title,
        [string[]] $Items,
        [string[]] $Descriptions = $null,
        [string]   $Hint = 'Yukarı/Aşağı ok tuşları ile seçin, Enter ile onaylayın.'
    )
    $idx = 0
    while ($true) {
        Write-Header $Title
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($i -eq $idx) { Write-Host ('   > ' + $Items[$i]) -ForegroundColor Black -BackgroundColor Gray }
            else             { Write-Host ('     ' + $Items[$i]) }
        }
        if ($Descriptions -and $Descriptions.Count -gt $idx -and $Descriptions[$idx]) {
            Write-Host ''
            foreach ($line in ($Descriptions[$idx] -split "`n")) {
                Write-Host ('   ' + $line) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        Write-Host ('   ' + $Hint) -ForegroundColor DarkGray
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'UpArrow'   { $idx = ($idx - 1 + $Items.Count) % $Items.Count }
            'DownArrow' { $idx = ($idx + 1) % $Items.Count }
            'Home'      { $idx = 0 }
            'End'       { $idx = $Items.Count - 1 }
            'Enter'     { return $idx }
        }
    }
}

# ---------- Proje adi ----------
function Get-SafeFileName {
    param([string]$Text)
    $bad   = [IO.Path]::GetInvalidFileNameChars()
    $clean = -join @($Text.ToCharArray() | Where-Object { $bad -notcontains $_ })
    return $clean.Trim().TrimEnd('.').Trim()
}

function Read-ProjectName {
    param([string]$Root, [string]$Default)
    $reserved = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$'
    while ($true) {
        Write-Header 'Proje adını yazın'
        Write-Host '   EXE dosyası ve diger bileşenler, bu adla oluşturulacak bir klasöre çıktılanacaktır.' -ForegroundColor DarkGray
        Write-Host '   EXE dosyası da bu adı taşıyacaktır.' -ForegroundColor DarkGray
        Write-Host ('   Klasör şurada oluşturulur: ' + $Root) -ForegroundColor DarkGray
        Write-Host ''
        $raw = Read-Host ('   Proje adı (boş bırakırsanız: ' + $Default + ')')
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $Default }
        $raw  = $raw.Trim().Trim('"').Trim("'")
        $name = Get-SafeFileName -Text $raw
        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Host ''; Write-Host '   Geçerli bir ad girmediniz. Tekrar deneyin.' -ForegroundColor Red
            Start-Sleep -Seconds 2; continue
        }
        if ($name -match $reserved) {
            Write-Host ''; Write-Host ('   "' + $name + '" Windows tarafından ayrılmış bir addır. Başka bir ad deneyin.') -ForegroundColor Red
            Start-Sleep -Seconds 2; continue
        }
        if ($name.Length -gt 80) { $name = $name.Substring(0, 80).TrimEnd('.', ' ') }
        if ($name -ne $raw) {
            Write-Host ''; Write-Host ('   Dosya adında kullanılamayan karakterler temizlendi: ' + $name) -ForegroundColor Yellow
            Start-Sleep -Milliseconds 1800
        }
        $dir = Join-Path $Root $name
        if (Test-Path -LiteralPath $dir -PathType Leaf) {
            Write-Host ''; Write-Host '   Aynı adda bir dosya zaten var. Başka bir ad deneyin.' -ForegroundColor Red
            Start-Sleep -Seconds 2; continue
        }
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $hasItems = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count -gt 0
            if ($hasItems) {
                $isOurs = Test-Path -LiteralPath (Join-Path $dir $MARKER)
                if ($isOurs) {
                    $items  = @('Bu klasörü kullan', 'Başka bir ad gir')
                    $useIdx = 0
                    $descs  = @(
                        "Bu klasör daha önceki bir derlemenin çıktı klasörü.`nAynı adlı dosyaların üzerine yazılır.",
                        'Farklı bir proje adı girmek için seçin.'
                    )
                } else {
                    $items  = @('Başka bir ad gir', 'Bu klasörü yine de kullan')
                    $useIdx = 1
                    $descs  = @(
                        'Önerilir: farklı bir proje adı girin.',
                        "DİKKAT: Bu klasör daha önceki bir derlemeye ait görünmüyor.`nİçinde proje dosyalarınız olabilir ve aynı adlı dosyaların üzerine yazılabilir."
                    )
                }
                $s = Show-Menu -Title ("'" + $name + "' klasörü zaten mevcut") -Items $items -Descriptions $descs
                if ($s -ne $useIdx) { continue }
            }
        }
        return $name
    }
}

# ---------- Dosya secici ----------
function Select-ProjectFiles {
    param([string]$Root)
    $allFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Where-Object { -not (Test-Ignored $_.FullName) })
    if ($allFiles.Count -eq 0) { return @() }
    $sel = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $allFiles) { [void]$sel.Add($f.FullName) }
    $cur = (Resolve-Path -LiteralPath $Root).Path
    $idx = 0
    $top = 0
    $page = 15
    while ($true) {
        $dirs = @(Get-ChildItem -LiteralPath $cur -Directory -Force -ErrorAction SilentlyContinue |
                  Where-Object { -not (Test-Ignored ($_.FullName + '\')) } | Sort-Object Name)
        $files = @(Get-ChildItem -LiteralPath $cur -File -Force -ErrorAction SilentlyContinue |
                   Where-Object { -not (Test-Ignored $_.FullName) } | Sort-Object Name)
        $entries = @()
        $entries += [pscustomobject]@{ Type='done'; Label='>> Seçimi tamamla ve devam et' }
        $entries += [pscustomobject]@{ Type='all';  Label='[*] Bu klasördeki TÜM dosyaları seç / kaldır (alt klasörler dahil)' }
        if ($cur -ne (Resolve-Path -LiteralPath $Root).Path) {
            $entries += [pscustomobject]@{ Type='up'; Label='..  Üst klasöre dön' }
        }
        foreach ($d in $dirs) {
            $under = @($allFiles | Where-Object { $_.FullName.StartsWith($d.FullName + '\', [StringComparison]::OrdinalIgnoreCase) })
            $cnt = @($under | Where-Object { $sel.Contains($_.FullName) }).Count
            $mark = if ($under.Count -eq 0) { ' ' } elseif ($cnt -eq $under.Count) { 'X' } elseif ($cnt -gt 0) { '~' } else { ' ' }
            $entries += [pscustomobject]@{ Type='dir'; Label=("[$mark] [KLASÖR] " + $d.Name); Path=$d.FullName }
        }
        foreach ($f in $files) {
            $mark = if ($sel.Contains($f.FullName)) { 'X' } else { ' ' }
            $entries += [pscustomobject]@{ Type='file'; Label=("[$mark] " + $f.Name); Path=$f.FullName }
        }
        if ($idx -ge $entries.Count) { $idx = $entries.Count - 1 }
        if ($idx -lt 0) { $idx = 0 }
        if ($idx -lt $top) { $top = $idx }
        if ($idx -ge $top + $page) { $top = $idx - $page + 1 }
        Write-Header 'Derlemeye dahil edilecek dosyaları seçin'
        Write-Host ('   Klasör: ' + $cur) -ForegroundColor Yellow
        Write-Host ('   Seçili dosya sayısı: ' + $sel.Count + ' / ' + $allFiles.Count) -ForegroundColor Yellow
        Write-Host ''
        $end = [Math]::Min($entries.Count, $top + $page)
        if ($top -gt 0) { Write-Host '     ^ ...' -ForegroundColor DarkGray }
        for ($i = $top; $i -lt $end; $i++) {
            $line = $entries[$i].Label
            if ($i -eq $idx) { Write-Host ('   > ' + $line) -ForegroundColor Black -BackgroundColor Gray }
            elseif ($entries[$i].Type -eq 'dir') { Write-Host ('     ' + $line) -ForegroundColor Cyan }
            elseif ($entries[$i].Type -in @('done','all','up')) { Write-Host ('     ' + $line) -ForegroundColor Green }
            else { Write-Host ('     ' + $line) }
        }
        if ($end -lt $entries.Count) { Write-Host '     v ...' -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host '   Ok tuşları: gezin   |   Boşluk: seç/kaldır   |   Enter: klasöre gir / işlemi uygula   |   Esc: üst klasör' -ForegroundColor DarkGray
        $k = [Console]::ReadKey($true)
        $e = $entries[$idx]
        switch ($k.Key) {
            'UpArrow'   { $idx-- ; if ($idx -lt 0) { $idx = $entries.Count - 1 } }
            'DownArrow' { $idx++ ; if ($idx -ge $entries.Count) { $idx = 0 } }
            'PageUp'    { $idx = [Math]::Max(0, $idx - $page) }
            'PageDown'  { $idx = [Math]::Min($entries.Count - 1, $idx + $page) }
            'Backspace' {
                if ($cur -ne (Resolve-Path -LiteralPath $Root).Path) { $cur = Split-Path $cur -Parent; $idx = 0; $top = 0 }
            }
            'Escape' {
                if ($cur -ne (Resolve-Path -LiteralPath $Root).Path) { $cur = Split-Path $cur -Parent; $idx = 0; $top = 0 }
            }
            'Spacebar' {
                if ($e.Type -eq 'file') {
                    if ($sel.Contains($e.Path)) { [void]$sel.Remove($e.Path) } else { [void]$sel.Add($e.Path) }
                } elseif ($e.Type -eq 'dir') {
                    $under = @($allFiles | Where-Object { $_.FullName.StartsWith($e.Path + '\', [StringComparison]::OrdinalIgnoreCase) })
                    $allSel = ($under.Count -gt 0) -and (@($under | Where-Object { $sel.Contains($_.FullName) }).Count -eq $under.Count)
                    foreach ($f in $under) { if ($allSel) { [void]$sel.Remove($f.FullName) } else { [void]$sel.Add($f.FullName) } }
                } elseif ($e.Type -eq 'all') {
                    $under = @($allFiles | Where-Object { $_.FullName.StartsWith($cur + '\', [StringComparison]::OrdinalIgnoreCase) })
                    $allSel = ($under.Count -gt 0) -and (@($under | Where-Object { $sel.Contains($_.FullName) }).Count -eq $under.Count)
                    foreach ($f in $under) { if ($allSel) { [void]$sel.Remove($f.FullName) } else { [void]$sel.Add($f.FullName) } }
                }
            }
            'Enter' {
                switch ($e.Type) {
                    'dir'  { $cur = $e.Path; $idx = 0; $top = 0 }
                    'up'   { $cur = Split-Path $cur -Parent; $idx = 0; $top = 0 }
                    'all'  {
                        $under = @($allFiles | Where-Object { $_.FullName.StartsWith($cur + '\', [StringComparison]::OrdinalIgnoreCase) })
                        $allSel = ($under.Count -gt 0) -and (@($under | Where-Object { $sel.Contains($_.FullName) }).Count -eq $under.Count)
                        foreach ($f in $under) { if ($allSel) { [void]$sel.Remove($f.FullName) } else { [void]$sel.Add($f.FullName) } }
                    }
                    'file' {
                        if ($sel.Contains($e.Path)) { [void]$sel.Remove($e.Path) } else { [void]$sel.Add($e.Path) }
                    }
                    'done' {
                        if ($sel.Count -eq 0) {
                            Write-Host ''
                            Write-Host '   Hiç dosya seçmediniz. En az bir .py dosyası seçmelisiniz.' -ForegroundColor Red
                            Start-Sleep -Seconds 2
                        } else {
                            return @($sel)
                        }
                    }
                }
            }
        }
    }
}

# ---------- Python bul ----------
function Find-PythonInterpreters {
    $cands = New-Object System.Collections.Generic.List[string]
    try {
        $r = Invoke-Native -Exe 'py' -Arguments @('-0p')
        foreach ($l in $r.Output) {
            $ls = $l.ToString().Trim()
            if ($ls -match '(?i)([A-Za-z]:\\[^\r\n]*?pythonw?\.exe)') { $cands.Add($matches[1].Trim()) }
        }
    } catch {}
    try {
        $r = Invoke-Native -Exe 'py' -Arguments @('-3','-c','import sys;print(sys.executable)')
        if ($r.ExitCode -eq 0) {
            foreach ($l in $r.Output) { if ($l -and (Test-Path -LiteralPath $l.Trim())) { $cands.Add($l.Trim()) } }
        }
    } catch {}
    foreach ($exe in @('python','python3','python3.exe','pythonw','pythonw3')) {
        try {
            $r = Invoke-Native -Exe 'where.exe' -Arguments @($exe)
            foreach ($l in $r.Output) { if ($l -and (Test-Path -LiteralPath $l.Trim())) { $cands.Add($l.Trim()) } }
        } catch {}
    }
    foreach ($hive in @('HKLM:\SOFTWARE\Python\PythonCore',
                        'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore',
                        'HKCU:\SOFTWARE\Python\PythonCore')) {
        if (Test-Path $hive) {
            foreach ($k in (Get-ChildItem $hive -ErrorAction SilentlyContinue)) {
                if ($k.PSChildName -notmatch '^3\.') { continue }
                $ip = (Get-ItemProperty -Path ($k.PSPath + '\InstallPath') -ErrorAction SilentlyContinue).'(default)'
                if ($ip) {
                    $pexe = Join-Path $ip 'python.exe'
                    if (Test-Path -LiteralPath $pexe) { $cands.Add($pexe) }
                }
            }
        }
    }
    $globs = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3*\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python31*\python.exe'),
        'C:\Python3*\python.exe',
        'C:\Python31*\python.exe',
        (Join-Path $env:ProgramFiles 'Python3*\python.exe'),
        (Join-Path $env:ProgramFiles 'Python31*\python.exe'),
        (Join-Path $env:ProgramFiles 'Python312\python.exe'),
        (Join-Path $env:ProgramFiles 'Python313\python.exe'),
        'C:\ProgramData\Anaconda3\python.exe',
        'C:\ProgramData\Miniconda3\python.exe',
        (Join-Path $env:USERPROFILE 'anaconda3\python.exe'),
        (Join-Path $env:USERPROFILE 'miniconda3\python.exe'),
        (Join-Path $env:USERPROFILE 'scoop\apps\python\current\python.exe'),
        (Join-Path $env:USERPROFILE 'scoop\apps\python310\current\python.exe'),
        (Join-Path $env:USERPROFILE 'scoop\apps\python311\current\python.exe'),
        (Join-Path $env:USERPROFILE 'scoop\apps\python312\current\python.exe'),
        (Join-Path $env:USERPROFILE 'scoop\apps\python313\current\python.exe'),
        'C:\ProgramData\chocolatey\lib\python3\tools\python.exe',
        'C:\msys64\mingw64\bin\python.exe',
        'C:\msys64\ucrt64\bin\python.exe'
    )
    if (${env:ProgramFiles(x86)}) { $globs += (Join-Path ${env:ProgramFiles(x86)} 'Python3*\python.exe') }
    foreach ($g in $globs) {
        foreach ($p in (Get-ChildItem -Path $g -ErrorAction SilentlyContinue)) { $cands.Add($p.FullName) }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $result = @()
    foreach ($c in $cands) {
        if (-not $c) { continue }
        if ($c -match 'WindowsApps') { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $full = (Resolve-Path -LiteralPath $c).Path
        if (-not $seen.Add($full)) { continue }
        try {
            $r = Invoke-Native -Exe $full -Arguments @('-c', "import sys,struct;print(sys.version.split()[0]);print(struct.calcsize('P')*8)")
            if ($r.ExitCode -eq 0 -and $r.Output.Count -ge 2) {
                $ver = $r.Output[0].ToString().Trim()
                if ($ver -notmatch '^3\.') { continue }
                $result += [pscustomobject]@{ Path = $full; Version = $ver; Bits = [int]$r.Output[1].ToString().Trim() }
            }
        } catch {}
    }
    return ($result | Sort-Object -Property @{Expression='Bits';Descending=$true}, @{Expression='Version';Descending=$true})
}

# ============================================================
#  PAKET HARITALARI (v8.8)
# ============================================================
$script:ALIAS          = @{}
$script:COLLECT_ALL    = @{}
$script:COLLECT_SUBMOD = @{}
$script:COLLECT_DATA   = @{}
$script:HIDDEN_MAP     = @{}
$script:COPY_META      = @{}

function Import-Map {
    param([string]$Text, [hashtable]$Target, [switch]$List)
    foreach ($line in ($Text -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 0) { $Target[$line] = if ($List) { @() } else { '' }; continue }
        $k = $line.Substring(0, $idx).Trim()
        $v = $line.Substring($idx + 1)
        if ($List) {
            $arr = @()
            foreach ($x in ($v -split ';')) { if ($x.Trim()) { $arr += $x.Trim() } }
            $Target[$k] = $arr
        } else {
            $Target[$k] = $v
        }
    }
}

Import-Map -Target $script:ALIAS -Text @'
google=
azure=
cv2=opencv-python
cv=opencv-python
PIL=Pillow
skimage=scikit-image
mpl_toolkits=matplotlib
matplotlib=matplotlib
imageio=imageio
imageio_ffmpeg=imageio-ffmpeg
moviepy=moviepy
skvideo=scikit-video
pydub=pydub
ffmpeg=ffmpeg-python
tifffile=tifffile
rawpy=rawpy
exifread=ExifRead
piexif=piexif
sklearn=scikit-learn
numpy=numpy
scipy=scipy
pandas=pandas
polars=polars
statsmodels=statsmodels
sympy=sympy
numba=numba
cython=Cython
pyarrow=pyarrow
fastparquet=fastparquet
h5py=h5py
tables=tables
zarr=zarr
dask=dask
ray=ray
modin=modin
vaex=vaex
duckdb=duckdb
xgboost=xgboost
lightgbm=lightgbm
catboost=catboost
prophet=prophet
pymc=pymc
arviz=arviz
theano=Theano
networkx=networkx
igraph=python-igraph
pygraphviz=pygraphviz
pydot=pydot
torch=torch
torchvision=torchvision
torchaudio=torchaudio
tensorflow=tensorflow
tensorflow_hub=tensorflow-hub
keras=keras
jax=jax
flax=flax
transformers=transformers
datasets=datasets
tokenizers=tokenizers
sentence_transformers=sentence-transformers
accelerate=accelerate
peft=peft
trl=trl
diffusers=diffusers
onnx=onnx
onnxruntime=onnxruntime
openvino=openvino
tflite_runtime=tflite-runtime
ultralytics=ultralytics
yolo=yolo
detectron2=detectron2
mmcv=mmcv
mmdet=mmdet
paddle=paddlepaddle
paddleocr=paddleocr
mediapipe=mediapipe
easyocr=easyocr
pytesseract=pytesseract
face_recognition=face-recognition
dlib=dlib
deepface=deepface
bs4=beautifulsoup4
ruamel=ruamel.yaml
dotenv=python-dotenv
jwt=PyJWT
flask=Flask
flask_cors=Flask-Cors
flask_sqlalchemy=Flask-SQLAlchemy
flask_login=Flask-Login
flask_migrate=Flask-Migrate
flask_wtf=Flask-WTF
flask_restful=Flask-RESTful
rest_framework=djangorestframework
django=Django
fastapi=fastapi
starlette=starlette
uvicorn=uvicorn
gunicorn=gunicorn
hypercorn=hypercorn
aiohttp=aiohttp
httpx=httpx
requests=requests
urllib3=urllib3
websockets=websockets
socketio=python-socketio
engineio=python-engineio
bottle=bottle
tornado=tornado
sanic=sanic
falcon=falcon
pyramid=pyramid
cherrypy=CherryPy
scrapy=Scrapy
selenium=selenium
playwright=playwright
mechanicalsoup=MechanicalSoup
lxml=lxml
html5lib=html5lib
cssselect=cssselect
xmltodict=xmltodict
sqlalchemy=SQLAlchemy
sqlmodel=sqlmodel
alembic=alembic
pymongo=pymongo
redis=redis
psycopg2=psycopg2-binary
psycopg=psycopg
MySQLdb=mysqlclient
pymysql=PyMySQL
peewee=peewee
tortoise=tortoise-orm
motor=motor
asyncpg=asyncpg
aiomysql=aiomysql
pymemcache=pymemcache
Crypto=pycryptodome
Cryptodome=pycryptodome
OpenSSL=pyOpenSSL
nacl=PyNaCl
bcrypt=bcrypt
passlib=passlib
argon2=argon2-cffi
cryptography=cryptography
jose=python-jose
dns=dnspython
paramiko=paramiko
fabric=Fabric
oauthlib=oauthlib
requests_oauthlib=requests-oauthlib
authlib=Authlib
zmq=pyzmq
pika=pika
kafka=kafka-python
confluent_kafka=confluent-kafka
amqp=amqp
celery=celery
rq=rq
dramatiq=dramatiq
grpc=grpcio
thrift=thrift
zeroconf=zeroconf
netifaces=netifaces
scapy=scapy
boto3=boto3
botocore=botocore
s3fs=s3fs
gcsfs=gcsfs
firebase_admin=firebase-admin
supabase=supabase
google.protobuf=protobuf
google.generativeai=google-generativeai
google.cloud=google-cloud-storage
google.cloud.storage=google-cloud-storage
google.auth=google-auth
google.oauth2=google-auth
googleapiclient=google-api-python-client
google.api_core=google-api-core
google.cloud.bigquery=google-cloud-bigquery
google.cloud.firestore=google-cloud-firestore
google.cloud.pubsub=google-cloud-pubsub
google.cloud.translate=google-cloud-translate
google.cloud.vision=google-cloud-vision
google.cloud.speech=google-cloud-speech
google.cloud.texttospeech=google-cloud-texttospeech
azure.storage=azure-storage-blob
azure.storage.blob=azure-storage-blob
azure.storage.queue=azure-storage-queue
azure.identity=azure-identity
azure.cosmos=azure-cosmos
azure.keyvault=azure-keyvault-secrets
azure.keyvault.secrets=azure-keyvault-secrets
azure.keyvault.keys=azure-keyvault-keys
azure.core=azure-core
azure.servicebus=azure-servicebus
serial=pyserial
usb=pyusb
smbus=smbus2
smbus2=smbus2
spidev=spidev
RPi=RPi.GPIO
gpiozero=gpiozero
pylibftdi=pylibftdi
hid=hidapi
bluetooth=pybluez
bleak=bleak
win32com=pywin32
win32api=pywin32
win32gui=pywin32
win32con=pywin32
win32event=pywin32
win32file=pywin32
win32pipe=pywin32
win32security=pywin32
win32service=pywin32
win32serviceutil=pywin32
win32process=pywin32
win32clipboard=pywin32
win32print=pywin32
win32ui=pywin32
win32com.client=pywin32
win32com.server=pywin32
pythoncom=pywin32
pywintypes=pywin32
wmi=WMI
comtypes=comtypes
clr=pythonnet
clr_loader=clr-loader
psutil=psutil
GPUtil=gputil
cpuinfo=py-cpuinfo
screeninfo=screeninfo
pygetwindow=PyGetWindow
pywinauto=pywinauto
pynput=pynput
keyboard=keyboard
mouse=mouse
pyautogui=PyAutoGUI
pyperclip=pyperclip
mss=mss
plyer=plyer
pywinpty=pywinpty
fitz=PyMuPDF
pymupdf=PyMuPDF
docx=python-docx
pptx=python-pptx
openpyxl=openpyxl
xlrd=xlrd
xlwt=xlwt
xlsxwriter=XlsxWriter
xlwings=xlwings
odf=odfpy
pdfplumber=pdfplumber
PyPDF2=PyPDF2
pypdf=pypdf
pdf2image=pdf2image
pdfminer=pdfminer.six
pikepdf=pikepdf
reportlab=reportlab
weasyprint=weasyprint
fpdf=fpdf2
ebooklib=EbookLib
mammoth=mammoth
striprtf=striprtf
docx2pdf=docx2pdf
markdown=Markdown
nltk=nltk
spacy=spacy
gensim=gensim
jieba=jieba
snowballstemmer=snowballstemmer
textblob=textblob
vaderSentiment=vaderSentiment
Levenshtein=python-Levenshtein
rapidfuzz=rapidfuzz
fuzzywuzzy=fuzzywuzzy
diff_match_patch=diff-match-patch
unicodedata2=unicodedata2
regex=regex
openai=openai
anthropic=anthropic
langchain=langchain
langchain_core=langchain-core
langchain_community=langchain-community
llama_index=llama-index
chromadb=chromadb
pinecone=pinecone-client
weaviate=weaviate-client
qdrant_client=qdrant-client
faiss=faiss-cpu
sentencepiece=sentencepiece
tiktoken=tiktoken
cohere=cohere
mistralai=mistralai
ollama=ollama
speech_recognition=SpeechRecognition
pyaudio=PyAudio
pyttsx3=pyttsx3
whisper=openai-whisper
faster_whisper=faster-whisper
TTS=TTS
soundfile=soundfile
sounddevice=sounddevice
librosa=librosa
audioread=audioread
mutagen=mutagen
eyed3=eyeD3
midiutil=MIDIUtil
mido=mido
tkinter=
turtle=
customtkinter=customtkinter
ttkbootstrap=ttkbootstrap
ttkthemes=ttkthemes
PySimpleGUI=PySimpleGUI
dearpygui=dearpygui
flet=flet
eel=eel
guizero=guizero
pyglet=pyglet
arcade=arcade
pygame=pygame
pygame_gui=pygame_gui
pymunk=pymunk
PySide2=PySide2
PySide6=PySide6
PyQt5=PyQt5
PyQt6=PyQt6
qtpy=QtPy
wx=wxPython
kivy=Kivy
kivymd=kivymd
pywebview=pywebview
pyqtgraph=pyqtgraph
qdarkstyle=QDarkStyle
vispy=vispy
moderngl=moderngl
panda3d=panda3d
ursina=ursina
OpenGL=PyOpenGL
glfw=glfw
sdl2=pysdl2
qrcode=qrcode
barcode=python-barcode
pyzbar=pyzbar
cairosvg=CairoSVG
svglib=svglib
cairocffi=cairocffi
wand=Wand
jinja2=Jinja2
mako=Mako
markupsafe=MarkupSafe
werkzeug=Werkzeug
itsdangerous=itsdangerous
click=click
typer=typer
colorama=colorama
rich=rich
tabulate=tabulate
prettytable=prettytable
termcolor=termcolor
tqdm=tqdm
halo=halo
loguru=loguru
structlog=structlog
toml=toml
tomli=tomli
tomlkit=tomlkit
configobj=configobj
yaml=PyYAML
json5=json5
jsonschema=jsonschema
pydantic=pydantic
attrs=attrs
attr=attrs
cattrs=cattrs
marshmallow=marshmallow
dateutil=python-dateutil
pytz=pytz
arrow=arrow
pendulum=pendulum
tzlocal=tzlocal
schedule=schedule
apscheduler=APScheduler
dateparser=dateparser
holidays=holidays
pytest=pytest
hypothesis=hypothesis
coverage=coverage
mock=mock
freezegun=freezegun
prompt_toolkit=prompt-toolkit
questionary=questionary
inquirer=inquirer
astropy=astropy
sunpy=sunpy
skyfield=skyfield
ephem=ephem
Bio=biopython
rdkit=rdkit
ase=ase
MDAnalysis=MDAnalysis
openmm=openmm
mdtraj=mdtraj
nibabel=nibabel
mne=mne
nilearn=nilearn
pydicom=pydicom
SimpleITK=SimpleITK
itk=itk
vtk=vtk
yfinance=yfinance
pandas_datareader=pandas-datareader
ta=ta
ccxt=ccxt
backtrader=backtrader
zipline=zipline
quantlib=QuantLib
finnhub=finnhub-python
alpaca=alpaca-py
binance=python-binance
web3=web3
eth_account=eth-account
solana=solana
bitcoin=bitcoin
phonenumbers=phonenumbers
pycountry=pycountry
babel=Babel
email_validator=email-validator
validators=validators
cerberus=Cerberus
faker=Faker
factory=factory-boy
wtforms=WTForms
bleach=bleach
markdown2=markdown2
mistune=mistune
commonmark=commonmark
docutils=docutils
pygments=Pygments
pystache=Pystache
chevron=chevron
pkg_resources=setuptools
importlib_metadata=importlib-metadata
importlib_resources=importlib-resources
setuptools=setuptools
wheel=wheel
pip=pip
packaging=packaging
typing_extensions=typing-extensions
six=six
future=future
mlflow=mlflow
wandb=wandb
tensorboard=tensorboard
optuna=optuna
hyperopt=hyperopt
skopt=scikit-optimize
gpytorch=gpytorch
botorch=botorch
gym=gym
gymnasium=gymnasium
stable_baselines3=stable-baselines3
pypdfium2=pypdfium2
Xlib=python-xlib
telebot=pyTelegramBotAPI
telegram=python-telegram-bot
discord=discord.py
slack_sdk=slack-sdk
twilio=twilio
stripe=stripe
sendgrid=sendgrid
yagmail=yagmail
pytrends=pytrends
wikipedia=wikipedia
googletrans=googletrans
deep_translator=deep-translator
translators=translators
'@

Import-Map -Target $script:COLLECT_ALL -Text @'
streamlit=streamlit
plotly=plotly
dash=dash
gradio=gradio
nicegui=nicegui
panel=panel
bokeh=bokeh
voila=voila
jupyter=jupyter
notebook=notebook
nbconvert=nbconvert
papermill=papermill
shiny=shiny
kivy=kivy
kivymd=kivymd
PyQt5=PyQt5
PyQt6=PyQt6
PySide2=PySide2
PySide6=PySide6
PySimpleGUI=PySimpleGUI
dearpygui=dearpygui
flet=flet
eel=eel
guizero=guizero
customtkinter=customtkinter
ttkbootstrap=ttkbootstrap
ttkthemes=ttkthemes
pyglet=pyglet
arcade=arcade
panda3d=panda3d
ursina=ursina
moderngl=moderngl
vispy=vispy
qtpy=qtpy
pyqtgraph=pyqtgraph
qdarkstyle=QDarkStyle
wx=wx
cefpython3=cefpython3
pywebview=webview
scikit-learn=sklearn
scikit-image=skimage
scikit-optimize=skopt
spacy=spacy
nltk=nltk
gensim=gensim
transformers=transformers
datasets=datasets
sentence-transformers=sentence_transformers
sentencepiece=sentencepiece
tokenizers=tokenizers
statsmodels=statsmodels
sympy=sympy
networkx=networkx
numba=numba
pymc=pymc
arviz=arviz
prophet=prophet
torch=torch
torchvision=torchvision
torchaudio=torchaudio
tensorflow=tensorflow
keras=keras
tensorflow-hub=tensorflow_hub
jax=jax
flax=flax
diffusers=diffusers
accelerate=accelerate
peft=peft
trl=trl
openai-whisper=whisper
faster-whisper=faster_whisper
mediapipe=mediapipe
easyocr=easyocr
paddleocr=paddleocr
paddlepaddle=paddle
onnxruntime=onnxruntime
openvino=openvino
ultralytics=ultralytics
detectron2=detectron2
mmcv=mmcv
mmdet=mmdet
fastai=fastai
xgboost=xgboost
lightgbm=lightgbm
catboost=catboost
fastapi=fastapi
uvicorn=uvicorn
gunicorn=gunicorn
starlette=starlette
flask=flask
django=django
tornado=tornado
sanic=sanic
aiohttp=aiohttp
scrapy=scrapy
selenium=selenium
playwright=playwright
httpx=httpx
requests=requests
langchain=langchain
langchain-core=langchain_core
langchain-community=langchain_community
llama-index=llama_index
openai=openai
anthropic=anthropic
tiktoken=tiktoken
chromadb=chromadb
pinecone-client=pinecone
weaviate-client=weaviate
qdrant-client=qdrant_client
faiss-cpu=faiss
cohere=cohere
mistralai=mistralai
google-generativeai=google.generativeai
ollama=ollama
TTS=TTS
librosa=librosa
soundfile=soundfile
pydub=pydub
pyttsx3=pyttsx3
opencv-python=cv2
opencv-contrib-python=cv2
opencv-python-headless=cv2
Pillow=PIL
imageio=imageio
imageio-ffmpeg=imageio_ffmpeg
moviepy=moviepy
tifffile=tifffile
mlflow=mlflow
wandb=wandb
tensorboard=tensorboard
optuna=optuna
pandas=pandas
numpy=numpy
scipy=scipy
pyarrow=pyarrow
polars=polars
duckdb=duckdb
h5py=h5py
tables=tables
zarr=zarr
dask=dask
ray=ray
pytesseract=pytesseract
pyzbar=pyzbar
pdfplumber=pdfplumber
pymupdf=fitz
pypdf=pypdf
PyPDF2=PyPDF2
python-docx=docx
python-pptx=pptx
openpyxl=openpyxl
reportlab=reportlab
weasyprint=weasyprint
docx2pdf=docx2pdf
pydantic=pydantic
PyOpenGL=OpenGL
glfw=glfw
pythonnet=clr
pywin32=win32com
comtypes=comtypes
pygame=pygame
pygame_gui=pygame_gui
pymunk=pymunk
rich=rich
textual=textual
prompt-toolkit=prompt_toolkit
boto3=boto3
botocore=botocore
celery=celery
apscheduler=apscheduler
sqlalchemy=sqlalchemy
alembic=alembic
'@

Import-Map -Target $script:COLLECT_SUBMOD -Text @'
flask=flask
werkzeug=werkzeug
sqlalchemy=sqlalchemy
alembic=alembic
celery=celery
pydantic=pydantic
jsonschema=jsonschema
pythonnet=clr_loader
grpc=grpc
h5py=h5py
keras=keras
tensorflow=tensorflow
torch=torch
sklearn=sklearn
pandas=pandas
numpy=numpy
scipy=scipy
PIL=PIL
asyncio=asyncio
pkg_resources=pkg_resources
setuptools=setuptools
'@

Import-Map -Target $script:COLLECT_DATA -Text @'
certifi=certifi
matplotlib=matplotlib
nltk=nltk
spacy=spacy
textblob=textblob
babel=babel
pytz=pytz
dateutil=dateutil
tzdata=tzdata
lightgbm=lightgbm
xgboost=xgboost
catboost=catboost
mediapipe=mediapipe
easyocr=easyocr
paddleocr=paddleocr
pycountry=pycountry
phonenumbers=phonenumbers
folium=folium
geopandas=geopandas
streamlit=streamlit
gradio=gradio
plotly=plotly
bokeh=bokeh
panel=panel
pygments=pygments
rich=rich
textual=textual
reportlab=reportlab
fpdf=fpdf
fitz=fitz
PyPDF2=PyPDF2
pypdf=pypdf
pikepdf=pikepdf
chardet=chardet
charset_normalizer=charset_normalizer
idna=idna
requests=requests
urllib3=urllib3
yaml=yaml
sqlalchemy=sqlalchemy
django=django
flask=flask
werkzeug=werkzeug
jinja2=jinja2
markupsafe=markupsafe
click=click
PIL=PIL
cv2=cv2
imageio=imageio
imageio_ffmpeg=imageio_ffmpeg
moviepy=moviepy
soundfile=soundfile
librosa=librosa
pydub=pydub
pygame=pygame
wx=wx
kivy=kivy
panda3d=panda3d
torch=torch
torchvision=torchvision
openvino=openvino
paddle=paddle
tensorflow=tensorflow
keras=keras
onnxruntime=onnxruntime
transformers=transformers
'@

Import-Map -Target $script:HIDDEN_MAP -List -Text @'
sqlalchemy=sqlalchemy.sql.default_comparator;sqlalchemy.dialects.sqlite;sqlalchemy.dialects.sqlite.pysqlite;sqlalchemy.dialects.postgresql;sqlalchemy.dialects.postgresql.psycopg2;sqlalchemy.dialects.mysql;sqlalchemy.dialects.mysql.pymysql;sqlalchemy.dialects.mysql.mysqldb;sqlalchemy.dialects.oracle;sqlalchemy.dialects.mssql;sqlalchemy.dialects.mssql.pyodbc;sqlalchemy.dialects.mssql.pymssql
pywin32=win32timezone;win32com;win32com.client;win32com.client.gencache;win32com.client.dynamic;win32com.shell;win32com.shell.shell;win32com.shell.shellcon;pythoncom;pywintypes;win32api;win32con;win32event;win32file;win32gui;win32process;win32security
pydantic=pydantic.deprecated.decorator;pydantic_core;pydantic_core._pydantic_core;annotated_types
pandas=pandas._libs.tslibs.base;pandas._libs.tslibs.np_datetime;pandas._libs.tslibs.nattype;pandas._libs.tslibs.timedeltas;pandas._libs.tslibs.timestamps;pandas._libs.tslibs.timezones;pandas._libs.tslibs.ccalendar;pandas._libs.tslibs.parsing;pandas._libs.tslibs.conversion;pandas._libs.tslibs.period;pandas._libs.tslibs.offsets;pandas._libs.tslibs.strptime;pandas._libs.tslibs.frequencies
matplotlib=matplotlib.backends.backend_tkagg;matplotlib.backends.backend_qt5agg;matplotlib.backends.backend_qt5;matplotlib.backends.backend_qt6agg;matplotlib.backends.backend_wx;matplotlib.backends.backend_wxagg;matplotlib.backends._backend_tk;matplotlib.backends.backend_pdf;matplotlib.backends.backend_svg;matplotlib.backends.backend_ps;matplotlib.backends.backend_pgf;matplotlib.backends.backend_cairo;matplotlib.backends.backend_webagg;matplotlib.backends.backend_webagg_core
numpy=numpy.core._multiarray_umath;numpy.core._multiarray_tests;numpy.random._pickle;numpy.random.bit_generator;numpy.testing._private.utils
scipy=scipy._lib.array_api_compat.numpy.fft;scipy._lib.array_api_compat.numpy.linalg;scipy.special._cdflib
sklearn=sklearn.utils._typedefs;sklearn.utils._heap;sklearn.utils._sorting;sklearn.utils._vector_sentinel;sklearn.neighbors._partition_nodes
PIL=PIL._tkinter_finder;PIL.ImageQt;PIL.ImageTk;PIL.BmpImagePlugin;PIL.GifImagePlugin;PIL.JpegImagePlugin;PIL.PngImagePlugin;PIL.TiffImagePlugin;PIL.WebPImagePlugin
reportlab=reportlab.graphics.barcode;reportlab.graphics.barcode.qr;reportlab.graphics.barcode.eanbc;reportlab.graphics.barcode.code128;reportlab.graphics.barcode.code39
django=django.db.backends.sqlite3;django.db.backends.postgresql;django.db.backends.mysql;django.db.backends.oracle;django.contrib.admin;django.contrib.auth;django.contrib.contenttypes;django.contrib.sessions;django.contrib.messages;django.contrib.staticfiles
flask=flask.json;flask.json.tag
requests=requests.packages.urllib3;requests.packages.chardet;requests.packages.idna
cryptography=cryptography.hazmat.backends.openssl;cryptography.hazmat.bindings._openssl
grpc=grpc._cython.cygrpc
boto3=boto3.session;botocore.session;botocore.loaders;botocore.response;botocore.stub
jsonschema=jsonschema._format
lxml=lxml.etree;lxml.objectify;lxml.html;lxml.html.clean;lxml.isoschematron;lxml.cssselect;lxml._elementpath
selenium=selenium.webdriver.chrome.service;selenium.webdriver.firefox.service;selenium.webdriver.edge.service;selenium.webdriver.safari.service;selenium.webdriver.common.keys
playwright=playwright._impl._driver;playwright.sync_api
scrapy=scrapy.crawler;scrapy.spiders;scrapy.utils.response
jinja2=jinja2.ext;jinja2.sandbox;jinja2.async_utils
openpyxl=openpyxl.cell._writer;openpyxl.reader.excel;openpyxl.writer.excel
xlrd=xlrd.xlsx;xlrd.xls;xlrd.formatting;xlrd.compdoc
pyarrow=pyarrow._pyarrow_cpp_tests;pyarrow.orc;pyarrow.parquet;pyarrow.dataset;pyarrow.flight;pyarrow.fs;pyarrow.csv
polars=polars.polars
pymongo=pymongo.auth;pymongo.srv_resolver;pymongo.encryption_options;pymongo.monitoring
redis=redis.connection;redis.client;redis.cluster;redis.asyncio;redis.commands
tornado=tornado.platform.asyncio;tornado.platform.twisted;tornado.ioloop;tornado.httpserver;tornado.websocket
aiohttp=aiohttp._websocket;aiohttp._http_parser;aiohttp._http_writer
fastapi=fastapi.responses;fastapi.routing;fastapi.staticfiles;fastapi.templating;fastapi.websockets;fastapi.middleware.cors;fastapi.middleware.httpsredirect;fastapi.middleware.trustedhost
uvicorn=uvicorn.logging;uvicorn.loops;uvicorn.loops.auto;uvicorn.loops.asyncio;uvicorn.protocols;uvicorn.protocols.http;uvicorn.protocols.http.auto;uvicorn.protocols.http.h11_impl;uvicorn.protocols.http.httptools_impl;uvicorn.protocols.websockets;uvicorn.protocols.websockets.auto;uvicorn.protocols.websockets.wsproto_impl;uvicorn.lifespan;uvicorn.lifespan.on;uvicorn.lifespan.off
transformers=transformers.models.auto;transformers.models.auto.modeling_auto;transformers.models.auto.tokenization_auto;transformers.models.auto.configuration_auto;transformers.models.auto.image_processing_auto;transformers.models.auto.feature_extraction_auto;transformers.models.auto.processing_auto
pyzbar=pyzbar.pyzbar;pyzbar.wrapper;pyzbar.pyzbar_error
cv2=cv2.data;cv2.gapi;cv2.ml;cv2.dnn;cv2.ximgproc
pytesseract=pytesseract.pytesseract
multiprocessing=multiprocessing.popen_spawn_win32;multiprocessing.pool;multiprocessing.managers;multiprocessing.sharedctypes;multiprocessing.resource_tracker
concurrent.futures=concurrent.futures.thread;concurrent.futures.process
asyncio=asyncio.windows_events;asyncio.windows_utils;asyncio.proactor_events
pkg_resources=pkg_resources.py2_warn;pkg_resources.extern
tkinter=tkinter.ttk;tkinter.filedialog;tkinter.messagebox;tkinter.colorchooser;tkinter.font;tkinter.scrolledtext;tkinter.simpledialog;tkinter.constants;tkinter.dnd
sqlite3=sqlite3.dbapi2;_sqlite3
hashlib=_hashlib;_sha256;_sha512;_sha1;_md5;_blake2
ssl=_ssl;ssl
bz2=_bz2
lzma=_lzma
zlib=_zlib;zlib
ctypes=_ctypes;ctypes.util;ctypes.wintypes;ctypes.macholib
decimal=_decimal
struct=_struct
zoneinfo=tzdata
fitz=fitz.fitz;fitz.utils;fitz.table;fitz.new
docx=docx.opc;docx.oxml;docx.parts;docx.enum
pptx=pptx.chart;pptx.dml;pptx.enum;pptx.opc;pptx.parts;pptx.shapes;pptx.text
graphviz=graphviz.backend;graphviz.backend.dot_command;graphviz.sources
zmq=zmq.utils.garbage;zmq.backend.cython;zmq.backend.cffi
serial=serial.tools;serial.tools.list_ports;serial.tools.list_ports_windows
usb=usb.backend;usb.backend.libusb1;usb.backend.libusb0;usb.backend.openusb;usb.backend.libsub
wx=wx.lib;wx.lib.inspection;wx.lib.mixins;wx.adv;wx.html;wx.html2;wx.xml;wx.xrc;wx.grid
pygame=pygame._sdl2;pygame.mixer;pygame.mixer.music;pygame.font;pygame.image;pygame.imageext;pygame.surface;pygame.time;pygame.transform;pygame.draw;pygame.event;pygame.key;pygame.mouse
babel=babel.dates;babel.numbers;babel.messages;babel.localtime
setuptools=setuptools.msvc;setuptools.command.easy_install;setuptools.command.install;setuptools.command.build_py
pytz=pytz.tzfile;pytz.exceptions;pytz.lazy
dateutil=dateutil.tz;dateutil.parser;dateutil.rrule;dateutil.relativedelta;dateutil.easter;dateutil.zoneinfo
certifi=certifi
charset_normalizer=charset_normalizer.md__mypyc
markupsafe=markupsafe._speedups
yaml=yaml._yaml;yaml.cyaml;yaml.resolver;yaml.constructor;yaml.representer
psutil=psutil._psutil_windows;psutil._psutil_linux;psutil._psutil_osx;psutil._psutil_bsd
websockets=websockets.legacy;websockets.legacy.client;websockets.legacy.server;websockets.legacy.protocol;websockets.speedups
httptools=httptools.parser;httptools.parser.parser
watchfiles=watchfiles._rust_notify;watchfiles.main
anyio=anyio._backends._asyncio;anyio._backends._trio
'@

Import-Map -Target $script:COPY_META -List -Text @'
transformers=transformers;tokenizers;huggingface-hub;safetensors;regex;tqdm;numpy;packaging;pyyaml;requests;filelock
huggingface-hub=huggingface-hub
datasets=datasets;pyarrow;pandas;requests;tqdm;numpy
sentence-transformers=sentence-transformers;transformers;torch;scikit-learn;scipy;numpy
accelerate=accelerate;torch;packaging;pyyaml;psutil;numpy
peft=peft;transformers;torch;accelerate;numpy
diffusers=diffusers;transformers;huggingface-hub;numpy;Pillow;safetensors;filelock
openai=openai;httpx;pydantic;typing-extensions;anyio;distro;sniffio;tqdm
anthropic=anthropic;httpx;pydantic;anyio;distro;sniffio;tokenizers
langchain=langchain;langchain-core;langchain-community;pydantic;SQLAlchemy;requests;PyYAML;numpy;aiohttp;tenacity;jsonpatch;packaging
langchain-core=langchain-core;pydantic;tenacity;PyYAML;jsonpatch;packaging;typing-extensions
llama-index=llama-index;llama-index-core;pydantic;requests;tiktoken;SQLAlchemy;numpy;tenacity;PyYAML;dataclasses-json
chromadb=chromadb;pydantic;numpy;onnxruntime;fastapi;uvicorn;requests;PyYAML;posthog
tiktoken=tiktoken;regex;requests
pydantic=pydantic;pydantic-core;annotated-types;typing-extensions
pydantic-settings=pydantic-settings;pydantic;python-dotenv
sqlalchemy=SQLAlchemy;greenlet;typing-extensions
alembic=alembic;SQLAlchemy;Mako;typing-extensions
pandas=pandas;numpy;python-dateutil;pytz;tzdata
numpy=numpy
scipy=scipy;numpy
scikit-learn=scikit-learn;scipy;joblib;threadpoolctl;numpy
matplotlib=matplotlib;numpy;Pillow;pyparsing;cycler;kiwisolver;packaging;python-dateutil;contourpy;fonttools
plotly=plotly;tenacity;packaging
streamlit=streamlit;altair;blinker;cachetools;click;numpy;packaging;pandas;pillow;protobuf;pyarrow;requests;rich;tenacity;toml;typing-extensions;tornado;gitpython;pydeck;watchdog
gradio=gradio;gradio-client;aiofiles;altair;fastapi;ffmpy;httpx;huggingface-hub;jinja2;markupsafe;matplotlib;numpy;orjson;packaging;pandas;pillow;pydantic;pydub;python-multipart;pyyaml;requests;semantic-version;starlette;tomlkit;typer;typing-extensions;uvicorn;websockets
django=Django;asgiref;sqlparse;tzdata
flask=Flask;Werkzeug;Jinja2;itsdangerous;click;blinker;MarkupSafe
fastapi=fastapi;starlette;pydantic;typing-extensions;anyio;idna;sniffio
uvicorn=uvicorn;click;h11;typing-extensions
requests=requests;certifi;charset-normalizer;idna;urllib3
httpx=httpx;certifi;httpcore;idna;sniffio;anyio
aiohttp=aiohttp;aiosignal;async-timeout;attrs;frozenlist;multidict;yarl
openpyxl=openpyxl;et-xmlfile
xlsxwriter=XlsxWriter
docx=python-docx;lxml;typing-extensions
pptx=python-pptx;lxml;Pillow;XlsxWriter;typing-extensions
fitz=PyMuPDF
PyPDF2=PyPDF2;typing-extensions
pypdf=pypdf;typing-extensions
pdfplumber=pdfplumber;pdfminer.six;Pillow;pypdfium2;Wand
pikepdf=pikepdf;Pillow
reportlab=reportlab;pillow;chardet
weasyprint=weasyprint;cffi;tinycss2;cssselect2;Pyphen;Pillow;fonttools;pydyf
PIL=Pillow
opencv-python=opencv-python
opencv-contrib-python=opencv-contrib-python
boto3=boto3;botocore;jmespath;s3transfer;python-dateutil;urllib3;six
azure-storage-blob=azure-storage-blob;azure-core;cryptography;msrest;isodate;typing-extensions
google-cloud-storage=google-cloud-storage;google-auth;google-api-core;google-cloud-core;google-crc32c;google-resumable-media;requests;protobuf
google-generativeai=google-generativeai;google-ai-generativelanguage;google-api-core;google-api-python-client;google-auth;protobuf;pydantic;tqdm;typing-extensions
pymongo=pymongo;dnspython
redis=redis;async-timeout
psycopg2-binary=psycopg2-binary
mysqlclient=mysqlclient
PyMySQL=PyMySQL
celery=celery;billiard;kombu;vine;click;click-didyoumean;click-repl;click-plugins;python-dateutil;tzdata;amqp
ray=ray;click;filelock;jsonschema;msgpack;packaging;protobuf;pyyaml;aiosignal;frozenlist;requests;numpy;grpcio
polars=polars
pyarrow=pyarrow;numpy
duckdb=duckdb
dask=dask;click;cloudpickle;fsspec;packaging;partd;pyyaml;toolz;importlib-metadata
h5py=h5py;numpy
tables=tables;numpy;numexpr;blosc2;py-cpuinfo;packaging;typing-extensions
zarr=zarr;asciitree;fasteners;numcodecs;numpy
xgboost=xgboost;numpy;scipy
lightgbm=lightgbm;numpy;scipy
catboost=catboost;numpy;pandas;scipy;plotly;six
statsmodels=statsmodels;numpy;scipy;pandas;patsy;packaging
sympy=sympy;mpmath
networkx=networkx
numba=numba;llvmlite;numpy
pygame=pygame
pymunk=pymunk;cffi
kivy=Kivy;Kivy-Garden;docutils;pygments;requests;pillow;filetype
wx=wxPython;numpy;pillow;six
PyQt5=PyQt5;PyQt5-Qt5;PyQt5-sip
PyQt6=PyQt6;PyQt6-Qt6;PyQt6-sip
PySide2=PySide2;shiboken2
PySide6=PySide6;PySide6-Essentials;PySide6-Addons;shiboken6
pytesseract=pytesseract;Pillow;packaging
easyocr=easyocr;torch;torchvision;opencv-python-headless;scikit-image;scipy;numpy;Pillow;python-bidi;PyYAML;Shapely;pyclipper;ninja
mediapipe=mediapipe;absl-py;attrs;flatbuffers;matplotlib;numpy;opencv-contrib-python;protobuf;sounddevice
ultralytics=ultralytics;matplotlib;numpy;opencv-python;pillow;pyyaml;requests;scipy;torch;torchvision;tqdm;psutil;py-cpuinfo;thop;pandas
openai-whisper=openai-whisper;numba;numpy;torch;tqdm;more-itertools;tiktoken;ffmpeg-python
TTS=TTS;numpy;torch;torchaudio;scipy;librosa;numba;inflect;soundfile;pysbd;umap-learn
librosa=librosa;audioread;numpy;scipy;scikit-learn;joblib;decorator;numba;soundfile;pooch;soxr;typing-extensions;lazy-loader;msgpack;standard-aifc;standard-sunau
soundfile=soundfile;cffi;numpy
pydub=pydub;audioop-lts
pyttsx3=pyttsx3;comtypes;pypiwin32;pywin32
SpeechRecognition=SpeechRecognition;requests
PyAudio=PyAudio
'@

# ---------- Harita normalizasyonu ----------
function Normalize-PkgName {
    param([string]$Name)
    if (-not $Name) { return '' }
    return ($Name.Trim().ToLower() -replace '[-_.]+','-')
}

function Get-NormalizedMap {
    param([hashtable]$Map)
    $norm = @{}
    foreach ($k in $Map.Keys) {
        $nk = Normalize-PkgName -Name $k
        if (-not $norm.ContainsKey($nk)) { $norm[$nk] = $Map[$k] }
    }
    return $norm
}

$script:ALIAS_NORM          = Get-NormalizedMap -Map $script:ALIAS
$script:COLLECT_ALL_NORM    = Get-NormalizedMap -Map $script:COLLECT_ALL
$script:COLLECT_SUBMOD_NORM = Get-NormalizedMap -Map $script:COLLECT_SUBMOD
$script:COLLECT_DATA_NORM   = Get-NormalizedMap -Map $script:COLLECT_DATA
$script:HIDDEN_IMPORTS_NORM = Get-NormalizedMap -Map $script:HIDDEN_MAP
$script:COPY_METADATA_NORM  = Get-NormalizedMap -Map $script:COPY_META

$STDLIB_FALLBACK = @(
    '__future__','__main__','_ast','_codecs','_collections','_functools','_io','_locale','_operator',
    '_signal','_sre','_stat','_string','_symtable','_thread','_tokenize','_tracemalloc','_warnings',
    '_weakref','_weakrefset','abc','aifc','argparse','array','ast','asynchat','asyncio','asyncore',
    'atexit','audioop','base64','bdb','binascii','binhex','bisect','builtins','bz2','cProfile',
    'calendar','cgi','cgitb','chunk','cmath','cmd','code','codecs','codeop','collections',
    'colorsys','compileall','concurrent','configparser','contextlib','contextvars','copy','copyreg',
    'crypt','csv','ctypes','curses','dataclasses','datetime','dbm','decimal','difflib','dis',
    'distutils','doctest','email','encodings','ensurepip','enum','errno','faulthandler','fcntl',
    'filecmp','fileinput','fnmatch','formatter','fractions','ftplib','functools','gc','getopt',
    'getpass','gettext','glob','graphlib','grp','gzip','hashlib','heapq','hmac','html','http',
    'idlelib','imaplib','imghdr','imp','importlib','inspect','io','ipaddress','itertools','json',
    'keyword','lib2to3','linecache','locale','logging','lzma','mailbox','mailcap','marshal','math',
    'mimetypes','mmap','modulefinder','msilib','msvcrt','multiprocessing','netrc','nis','nntplib',
    'nt','ntpath','nturl2path','numbers','opcode','operator','optparse','os','ossaudiodev','pathlib',
    'pdb','pickle','pickletools','pipes','pkgutil','platform','plistlib','poplib','posix','posixpath',
    'pprint','profile','pstats','pty','pwd','py_compile','pyclbr','pydoc','pydoc_data','queue',
    'quopri','random','re','readline','reprlib','resource','rlcompleter','runpy','sched','secrets',
    'select','selectors','shelve','shlex','shutil','signal','site','smtpd','smtplib','sndhdr',
    'socket','socketserver','spwd','sqlite3','sre_compile','sre_constants','sre_parse','ssl','stat',
    'statistics','string','stringprep','struct','subprocess','sunau','symtable','sys','sysconfig',
    'syslog','tabnanny','tarfile','telnetlib','tempfile','termios','test','textwrap','threading',
    'time','timeit','tkinter','token','tokenize','tomllib','trace','traceback','tracemalloc','tty',
    'turtle','turtledemo','types','typing','unicodedata','unittest','urllib','uu','uuid','venv',
    'warnings','wave','weakref','webbrowser','winreg','winsound','wsgiref','xdrlib','xml','xmlrpc',
    'zipapp','zipfile','zipimport','zlib','zoneinfo'
)

function Get-StdlibNames {
    param([string]$PyExe)
    try {
        $r = Invoke-Native -Exe $PyExe -Arguments @('-c', "import sys;print(chr(10).join(sorted(sys.stdlib_module_names)))")
        if ($r.ExitCode -eq 0) {
            $list = @($r.Output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
            if ($list.Count -gt 30) { return $list }
        }
    } catch {}
    return $STDLIB_FALLBACK
}

function Get-PackageBaseName {
    param([string]$Spec)
    if (-not $Spec) { return $null }
    $s = $Spec.Trim()
    if ($s -match '^([^;]+);') { $s = $matches[1].Trim() }
    if ($s -match '#egg=([A-Za-z0-9_\-\.]+)') { return $matches[1] }
    if ($s -match '^-e\s') { return $null }
    if ($s -match '^-')    { return $null }
    if ($s -match '^(?<n>[A-Za-z0-9_\-\.]+)') { return $matches['n'] }
    return $null
}

function Get-LocalModuleNames {
    param([string]$Root)
    $local = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $local }
    foreach ($f in (Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Extension -eq '.py' -or $f.Extension -eq '.pyw') { [void]$local.Add($f.BaseName) }
    }
    foreach ($d in (Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction SilentlyContinue)) {
        if (-not (Test-Ignored $d.FullName)) { [void]$local.Add($d.Name) }
    }
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Extension -eq '.py' -or $f.Extension -eq '.pyw') {
            if (-not (Test-Ignored $f.FullName)) { [void]$local.Add($f.BaseName) }
        }
    }
    return $local
}

# ============================================================
#  py_module yukleyici
#  Gomulu Python kodlari artik .\py_module klasorunde ayri dosyalar.
#  (PS bolumu Invoke-Expression ile calistigi icin $PSScriptRoot yok;
#   bat dosyasinin yolu cmd tarafindan $env:SELF ile aktarilir.)
# ============================================================
$script:AppDir       = Split-Path -Parent $env:SELF
$script:PyModuleDir  = Join-Path $script:AppDir 'py_module'
$script:PyModuleFiles = @('ast_scanner.py','installer.py','plan_and_compress.py','runtime_hook.py','uninstaller.py')

function Get-PyModulePath {
    param([Parameter(Mandatory=$true)][string]$Name)
    return (Join-Path $script:PyModuleDir $Name)
}

function Get-PyModuleSource {
    param([Parameter(Mandatory=$true)][string]$Name)
    $p = Get-PyModulePath $Name
    if (-not (Test-Path -LiteralPath $p)) {
        throw ('py_module dosyası bulunamadı: ' + $p)
    }
    return [IO.File]::ReadAllText($p, (New-Object Text.UTF8Encoding($false)))
}

$missingPy = @($script:PyModuleFiles | Where-Object { -not (Test-Path -LiteralPath (Get-PyModulePath $_)) })
if ($missingPy.Count -gt 0) {
    throw ('py_module klasöründe eksik dosya(lar) var (' + $script:PyModuleDir + '): ' + ($missingPy -join ', '))
}

function Get-PythonTopImports {
    param([string]$Root, [string]$PyExe, [string[]]$Files)
    $result = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not $Files -or $Files.Count -eq 0) { return $result }
    if ($PyExe -and (Test-Path -LiteralPath $PyExe)) {
        try {
            $tmp = Get-PyModulePath 'ast_scanner.py'
            $args = @('-X','utf8',$tmp) + $Files
            $r = Invoke-Native -Exe $PyExe -Arguments $args
            if ($r.ExitCode -eq 0 -and $r.Output.Count -gt 0) {
                $jsonLine = $null
                foreach ($l in $r.Output) {
                    $ls = $l.ToString().Trim()
                    if ($ls.StartsWith('[') -and $ls.EndsWith(']')) { $jsonLine = $ls; break }
                }
                if ($jsonLine) {
                    try {
                        $arr = $jsonLine | ConvertFrom-Json
                        foreach ($m in $arr) { if ($m) { [void]$result.Add([string]$m) } }
                        if ($result.Count -gt 0) { return $result }
                    } catch {}
                }
            }
        } catch {}
    }
    foreach ($file in $Files) {
        $content = $null
        try { $content = Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction SilentlyContinue } catch { continue }
        if (-not $content) { continue }
        $joined = ($content -join "`n")
        $joined = [regex]::Replace($joined, '\(\s*\r?\n', '(')
        $joined = [regex]::Replace($joined, ',\s*\r?\n', ', ')
        foreach ($line in ($joined -split "`n")) {
            if ($null -eq $line) { continue }
            # Noktali virgulle ayrilmis birden fazla ifade olabilir (import a; import b)
            foreach ($stmt in ($line -split ';')) {
                $stmt = $stmt.Trim()
                if (-not $stmt) { continue }
                if ($stmt -match '^#') { continue }
                if ($stmt -match '^\s*import\s+(.+?)(?:\s*#.*)?$') {
                    foreach ($part in ($matches[1] -split ',')) {
                        $t = ($part.Trim() -split '\s+')[0]
                        if ($t) {
                            [void]$result.Add($t)
                            $top = ($t -split '\.')[0]
                            if ($top -and $top -ne $t) { [void]$result.Add($top) }
                        }
                    }
                }
                elseif ($stmt -match '^\s*from\s+(\.*)([A-Za-z_][\w\.]*)\s+import') {
                    if (-not $matches[1]) {
                        $full = $matches[2]
                        [void]$result.Add($full)
                        $top = ($full -split '\.')[0]
                        if ($top -and $top -ne $full) { [void]$result.Add($top) }
                    }
                }
            }
        }
    }
    return $result
}

function Get-RequiredPackages {
    param([string]$Root, [string]$PyExe, [string[]]$Files = $null)
    $pkgsFromReq = @()
    $reqFile = Join-Path $Root 'requirements.txt'
    if (Test-Path -LiteralPath $reqFile) {
        foreach ($line in (Get-Content -LiteralPath $reqFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($null -eq $line) { continue }
            $l = $line.Trim()
            if (-not $l) { continue }
            if ($l.StartsWith('#')) { continue }
            if ($l -notmatch 'https?://|git\+|file://') { $l = ($l -split '#')[0].Trim() }
            if ($l -and $l -notmatch '^-') { $pkgsFromReq += $l }
        }
    }
    $std = Get-StdlibNames -PyExe $PyExe
    $stdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $std) { [void]$stdSet.Add($s) }
    foreach ($s in @('__future__','__main__','__init__')) { [void]$stdSet.Add($s) }
    $localSet = Get-LocalModuleNames -Root $Root
    if (-not $Files) {
        $Files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Where-Object { (-not (Test-Ignored $_.FullName)) -and ($_.Extension -eq '.py' -or $_.Extension -eq '.pyw') } |
                   ForEach-Object { $_.FullName })
    } else {
        $Files = @($Files | Where-Object { $_ -like '*.py' -or $_ -like '*.pyw' })
    }
    $tops = Get-PythonTopImports -Root $Root -PyExe $PyExe -Files $Files
    $found = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $tops) {
        if (-not $t) { continue }
        if ($t -match '\.') {
            $nt = Normalize-PkgName -Name $t
            if ($script:ALIAS_NORM.ContainsKey($nt)) {
                $name = $script:ALIAS_NORM[$nt]
                if ($name) { [void]$found.Add($name) }
            }
            continue
        }
        if ($stdSet.Contains($t)) { continue }
        if ($localSet.Contains($t)) { continue }
        if ($t -match '^_') { continue }
        if ($t -notmatch '^[A-Za-z_][\w]*$') { continue }
        $nt = Normalize-PkgName -Name $t
        $name = if ($script:ALIAS_NORM.ContainsKey($nt)) { $script:ALIAS_NORM[$nt] } else { $t }
        if ($name) { [void]$found.Add($name) }
    }
    $allNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $finalPackages = New-Object System.Collections.Generic.List[object]
    foreach ($spec in $pkgsFromReq) {
        $bn = Get-PackageBaseName -Spec $spec
        if (-not $bn) { continue }
        $nk = Normalize-PkgName -Name $bn
        if ($allNames.Add($nk)) { $finalPackages.Add([pscustomobject]@{ Name = $bn; Spec = $spec }) }
    }
    foreach ($name in ($found | Sort-Object)) {
        $nk = Normalize-PkgName -Name $name
        if ($allNames.Add($nk)) { $finalPackages.Add([pscustomobject]@{ Name = $name; Spec = $name }) }
    }
    $srcParts = @()
    if ($pkgsFromReq.Count -gt 0) { $srcParts += 'requirements.txt' }
    if ($found.Count -gt 0)       { $srcParts += 'import taramasi' }
    $source = if ($srcParts.Count -gt 0) { $srcParts -join ' + ' } else { 'tarama (harici paket bulunamadı)' }
    $pkgArray = New-Object 'object[]' $finalPackages.Count
    for ($i = 0; $i -lt $finalPackages.Count; $i++) { $pkgArray[$i] = $finalPackages[$i] }
    $resultObj = New-Object PSObject
    $resultObj | Add-Member -MemberType NoteProperty -Name 'Source'   -Value $source
    $resultObj | Add-Member -MemberType NoteProperty -Name 'Packages' -Value $pkgArray
    return $resultObj
}

# ============================================================
#  KURULUM PAKETI (GUI installer + paralel py7zr)
# ============================================================
function Test-Py7zrCompatibility {
    param([string]$PyExe)
    try {
        $r = Invoke-Native -Exe $PyExe -Arguments @('-c', "import sys; print('.'.join(map(str, sys.version_info[:3])))")
        if ($r.ExitCode -eq 0) {
            $verStr = $r.Output[0].ToString().Trim()
            $parts = $verStr -split '\.'
            if ($parts.Count -ge 2) {
                $major = [int]$parts[0]; $minor = [int]$parts[1]
                if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 9)) {
                    return [pscustomobject]@{ Ok = $false; Version = $verStr; Reason = "py7zr 1.0+ en az Python 3.9 gerektirir. Sizin sürümünüz: $verStr" }
                }
            }
        }
    } catch {}
    return [pscustomobject]@{ Ok = $true; Version = ''; Reason = '' }
}

function New-Py7zrSetupPackage {
    param(
        [string]$OutRoot,
        [string]$ProjectName,
        [string]$ExeName,
        [string]$WorkDir,
        [string]$PythonExe,
        [string]$IconPath = $null
    )

    $setupDir = Join-Path $WorkDir 'setup_py7zr'
    if (Test-Path -LiteralPath $setupDir) { Remove-Item -LiteralPath $setupDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $setupDir | Out-Null

    # --- GUI installer.py ---
    $installerPy = Join-Path $setupDir 'installer.py'
    $pyProjectName = ConvertTo-PyLiteral $ProjectName
    $pyExeName     = ConvertTo-PyLiteral $ExeName

    $installerCode = Get-PyModuleSource 'installer.py'

    $installerCode = $installerCode.Replace('__PROJECT_NAME__', $pyProjectName)
    $installerCode = $installerCode.Replace('__EXE_NAME__', $pyExeName)
    [IO.File]::WriteAllText($installerPy, $installerCode, (New-Object Text.UTF8Encoding($true)))

    # --- Paralel planlama + sikistirma ---
    $cpuCount = 0
    try { $cpuCount = [int]$env:NUMBER_OF_PROCESSORS } catch {}
    if ($cpuCount -lt 1) { $cpuCount = 2 }
    $workers   = [Math]::Max(1, [int][Math]::Floor($cpuCount / 2))
    $chunkSize = 250 * 1024 * 1024

    Write-Host ('   Paralel sıkıştırma: ' + $workers + ' worker (' + $cpuCount + ' çekirdeğin yarısı), 250 MB chunk') -ForegroundColor DarkGray

    $plannerPy = Join-Path $setupDir '_plan_and_compress.py'
    $plannerCode = Get-PyModuleSource 'plan_and_compress.py'
    [IO.File]::WriteAllText($plannerPy, $plannerCode, (New-Object Text.UTF8Encoding($false)))

    $setupExeName = ($ProjectName + '_Kurulum.exe')
    $compressionOk = $false
    $compressionErr = $null
    try {
        $r = Invoke-NativeLive -Exe $PythonExe -Label 'Arşivler sıkıştırılıyor...' -Arguments @(
            '-X','utf8', $plannerPy, $OutRoot, $setupDir, $chunkSize, $workers, $MARKER, $setupExeName
        )
        if ($r.ExitCode -ne 0) {
            if ($r.ExitCode -eq 4) {
                throw 'Bazı chunk''lar 5 denemede de oluşturulamadı.'
            } else {
                throw ('Paralel sıkıştırma başarısız oldu (çıkış kodu: ' + $r.ExitCode + ').')
            }
        }
        $compressionOk = $true
    } catch {
        $compressionErr = $_
    } finally {
        # HER DURUMDA OutRoot'u geri birlestir
        try {
            $manifestPathF = Join-Path $setupDir 'manifest.json'
            if (Test-Path -LiteralPath $manifestPathF) {
                $m = Get-Content -LiteralPath $manifestPathF -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($m.joins -and $m.joins.Count -gt 0) {
                    Write-Host '   Büyük dosyalar geri birleştiriliyor (OutRoot bütünlüğü)...' -ForegroundColor DarkGray
                    foreach ($j in $m.joins) {
                        $targetFull = Join-Path $OutRoot ($j.target -replace '/', '\')
                        $targetDir  = Split-Path $targetFull -Parent
                        if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
                            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
                        }
                        if (Test-Path -LiteralPath $targetFull) {
                            Remove-Item -LiteralPath $targetFull -Force -ErrorAction SilentlyContinue
                        }
                        $outFs = [IO.File]::Open($targetFull, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                        try {
                            foreach ($partRel in $j.parts) {
                                $partFull = Join-Path $OutRoot ($partRel -replace '/', '\')
                                if (-not (Test-Path -LiteralPath $partFull)) { continue }
                                $inFs = [IO.File]::OpenRead($partFull)
                                try { $inFs.CopyTo($outFs, 4 * 1024 * 1024) } finally { $inFs.Dispose() }
                            }
                        } finally { $outFs.Dispose() }
                    }
                    $partsDir = Join-Path $OutRoot '__parts__'
                    if (Test-Path -LiteralPath $partsDir) {
                        Remove-Item -LiteralPath $partsDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Write-Host '   Geri birleştirme tamamlandı.' -ForegroundColor Green
                }
            }
        } catch {
            Write-Host ('   UYARI: OutRoot geri birleştirme başarısız: ' + $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }
    if (-not $compressionOk) { throw $compressionErr }

    $manifestPath = Join-Path $setupDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-Host '   Sıkıştırıcının son çıktısı:' -ForegroundColor Yellow
        foreach ($l in @($r.Output | Select-Object -Last 25)) { Write-Host ('     ' + $l) -ForegroundColor DarkYellow }
        throw ('manifest.json oluşturulamadı. Sıkıştırıcı çıkış kodu: ' + $r.ExitCode)
    }
    $payloadFiles = @(Get-ChildItem -LiteralPath $setupDir -Filter 'payload_*.7z' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($payloadFiles.Count -eq 0) { throw 'Hiç payload arşivi oluşturulmadı.' }
    $totalPayloadSize = ($payloadFiles | Measure-Object -Property Length -Sum).Sum
    Write-Host ('   Toplam arşiv: ' + [Math]::Round($totalPayloadSize / 1MB, 2) + ' MB, ' + $payloadFiles.Count + ' parca') -ForegroundColor Green

    Write-Host '   Kurulum exe derleniyor (PyInstaller)...' -ForegroundColor DarkGray
    $setupExe = Join-Path $OutRoot ($ProjectName + '_Kurulum.exe')
    if (Test-Path -LiteralPath $setupExe) { Remove-Item -LiteralPath $setupExe -Force -ErrorAction SilentlyContinue }

    $pyiArgs = @(
        '-m','PyInstaller','--noconfirm','--clean','--onefile','--windowed',
        '--name', ($ProjectName + '_Kurulum'),
        '--distpath', $setupDir,
        '--workpath', (Join-Path $setupDir '_pyi_build'),
        '--specpath', (Join-Path $setupDir '_pyi_spec'),
        '--hidden-import', 'py7zr',
        '--hidden-import', 'py7zr.callbacks',
        '--hidden-import', 'pycryptodomex',
        '--hidden-import', 'pyzstd',
        '--hidden-import', 'pyppmd',
        '--hidden-import', 'pybcj',
        '--hidden-import', 'texttable',
        '--hidden-import', 'inflate64',
        '--hidden-import', 'multivolumefile',
        '--hidden-import', 'win32com',
        '--hidden-import', 'win32com.client',
        '--collect-all', 'pycryptodomex',
        '--collect-all', 'pyzstd',
        '--collect-all', 'pyppmd',
        '--collect-all', 'pybcj',
        '--collect-all', 'texttable',
        '--collect-all', 'inflate64',
        '--collect-all', 'multivolumefile',
        '--collect-all', 'py7zr'
    )
    if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
        $pyiArgs += @('--icon', $IconPath)
        # Pencere ikonu icin ikonu pakete de gom (Tkinter iconbitmap icin)
        $iconExt = [IO.Path]::GetExtension($IconPath)
        if (-not $iconExt) { $iconExt = '.ico' }
        $iconCopy = Join-Path $setupDir ('_pb_window_icon' + $iconExt)
        try {
            Copy-Item -LiteralPath $IconPath -Destination $iconCopy -Force
            $pyiArgs += @('--add-data', ($iconCopy + ';.'))
            Write-Host ('   Pencere ikonu pakete gömüldü: _pb_window_icon' + $iconExt) -ForegroundColor DarkGray
        } catch {
            Write-Host ('   UYARI: ikon pakete gömülemedi: ' + $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }
    $pyiArgs += @('--add-data', ($manifestPath + ';.'))
    foreach ($pf in $payloadFiles) { $pyiArgs += @('--add-data', ($pf.FullName + ';.')) }
    $pyiArgs += $installerPy

    $r = Invoke-NativeLive -Exe $PythonExe -Label 'Kurulum exe derleniyor...' -Arguments $pyiArgs
    if ($r.ExitCode -ne 0) {
        $r.Output | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor DarkYellow }
        throw 'Kurulum exe derlenemedi.'
    }

    $builtSetup = Join-Path $setupDir ($ProjectName + '_Kurulum.exe')
    if (-not (Test-Path -LiteralPath $builtSetup)) {
        $alt = Get-ChildItem -LiteralPath $setupDir -Filter '*_Kurulum.exe' -Recurse -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($alt) { $builtSetup = $alt.FullName }
    }
    if (-not $builtSetup -or -not (Test-Path -LiteralPath $builtSetup)) { throw 'Kurulum exe dosyası bulunamadı.' }
    Copy-Item -LiteralPath $builtSetup -Destination $setupExe -Force
    return $setupExe
}

# ============================================================
#  ANA AKIS
# ============================================================
$exitCode = 0

# --- 0) Ilk acilista kullanim kilavuzu sorusu ---
# Durum dosyasi: .\Wlogin\Wlogin.json  ->  { "opened": false }
#   false (veya dosya yok) : soru sorulur, deger hemen true yapilir
#   true                   : soru sorulmaz
$script:LoginDir   = Join-Path $script:AppDir 'Wlogin'
$script:LoginFile  = Join-Path $script:LoginDir 'Wlogin.json'
$script:ManualFile = Join-Path (Join-Path $script:AppDir 'Web') 'usermanual.html'

function Test-FirstRunDone {
    try {
        if (Test-Path -LiteralPath $script:LoginFile) {
            $cfg = [IO.File]::ReadAllText($script:LoginFile, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json
            return ($cfg.opened -eq $true)
        }
    } catch {}
    return $false
}

function Set-FirstRunDone {
    try {
        if (-not (Test-Path -LiteralPath $script:LoginDir)) { New-Item -ItemType Directory -Force -Path $script:LoginDir | Out-Null }
        $json = "{`r`n  `"opened`": true`r`n}`r`n"
        [IO.File]::WriteAllText($script:LoginFile, $json, (New-Object Text.UTF8Encoding($false)))
    } catch {}
}

if (-not (Test-FirstRunDone)) {
    Set-FirstRunDone
    if (Test-Path -LiteralPath $script:ManualFile) {
        $manualSel = Show-Menu -Title 'Kullanım kılavuzunu incelemek ister misiniz?' `
            -Items @('Evet, kılavuzu tarayıcıda aç', 'Hayır, doğrudan başlat') `
            -Descriptions @(
                "Kılavuz varsayılan tarayıcınızda açılır: Python kurulumu, adım adım kullanım, seçenekler ve sık sorulan sorular.`nKılavuz açık kalırken bu pencerede devam edebilir, istediğiniz zaman kılavuza dönebilirsiniz.",
                "Kılavuzu daha sonra Web\usermanual.html dosyasına çift tıklayarak açabilirsiniz."
            )
        if ($manualSel -eq 0) {
            try { Start-Process -FilePath $script:ManualFile } catch {
                Write-Host ('   Kılavuz açılamadı: ' + $_.Exception.Message) -ForegroundColor DarkYellow
                Start-Sleep -Seconds 2
            }
        }
    }
}


# --- 1) Yol sorma ---
$target = $null
while (-not $target) {
    Clear-Host
    Write-Host ''
    Write-Host '  Python dosyanızı / proje klasörünüzü seçiniz' -ForegroundColor Cyan
    Write-Host '  --------------------------------------------' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '   Tam yolu aşağıya yapıştırın (dosyayı bu pencereye sürükleyip bırakabilirsiniz).' -ForegroundColor DarkGray
    Write-Host ''
    $inp = Read-Host '   Yol'
    if (-not $inp) { continue }
    $inp = $inp.Trim().Trim('"').Trim("'")
    if (Test-Path -LiteralPath $inp) { $target = (Resolve-Path -LiteralPath $inp).Path }
    else {
        Write-Host ''; Write-Host '   Bu yol bulunamadı. Tekrar deneyin.' -ForegroundColor Red
        Start-Sleep -Seconds 2
    }
}

$isFolder = (Get-Item -LiteralPath $target).PSIsContainer
if ($isFolder) { $projectRoot = $target } else { $projectRoot = Split-Path $target -Parent }
$script:RootPath = $projectRoot

Start-Logging -Root $projectRoot

try {

# --- 3) Proje adi ---
if ($isFolder) { $defaultName = Split-Path $projectRoot -Leaf }
else           { $defaultName = [IO.Path]::GetFileNameWithoutExtension($target) }
if ([string]::IsNullOrWhiteSpace($defaultName)) { $defaultName = 'Proje' }
$defaultName = Get-SafeFileName -Text $defaultName
if ([string]::IsNullOrWhiteSpace($defaultName)) { $defaultName = 'Proje' }

$projectName = Read-ProjectName -Root $projectRoot -Default $defaultName
$outRoot     = Join-Path $projectRoot $projectName

Set-IgnoreRegex -ExtraNames (@(Get-BuilderOutputNames -Root $projectRoot) + @($projectName))

# --- 4) Dosya secimi ---
if ($isFolder) {
    $chosenFiles  = Select-ProjectFiles -Root $projectRoot
    $pyFiles      = @($chosenFiles | Where-Object { $_ -like '*.py' -or $_ -like '*.pyw' })
    if ($pyFiles.Count -eq 0) { throw 'Seçilen dosyalar arasında hiç .py dosyası yok.' }
    if ($pyFiles.Count -eq 1) {
        $mainScript = $pyFiles[0]
    } else {
        $pref = @('main.py','app.py','__main__.py','run.py','start.py','gui.py','program.py','uygulama.py','ana.py','bot.py','launcher.py','cli.py','server.py','index.py','manage.py','wsgi.py','asgi.py')
        $ordered = @($pyFiles | Sort-Object @{Expression={ $i = $pref.IndexOf((Split-Path $_ -Leaf).ToLower()); if ($i -lt 0) { 99 } else { $i } }}, @{Expression={$_.Length}})
        $labels = @($ordered | ForEach-Object { $_.Substring($projectRoot.Length).TrimStart('\') })
        $sel = Show-Menu -Title 'Programın başladığı ana .py dosyasını seçin' -Items $labels
        $mainScript = $ordered[$sel]
    }
} else {
    if ($target -notlike '*.py' -and $target -notlike '*.pyw') { throw 'Seçilen dosya bir .py / .pyw dosyası değil.' }
    $mainScript  = $target
    $chosenFiles = @($target)
}

# --- 5) Bit secimi ---
$bitSel = Show-Menu -Title 'Lütfen exe dosyasının kaç bit olarak işleneceğini seçin' `
    -Items @('32 bit (x86)', '64 bit (x64)') `
    -Descriptions @(
      "Eski ve 32 bit Windows sistemlerde de çalışır.`nBellek kullanımı 4 GB ile sınırlıdır.`nÜretmek için sisteminizde 32 bit bir Python 3 kurulu olmalıdır.",
      "Günümüz Windows sistemlerinin standardı, daha hızlı ve sınırsız bellek.`n32 bit Windows'ta ÇALIŞMAZ.`nEmin değilseniz bunu seçin."
    )
$wantBits = if ($bitSel -eq 0) { 32 } else { 64 }

# --- 6) Python bul ---
Write-Header 'Sistemdeki Python 3 kurulumları taranıyor...'
Write-Host '   Lütfen bekleyin.' -ForegroundColor DarkGray
$all = Find-PythonInterpreters
$matching = @($all | Where-Object { $_.Bits -eq $wantBits })

if ($all.Count -eq 0) {
    Write-Header 'Sistemde Python 3 bulunamadı'
    Write-Host '   Bu araç yalnızca Python 3 ile çalışır.' -ForegroundColor Red
    Write-Host ''
    Write-Host '   Çözüm: python.org adresinden bir Python 3 sürümü kurup bu aracı tekrar çalıştırın.' -ForegroundColor Yellow
    throw 'İşlem durduruldu.'
}

if ($matching.Count -eq 0) {
    Write-Header 'Uygun Python 3 sürümü bulunamadı'
    Write-Host ("   Sisteminizde $wantBits bit bir Python 3 kurulumu bulunamadı.") -ForegroundColor Red
    Write-Host ''
    Write-Host '   Bulunan diger Python 3 kurulumları:' -ForegroundColor Yellow
    foreach ($p in $all) { Write-Host ('     - Python ' + $p.Version + ' (' + $p.Bits + ' bit) -> ' + $p.Path) }
    Write-Host ''
    Write-Host ("   Çözüm: python.org adresinden $wantBits bit Python 3 kurup bu aracı tekrar çalıştırın.") -ForegroundColor Yellow
    throw 'İşlem durduruldu.'
}

$labels = @($matching | ForEach-Object { 'Python ' + $_.Version + '  (' + $_.Bits + ' bit)   ' + $_.Path })
$sel = Show-Menu -Title ("Kullanılacak Python 3 sürümünü seçin ($wantBits bit)") -Items $labels
$python = $matching[$sel]

# --- 7) Cikti tipi ---
$outSel = Show-Menu -Title 'Exe çıktı biçimini seçin' `
    -Items @('Tek dosya (--onefile), konsol penceresi açık',
             'Tek dosya (--onefile), pencereli/konsolsuz (--noconsole)',
             'Klasör halinde (--onedir), konsol penceresi açık',
             'Klasör halinde (--onedir), pencereli/konsolsuz (--noconsole)') `
    -Descriptions @(
      "Her şey tek bir .exe içine paketlenir.`nÇalışırken siyah bir konsol penceresi açılır.",
      "Yine tek bir .exe oluşur ama hiçbir konsol penceresi görünmez.`nTkinter, PyQt, PySide, Kivy gibi arayüzlü programlar için doğru seçimdir.",
      "Exe ve tüm bağımlılıklar proje klasörüne dağıtılır.`nÇalışırken siyah bir konsol penceresi açılır.`nAçılış hızı daha yüksektir.",
      "Exe ve tüm bağımlılılıklar proje klasörüne dağıtılır.`nHiçbir konsol penceresi görünmez; arayüzlü (GUI) uygulamalar için uygundur."
    )

# --- 8) Ikon ---
$iconPath = $null
$searchArgs = @{ LiteralPath = $projectRoot; File = $true; Force = $true; ErrorAction = 'SilentlyContinue' }
if ($isFolder) { $searchArgs['Recurse'] = $true }
$iconCands = @(Get-ChildItem @searchArgs |
    Where-Object {
        -not (Test-Ignored $_.FullName) -and
        $_.Extension -match '^\.(ico|png)$' -and
        $_.BaseName -match '(?i)(icon|ikon|logo|favicon|app|uygulama|program)'
    } |
    Sort-Object @{Expression={ if ($_.Extension -eq '.ico') { 0 } else { 1 } }},
                @{Expression={ if ($_.BaseName -match '(?i)^icon$|^ikon$') { 0 } else { 1 } }},
                @{Expression={ (Split-Path $_.FullName -Parent).Length }})

if ($iconCands.Count -eq 1) {
    $iconPath = $iconCands[0].FullName
    Write-Header 'İkon bulundu'
    Write-Host ('   ' + $iconPath) -ForegroundColor Green
    Write-Host ''
    Write-Host '   Bu dosya exe ikonu VE pencerelerin sol üst köşesindeki logo olarak kullanılacak.' -ForegroundColor DarkGray
    Write-Host '   Devam etmek için bir tuşa basın...' -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
} elseif ($iconCands.Count -gt 1) {
    $iconLabels = @($iconCands | ForEach-Object { $_.FullName.Substring($projectRoot.Length).TrimStart('\') })
    $iconLabels += 'İkon kullanma (varsayılan Python ikonu)'
    $isel = Show-Menu -Title 'Birden fazla ikon dosyası bulundu, birini seçin' -Items $iconLabels
    if ($isel -lt $iconCands.Count) { $iconPath = $iconCands[$isel].FullName }
}

# --- 9) Paketleri tespit et (yalnizca secilen dosyalar taranir) ---
Write-Header 'Gerekli kütüphaneler tespit ediliyor...'
$req = Get-RequiredPackages -Root $projectRoot -PyExe $python.Path -Files $pyFiles
Write-Host ('   Kaynak: ' + $req.Source) -ForegroundColor Yellow
Write-Host ''
if ($req.Packages.Count -eq 0) {
    Write-Host '   Harici kütüphane tespit edilmedi (yalnızca standart kütüphane kullanılıyor).' -ForegroundColor Green
} else {
    foreach ($p in $req.Packages) { Write-Host ('     - ' + $p.Spec) }
}
Write-Host ''
Write-Host '   Devam etmek için bir tuşa basın...' -ForegroundColor DarkGray
[void][Console]::ReadKey($true)

# --- 10) Cikti klasoru + gecici calisma alani ---
$exeName  = $projectName
$work     = Join-Path $outRoot '_derleme_gecici'
$dist     = Join-Path $work 'dist'
$buildDir = Join-Path $work 'build'
$spec     = Join-Path $work 'spec'

New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

$markerPath = Join-Path $outRoot $MARKER
if (-not (Test-Path -LiteralPath $markerPath)) {
    try {
        [IO.File]::WriteAllText($markerPath, 'PyExeBuilder çıktı klasörü', (New-Object Text.UTF8Encoding($false)))
        (Get-Item -LiteralPath $markerPath -Force).Attributes = 'Hidden'
    } catch {}
}

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

Write-Header 'Python ortamı hazırlanıyor'
Write-Host ('   Seçili Python  : ' + $python.Path) -ForegroundColor Yellow
Write-Host '   Mod           : Kalıcı kurulum (paketler bu Python sürümüne --user ile kurulur)' -ForegroundColor DarkGray
Write-Host ''

$vpy = $python.Path

Write-Host '   pip güncelleniyor...' -ForegroundColor DarkGray
$r = Invoke-NativeLive -Exe $vpy -Label 'pip güncelleniyor...' -Quiet -Arguments @('-m','pip','install','--user','--upgrade','pip','setuptools','wheel','--disable-pip-version-check','-q')
if ($r.ExitCode -ne 0) {
    Write-Host '   pip güncellenemedi, mevcut pip ile devam ediliyor.' -ForegroundColor DarkYellow
}

# --- 11) Paketleri kur ---
$failed = @()
$toInstall = New-Object System.Collections.Generic.List[object]
$installSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $req.Packages) {
    $nk = Normalize-PkgName -Name $p.Name
    if ($installSeen.Add($nk)) { $toInstall.Add($p) }
}
foreach ($extra in @(
    [pscustomobject]@{ Name='pyinstaller'; Spec='pyinstaller' },
    [pscustomobject]@{ Name='pyinstaller-hooks-contrib'; Spec='pyinstaller-hooks-contrib' },
    [pscustomobject]@{ Name='setuptools'; Spec='setuptools' },
    [pscustomobject]@{ Name='wheel'; Spec='wheel' },
    [pscustomobject]@{ Name='pip'; Spec='pip' },
    [pscustomobject]@{ Name='certifi'; Spec='certifi' },
    [pscustomobject]@{ Name='pywin32'; Spec='pywin32' }
)) {
    $nk = Normalize-PkgName -Name $extra.Name
    if ($installSeen.Add($nk)) { $toInstall.Add($extra) }
}
if ($iconPath -and $iconPath -like '*.png') {
    $nk = Normalize-PkgName -Name 'Pillow'
    if ($installSeen.Add($nk)) { $toInstall.Add([pscustomobject]@{ Name='Pillow'; Spec='Pillow' }) }
}

$n = 0
$totalPkg = $toInstall.Count
foreach ($pkg in $toInstall) {
    $n++
    $pkgName = $pkg.Name
    $pkgSpec = $pkg.Spec
    Write-Header 'Kütüphaneler kuruluyor'
    Write-Host ("   [$n / " + $totalPkg + "]  " + $pkgSpec) -ForegroundColor Yellow
    $pct = [int](($n - 1) / [double][Math]::Max(1, $totalPkg) * 100)
    $bar = '[' + ('#' * [int]($pct / 3)) + ('.' * (33 - [int]($pct / 3))) + '] ' + $pct + '%'
    Write-Host ('   ' + $bar) -ForegroundColor DarkCyan
    Write-Host ''

    $alreadyInstalled = $false
    if ($pkgName -and $pkgName -notmatch '^(git\+|https?:|file:)') {
        $r = Invoke-Native -Exe $vpy -Arguments @('-m','pip','show',$pkgName)
        if ($r.ExitCode -eq 0) { $alreadyInstalled = $true }
    }
    if ($alreadyInstalled) {
        Write-Host '   Zaten kurulu, atlanıyor.' -ForegroundColor Green
        Start-Sleep -Milliseconds 400
        continue
    }

    $r = Invoke-NativeLive -Exe $vpy -Label ("Kuruluyor: " + $pkgSpec) -Quiet -Arguments @('-m','pip','install','--user',$pkgSpec,'--disable-pip-version-check')
    if ($r.ExitCode -ne 0) {
        $failed += $pkgSpec
        Write-Host ''
        Write-Host ('   >>> ' + $pkgSpec + ' KURULAMADI (çıkış kodu: ' + $r.ExitCode + ')') -ForegroundColor Red
        Write-Host '   3 saniye sonra devam edilecek...' -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
    }
}

if (@($failed | Where-Object { $_ -match '(?i)^pyinstaller' }).Count -gt 0) {
    throw ('PyInstaller kurulamadı, derleme yapılamaz. Başarısız paketler: ' + ($failed -join ', '))
}
if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host '   Kurulamayan paketler var. Devam edilsin mi?' -ForegroundColor Yellow
    foreach ($f in $failed) { Write-Host ('     - ' + $f) -ForegroundColor Yellow }
    $k = [Console]::ReadKey($true)
    if ($k.Key -eq 'H' -or $k.Key -eq 'N') { throw 'Kullanıcı iptal etti.' }
}

# --- 12) Derleme argumanlari ---
$pyArgs = @('-m','PyInstaller','--noconfirm','--clean','--log-level=WARN',
            '--distpath',$dist,'--workpath',$buildDir,'--specpath',$spec,
            '--name',$exeName,'--paths',$projectRoot)
switch ($outSel) {
    0 { $pyArgs += '--onefile' }
    1 { $pyArgs += @('--onefile','--noconsole') }
    2 { $pyArgs += '--onedir' }
    3 { $pyArgs += @('--onedir','--noconsole') }
}
if ($iconPath) { $pyArgs += @('--icon', $iconPath) }

if ($iconPath) {
    $iconExt  = [IO.Path]::GetExtension($iconPath)
    if (-not $iconExt) { $iconExt = '.ico' }
    $packagedIcon = Join-Path $work ('_pyexebuilder_icon' + $iconExt)
    Copy-Item -LiteralPath $iconPath -Destination $packagedIcon -Force
    $pyArgs += @('--add-data', ($packagedIcon + ';.'))
}

$hookPath = Join-Path $work 'pyexebuilder_runtime_hook.py'
$hookCode = Get-PyModuleSource 'runtime_hook.py'
[IO.File]::WriteAllText($hookPath, $hookCode, (New-Object Text.UTF8Encoding($false)))
$pyArgs += @('--runtime-hook', $hookPath)

$collectAdded     = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$hiddenAdded      = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$collectSubAdded  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$collectDataAdded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$copyMetaAdded    = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

foreach ($p in $req.Packages) {
    $nk = Normalize-PkgName -Name $p.Name
    if ($script:COLLECT_ALL_NORM.ContainsKey($nk)) {
        $imp = $script:COLLECT_ALL_NORM[$nk]
        if ($imp -and $collectAdded.Add($imp)) { $pyArgs += @('--collect-all', $imp) }
    }
    if ($script:HIDDEN_IMPORTS_NORM.ContainsKey($nk)) {
        foreach ($h in $script:HIDDEN_IMPORTS_NORM[$nk]) {
            if ($h -and $hiddenAdded.Add($h)) { $pyArgs += @('--hidden-import', $h) }
        }
    }
    if ($script:COLLECT_SUBMOD_NORM.ContainsKey($nk)) {
        foreach ($s in $script:COLLECT_SUBMOD_NORM[$nk]) {
            if ($s -and $collectSubAdded.Add($s)) { $pyArgs += @('--collect-submodules', $s) }
        }
    }
    if ($script:COLLECT_DATA_NORM.ContainsKey($nk)) {
        foreach ($s in $script:COLLECT_DATA_NORM[$nk]) {
            if ($s -and $collectDataAdded.Add($s)) { $pyArgs += @('--collect-data', $s) }
        }
    }
    if ($script:COPY_METADATA_NORM.ContainsKey($nk)) {
        foreach ($s in $script:COPY_METADATA_NORM[$nk]) {
            if ($s -and $copyMetaAdded.Add($s)) { $pyArgs += @('--copy-metadata', $s) }
        }
    }
}

foreach ($h in @(
    'encodings.idna','encodings.utf_8','encodings.latin_1','encodings.cp1254','encodings.cp1252',
    'sqlite3','_sqlite3','ssl','_ssl','hashlib','_hashlib','zlib','_zlib','bz2','_bz2',
    'lzma','_lzma','ctypes','_ctypes','ctypes.util','ctypes.wintypes','decimal','_decimal',
    'multiprocessing','multiprocessing.spawn','multiprocessing.popen_spawn_win32',
    'multiprocessing.resource_tracker','concurrent.futures','concurrent.futures.process',
    'concurrent.futures.thread','asyncio','asyncio.windows_events','asyncio.windows_utils',
    'asyncio.proactor_events','asyncio.selector_events','email.mime.text','email.mime.multipart',
    'email.mime.application','xml.etree.ElementTree','xml.etree.cElementTree',
    'logging.handlers','pkgutil','pkg_resources','importlib.metadata',
    'importlib.resources','importlib.util','uuid','secrets','zoneinfo','tzdata',
    'sqlite3.dbapi2','http.server','socketserver','wsgiref.simple_server','wsgiref.handlers',
    'webbrowser','turtle','tkinter','tkinter.ttk','tkinter.filedialog','tkinter.messagebox',
    '_socket','select','_select','socket'
)) {
    if ($h -and $hiddenAdded.Add($h)) { $pyArgs += @('--hidden-import', $h) }
}

$dataRoots = @{}
foreach ($f in $chosenFiles) {
    if ($f -like '*.py' -or $f -like '*.pyw') { continue }
    if ($f -like '*requirements.txt') { continue }
    if ($f -like '*\_pyexebuilder_icon.*') { continue }
    $relDir = Split-Path $f -Parent
    $destRel = if ($relDir.Length -le $projectRoot.Length) { '.' } else { $relDir.Substring($projectRoot.Length).TrimStart('\') }
    $topName = if ($destRel -eq '.') { '.' } else { ($destRel -split '\\')[0] }
    $key = $topName
    if (-not $dataRoots.ContainsKey($key)) {
        $dataRoots[$key] = @{ Top = $topName; Dir = if ($topName -eq '.') { $projectRoot } else { Join-Path $projectRoot $topName }; Selected = @() }
    }
    $dataRoots[$key].Selected += $f
}
foreach ($key in $dataRoots.Keys) {
    $info = $dataRoots[$key]
    $allInDir = @()
    try {
        $allInDir = @(Get-ChildItem -LiteralPath $info.Dir -Recurse -File -Force -ErrorAction SilentlyContinue |
                       Where-Object { -not (Test-Ignored $_.FullName) } |
                       ForEach-Object { $_.FullName })
    } catch { $allInDir = @() }
    $selectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $info.Selected) { [void]$selectedSet.Add($x) }
    $allInDirSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $allInDir) { [void]$allInDirSet.Add($x) }
    if ($allInDirSet.Count -gt 0 -and $selectedSet.Count -eq $allInDirSet.Count) {
        $pyArgs += @('--add-data', ($info.Dir + ';' + $info.Top))
    } else {
        foreach ($f in $info.Selected) {
            $relDir = Split-Path $f -Parent
            $destRel = if ($relDir.Length -le $projectRoot.Length) { '.' } else { $relDir.Substring($projectRoot.Length).TrimStart('\') }
            $pyArgs += @('--add-data', ($f + ';' + $destRel))
        }
    }
}

$pyArgs += $mainScript

Write-Header 'EXE derleniyor'
Write-Host ('   Proje adı : ' + $projectName) -ForegroundColor Yellow
Write-Host ('   Ana dosya : ' + $mainScript) -ForegroundColor Yellow
Write-Host ('   Python    : ' + $python.Version + ' (' + $python.Bits + ' bit)') -ForegroundColor Yellow
if ($iconPath) { Write-Host ('   Ikon      : ' + $iconPath) -ForegroundColor Yellow }
Write-Host ('   PyInstaller argüman sayısı: ' + $pyArgs.Count) -ForegroundColor DarkGray
Write-Host ''
Write-Host '   Bu işlem projenin büyüklüğüne göre birkaç dakika sürebilir...' -ForegroundColor DarkGray
Write-Host ''

$r = Invoke-NativeLive -Exe $vpy -Label 'EXE derleniyor...' -Arguments $pyArgs
$buildOut  = $r.Output
$buildCode = $r.ExitCode

Write-Header 'Sonuç'
if ($buildCode -ne 0) {
    $exitCode = $buildCode
    Write-Host '   Derleme BAŞARISIZ oldu.' -ForegroundColor Red
    Write-Host ('   PyInstaller çıkış kodu: ' + $buildCode) -ForegroundColor Red
    Write-Host ''
    Write-Host '   --- PyInstaller çıktısı (son 60 satır) ---' -ForegroundColor Yellow
    $tail = @($buildOut) | Select-Object -Last 60
    foreach ($l in $tail) { Write-Host ('   ' + $l) -ForegroundColor DarkYellow }
    Write-Host ''
    if ($script:SessionLog) { Write-Host ('   Tam çıktı için oturum loguna bakın: ' + $script:SessionLog) -ForegroundColor Cyan }
    Write-Host ('   İnceleme için geçici dosyalar bırakıldı: ' + $work) -ForegroundColor DarkCyan
} else {
    if ($outSel -in @(2,3)) { $builtExe = Join-Path (Join-Path $dist $exeName) ($exeName + '.exe') }
    else                    { $builtExe = Join-Path $dist ($exeName + '.exe') }
    if (-not (Test-Path -LiteralPath $builtExe)) {
        $alt = Get-ChildItem -LiteralPath $dist -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $builtExe = if ($alt) { $alt.FullName } else { $null }
    }
    if (-not $builtExe) {
        $exitCode = 1
        Write-Host '   Derleme bitti ancak exe dosyası bulunamadı.' -ForegroundColor Red
        Write-Host ('   Kontrol edin: ' + $dist)
    } else {
        if ($outSel -in @(2,3)) {
            $srcDir = Split-Path $builtExe -Parent
            $oldInternal = Join-Path $outRoot '_internal'
            if (Test-Path -LiteralPath $oldInternal) { Remove-Item -LiteralPath $oldInternal -Recurse -Force -ErrorAction SilentlyContinue }
            Get-ChildItem -LiteralPath $srcDir -Force | Copy-Item -Destination $outRoot -Recurse -Force
        } else {
            Copy-Item -LiteralPath $builtExe -Destination $outRoot -Force
        }
        $finalExe = Join-Path $outRoot (Split-Path $builtExe -Leaf)
        if (-not (Test-Path -LiteralPath $finalExe)) { throw ('Exe çıktı klasörüne kopyalanamadı: ' + $finalExe) }
        $exeInfo = Get-Item -LiteralPath $finalExe

        $setupExePath = $null
        $installerSel = Show-Menu -Title 'Derleme ek olarak kurulum ister misiniz?' `
            -Items @('Evet, kurulum paketi oluştur', 'Hayır, sadece derleme yeterli') `
            -Descriptions @(
                "Çıktı klasörü 250 MB'lik chunk'lara bölünüp CPU/2 worker ile paralel LZMA2 ultra sıkıştırmasına tabi tutulur.`n`nKurulum penceresi GUI tabanlıdır; ilerleme çubuğu ve küçük bir günlük alanı gösterir.`n`n250 MB'ı aşan tek dosyalar otomatik olarak parçalara bölünür; kurulumda tekrar birleştirilir.",
                'Yalnızca exe dosyası ve yardımcı dosyalar üretilir; kurulum paketi hazırlanmaz.'
            )

        if ($installerSel -eq 0) {
            Write-Header 'Kurulum paketi hazırlanıyor (paralel py7zr)'
            $compat = Test-Py7zrCompatibility -PyExe $python.Path
            if (-not $compat.Ok) {
                Write-Host ''
                Write-Host '   UYARI: py7zr Python sürümünüzle uyumlu değil!' -ForegroundColor Yellow
                Write-Host ('   ' + $compat.Reason) -ForegroundColor Yellow
                Write-Host ''
                Write-Host '   Kurulum paketi oluşturma atlanıyor.' -ForegroundColor Red
                Start-Sleep -Seconds 5
            } else {
                $py7zrReady = $false
                $rCheck = Invoke-Native -Exe $python.Path -Arguments @('-c','import py7zr;print(py7zr.__version__)')
                if ($rCheck.ExitCode -eq 0) {
                    Write-Host '   py7zr zaten kurulu.' -ForegroundColor Green
                    $py7zrReady = $true
                } else {
                    Write-Host '   py7zr seçili Python sürümüne kalıcı olarak kuruluyor...' -ForegroundColor DarkGray
                    $r = Invoke-NativeLive -Exe $python.Path -Label 'py7zr kuruluyor...' -Quiet -Arguments @('-m','pip','install','--user','py7zr','--disable-pip-version-check')
                    if ($r.ExitCode -ne 0) {
                        Write-Host '   HATA: py7zr kurulamadı! Kurulum paketi oluşturma atlanıyor.' -ForegroundColor Red
                        Start-Sleep -Seconds 6
                    } else {
                        Write-Host '   py7zr başarıyla kuruldu.' -ForegroundColor Green
                        $py7zrReady = $true
                    }
                }

                if ($py7zrReady) {
                    $setupWork = Join-Path $work 'setup_build'
                    if (-not (Test-Path -LiteralPath $setupWork)) { New-Item -ItemType Directory -Force -Path $setupWork | Out-Null }

                    # --- GUI uninstaller ---
                    $uninstBuild = Join-Path $work 'uninst_build'
                    if (Test-Path -LiteralPath $uninstBuild) { Remove-Item -LiteralPath $uninstBuild -Recurse -Force -ErrorAction SilentlyContinue }
                    New-Item -ItemType Directory -Force -Path $uninstBuild | Out-Null

                    $uninstPy = Join-Path $uninstBuild 'uninstaller.py'
                    $uninstCode = Get-PyModuleSource 'uninstaller.py'
                    $uninstCode = $uninstCode.Replace('__PROJECT_NAME__', (ConvertTo-PyLiteral $projectName))
                    $uninstCode = $uninstCode.Replace('__EXE_NAME__', (ConvertTo-PyLiteral $exeName))
                    [IO.File]::WriteAllText($uninstPy, $uninstCode, (New-Object Text.UTF8Encoding($true)))

                    Write-Host '   Kaldırma aracı (uninstall.exe) derleniyor...' -ForegroundColor DarkGray
                    $uninstArgs = @(
                        '-m','PyInstaller','--noconfirm','--clean','--onefile','--windowed',
                        '--name','uninstall',
                        '--distpath', $uninstBuild,
                        '--workpath', (Join-Path $uninstBuild '_pyi_build'),
                        '--specpath', (Join-Path $uninstBuild '_pyi_spec')
                    )
                    if ($iconPath -and (Test-Path -LiteralPath $iconPath)) {
                        $uninstArgs += @('--icon', $iconPath)
                        $uninstIconExt = [IO.Path]::GetExtension($iconPath)
                        if (-not $uninstIconExt) { $uninstIconExt = '.ico' }
                        $uninstIconCopy = Join-Path $uninstBuild ('_pb_window_icon' + $uninstIconExt)
                        try {
                            Copy-Item -LiteralPath $iconPath -Destination $uninstIconCopy -Force
                            $uninstArgs += @('--add-data', ($uninstIconCopy + ';.'))
                        } catch {
                            Write-Host ('   UYARI: uninstall ikonu pakete gömülemedi: ' + $_.Exception.Message) -ForegroundColor DarkYellow
                        }
                    }
                    $uninstArgs += $uninstPy
                    $rU = Invoke-NativeLive -Exe $python.Path -Label 'uninstall.exe derleniyor...' -Quiet -Arguments $uninstArgs
                    if ($rU.ExitCode -ne 0) {
                        Write-Host '   UYARI: uninstall.exe derlenemedi.' -ForegroundColor Yellow
                    } else {
                        $builtUninst = Join-Path $uninstBuild 'uninstall.exe'
                        if (Test-Path -LiteralPath $builtUninst) {
                            Copy-Item -LiteralPath $builtUninst -Destination (Join-Path $outRoot 'uninstall.exe') -Force
                            Write-Host '   uninstall.exe çıktı klasörüne eklendi.' -ForegroundColor Green
                        }
                    }

                    try {
                        $setupExePath = New-Py7zrSetupPackage `
                            -OutRoot     $outRoot `
                            -ProjectName $projectName `
                            -ExeName     $exeName `
                            -WorkDir     $setupWork `
                            -PythonExe   $python.Path `
                            -IconPath    $iconPath
                        Write-Host ''
                        Write-Host '   Kurulum paketi başarıyla oluşturuldu.' -ForegroundColor Green
                        Write-Host ('   ' + $setupExePath) -ForegroundColor White
                        Write-Host ('   Boyut: ' + [Math]::Round((Get-Item -LiteralPath $setupExePath).Length / 1MB, 2) + ' MB') -ForegroundColor DarkGray
                    } catch {
                        Write-Host ''
                        Write-Host ('   Kurulum paketi oluşturulamadı: ' + $_.Exception.Message) -ForegroundColor Red
                    }
                }
            }
        }

        $cleanOk = $true
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop }
        catch { $cleanOk = $false }

        Write-Host ''
        Write-Host '   Çıktı klasörü:' -ForegroundColor Yellow
        Write-Host ('   ' + $outRoot) -ForegroundColor White
        Write-Host ''
        Write-Host '   EXE dosyasının tam yolu:' -ForegroundColor Yellow
        Write-Host ('   ' + $exeInfo.FullName) -ForegroundColor White
        Write-Host ('   Boyut: ' + [Math]::Round($exeInfo.Length / 1MB, 2) + ' MB') -ForegroundColor DarkGray
        if ($setupExePath -and (Test-Path -LiteralPath $setupExePath)) {
            Write-Host ''
            Write-Host '   KURULUM paketi:' -ForegroundColor Cyan
            Write-Host ('   ' + $setupExePath) -ForegroundColor White
        }
        $uninstOut = Join-Path $outRoot 'uninstall.exe'
        if (Test-Path -LiteralPath $uninstOut) {
            Write-Host ''
            Write-Host '   Kaldırma aracı:' -ForegroundColor Cyan
            Write-Host ('   ' + $uninstOut) -ForegroundColor White
        }
        if ($outSel -in @(2,3)) {
            Write-Host ''
            Write-Host '   NOT: --onedir seçtiniz, exe ile birlikte klasörün TAMAMINI taşımalısınız.' -ForegroundColor DarkGray
        }
        if (-not $cleanOk) {
            Write-Host ''
            Write-Host ('   Geçici klasör tamamen silinemedi: ' + $work) -ForegroundColor DarkYellow
        }

        $openTarget = if ($setupExePath -and (Test-Path -LiteralPath $setupExePath)) { $setupExePath } else { $exeInfo.FullName }
        Write-Host ''
        Write-Host '   Klasörü açmak için O, çıkmak için başka bir tuşa basın.' -ForegroundColor DarkGray
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'O') { Start-Process explorer.exe ('/select,"' + $openTarget + '"') }
    }
}

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host '   Kurulamayan paketler:' -ForegroundColor Yellow
    foreach ($f in $failed) { Write-Host ('     - ' + $f) -ForegroundColor Yellow }
}

} catch {
    $exitCode = 1
    try { Save-ErrorReport -ErrorRecord $_ -Context 'Ana akış' }
    catch {
        Write-Host ''
        Write-Host '   HATA (rapor yazılamadı):' -ForegroundColor Red
        Write-Host ($_.Exception.ToString()) -ForegroundColor DarkYellow
    }
    Write-Host ''
    Write-Host '   Kapatmak için bir tuşa basın...' -ForegroundColor DarkGray
    try { [void][Console]::ReadKey($true) } catch {}
}

if ($script:TranscriptActive) {
    try { Stop-Transcript | Out-Null } catch {}
}

if ($script:LogDir -or $script:SessionLog -or $script:ErrorLogPath) {
    Write-Host ''
    if ($script:LogDir)       { Write-Host ('   Log klasörü : ' + $script:LogDir)   -ForegroundColor DarkCyan }
    if ($script:SessionLog)   { Write-Host ('   Oturum logu : ' + $script:SessionLog) -ForegroundColor DarkCyan }
    if ($script:ErrorLogPath) { Write-Host ('   Hata logu   : ' + $script:ErrorLogPath) -ForegroundColor DarkCyan }
}

exit $exitCode