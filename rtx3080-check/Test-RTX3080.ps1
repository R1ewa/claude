# ============================================================================
#  Test-RTX3080.ps1 — проверка б/у видеокарты NVIDIA GeForce RTX 3080
#
#  Запуск: двойной клик по CHECK_GPU.bat (лежит рядом) или из PowerShell:
#      powershell -ExecutionPolicy Bypass -File .\Test-RTX3080.ps1
#
#  Параметры:
#      -StressMinutes N   длительность стресс-теста в минутах (по умолчанию 5)
#      -VramMinutes N     длительность теста видеопамяти в минутах (по умолчанию 4)
#      -SkipStress        пропустить стресс-тест
#      -SkipVram          пропустить тест видеопамяти
#
#  Что проверяет:
#      1. Карта определяется системой, драйвер NVIDIA установлен
#      2. Подлинность: PCI Device ID соответствует настоящему RTX 3080
#         (защита от «перешитых» подделок)
#      3. Объём видеопамяти соответствует модели (10 или 12 ГБ)
#      4. Ширина и поколение PCIe (следы райзеров/майнинг-ферм)
#      5. Температура и вентиляторы в простое
#      6. Журнал Windows: сбросы/ошибки видеодрайвера за последние 14 дней
#      7. Стресс-тест (FurMark, если лежит рядом на флешке) с мониторингом:
#         температура, частоты, потребление, троттлинг, сбросы драйвера
#      8. Тест видеопамяти (memtest_vulkan, если лежит рядом на флешке)
#
#  Все результаты и логи сохраняются в папку logs_<дата> рядом со скриптом.
# ============================================================================

param(
    [int]$StressMinutes = 5,
    [int]$VramMinutes = 4,
    [switch]$SkipStress,
    [switch]$SkipVram
)

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$Root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$LogDir = Join-Path $Root ("logs_" + $Stamp)
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
try { Start-Transcript -Path (Join-Path $LogDir 'report.txt') -Force | Out-Null } catch {}

# ---------------------------------------------------------------------------
# Сбор результатов
# ---------------------------------------------------------------------------
$Results = New-Object System.Collections.ArrayList

function Add-Result {
    param([string]$Status, [string]$Name, [string]$Detail)
    [void]$Results.Add([pscustomobject]@{ Status = $Status; Name = $Name; Detail = $Detail })
    $color = 'Gray'
    if ($Status -eq 'OK')   { $color = 'Green' }
    if ($Status -eq 'WARN') { $color = 'Yellow' }
    if ($Status -eq 'FAIL') { $color = 'Red' }
    Write-Host ("  [{0,-4}] {1}" -f $Status, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor DarkGray }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=== " + $Title + " " + ("=" * [Math]::Max(1, 70 - $Title.Length))) -ForegroundColor Cyan
}

function Parse-Num {
    param([string]$s)
    $v = 0.0
    if ($s -and [double]::TryParse($s.Trim(), [ref]$v)) { return $v }
    return $null
}

Write-Host ""
Write-Host "############################################################" -ForegroundColor Cyan
Write-Host "#   ПРОВЕРКА Б/У RTX 3080                                  #" -ForegroundColor Cyan
Write-Host "#   Логи сохраняются в: $LogDir" -ForegroundColor Cyan
Write-Host "############################################################" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Поиск nvidia-smi
# ---------------------------------------------------------------------------
Write-Section "1. Драйвер NVIDIA и утилита nvidia-smi"

$smiCandidates = @(
    (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
    (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
)
$smi = $null
foreach ($p in $smiCandidates) { if (Test-Path $p) { $smi = $p; break } }
if (-not $smi) {
    $w = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($w) { $smi = $w.Source }
}

if (-not $smi) {
    Add-Result 'FAIL' 'nvidia-smi не найден' 'Драйвер NVIDIA не установлен или карта не определилась. Дальнейшая проверка невозможна.'
    Write-Host ""
    Write-Host "Установите драйвер NVIDIA и запустите проверку заново." -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    Read-Host "Нажмите Enter для выхода"
    exit 1
}
Add-Result 'OK' 'nvidia-smi найден' $smi

# Полный дамп состояния карты — в лог
& $smi -q | Out-File -FilePath (Join-Path $LogDir 'nvidia-smi-full.txt') -Encoding utf8

# ---------------------------------------------------------------------------
# 2. Базовая информация о карте
# ---------------------------------------------------------------------------
Write-Section "2. Идентификация карты"

$fields = 'name,driver_version,vbios_version,serial,uuid,memory.total,pcie.link.gen.max,pcie.link.gen.current,pcie.link.width.max,pcie.link.width.current,temperature.gpu,power.draw,power.limit,power.max_limit,fan.speed,clocks.gr,clocks.mem'
$raw = (& $smi ("--query-gpu=" + $fields) --format=csv,noheader,nounits 2>&1 | Select-Object -First 1)

if (-not $raw -or $raw -match 'NVIDIA-SMI has failed|No devices') {
    Add-Result 'FAIL' 'nvidia-smi не видит GPU' ("Вывод: " + $raw)
    try { Stop-Transcript | Out-Null } catch {}
    Read-Host "Нажмите Enter для выхода"
    exit 1
}

$f = ($raw -split ',') | ForEach-Object { $_.Trim() }
$gpuName    = $f[0]
$driverVer  = $f[1]
$vbios      = $f[2]
$serial     = $f[3]
$uuid       = $f[4]
$memTotal   = Parse-Num $f[5]
$pcieGenMax = $f[6]
$pcieWMax   = $f[8]
$pcieWCur   = $f[9]
$idleTemp   = Parse-Num $f[10]
$idlePower  = Parse-Num $f[11]
$powerLimit = Parse-Num $f[12]
$powerMax   = Parse-Num $f[13]
$idleFan    = Parse-Num $f[14]

Write-Host "  Модель:         $gpuName"
Write-Host "  Драйвер:        $driverVer"
Write-Host "  VBIOS:          $vbios"
Write-Host "  Серийный номер: $serial"
Write-Host "  UUID:           $uuid"
Write-Host "  Память:         $memTotal МиБ"
Write-Host "  Лимит питания:  $powerLimit Вт (макс. $powerMax Вт)"

if ($gpuName -match '3080') {
    Add-Result 'OK' 'Карта представляется как RTX 3080' $gpuName
} else {
    Add-Result 'FAIL' 'Название карты не содержит 3080' $gpuName
}

# ---------------------------------------------------------------------------
# 3. Проверка подлинности по PCI Device ID
#    Подделки — это старые карты с перешитым BIOS: название подменить легко,
#    а PCI Device ID чипа — нет.
# ---------------------------------------------------------------------------
Write-Section "3. Подлинность (PCI Device ID)"

$known3080 = @{
    '2206' = 'RTX 3080 10GB (GA102-200)'
    '2216' = 'RTX 3080 10GB LHR (GA102-202)'
    '220A' = 'RTX 3080 12GB (GA102-220)'
}

$devId = $null
$pnp = $null
try {
    $vc = Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.PNPDeviceID -match 'VEN_10DE' } | Select-Object -First 1
    if ($vc) { $pnp = $vc.PNPDeviceID }
} catch {}
if ($pnp -and $pnp -match 'DEV_([0-9A-Fa-f]{4})') { $devId = $Matches[1].ToUpper() }

if ($devId) {
    Write-Host "  PCI Device ID: 10DE:$devId"
    if ($known3080.ContainsKey($devId)) {
        Add-Result 'OK' 'Чип соответствует настоящему RTX 3080' $known3080[$devId]
        # Сверка объёма памяти с конкретной ревизией
        $expectedMem = 10240
        if ($devId -eq '220A') { $expectedMem = 12288 }
        if ($memTotal -and [Math]::Abs($memTotal - $expectedMem) -le 300) {
            Add-Result 'OK' 'Объём видеопамяти соответствует модели' ("$memTotal МиБ (ожидалось ~$expectedMem)")
        } else {
            Add-Result 'FAIL' 'Объём видеопамяти НЕ соответствует модели' ("$memTotal МиБ вместо ~$expectedMem МиБ — возможна подделка")
        }
    } else {
        Add-Result 'FAIL' 'PCI Device ID НЕ из списка RTX 3080' ("10DE:$devId — очень похоже на перешитую подделку! Сверьте карту в GPU-Z.")
    }
} else {
    Add-Result 'WARN' 'Не удалось прочитать PCI Device ID' 'Проверьте карту вручную в GPU-Z (там есть детектор подделок).'
    if ($memTotal -and $memTotal -lt 9800) {
        Add-Result 'FAIL' 'Памяти меньше 10 ГБ' "$memTotal МиБ — это не RTX 3080"
    }
}

# ---------------------------------------------------------------------------
# 4. PCIe-подключение
# ---------------------------------------------------------------------------
Write-Section "4. Шина PCIe"

Write-Host "  Максимум: Gen$pcieGenMax x$pcieWMax, сейчас: x$pcieWCur"
$wCur = Parse-Num $pcieWCur
if ($wCur -ne $null -and $wCur -lt 16) {
    Add-Result 'WARN' "Ширина шины x$pcieWCur вместо x16" 'Возможно карта в неполноценном слоте этого ПК, либо повреждены контакты. x1 — типичный след райзера с майнинг-фермы.'
} else {
    Add-Result 'OK' 'Ширина шины PCIe x16' ''
}

# ---------------------------------------------------------------------------
# 5. Состояние в простое
# ---------------------------------------------------------------------------
Write-Section "5. Простой (idle)"

Write-Host "  Температура: $idleTemp °C, потребление: $idlePower Вт, вентиляторы: $idleFan %"
if ($idleTemp -ne $null) {
    if ($idleTemp -le 55) {
        Add-Result 'OK' "Температура в простое $idleTemp °C" ''
    } else {
        Add-Result 'WARN' "Высокая температура в простое: $idleTemp °C" 'Возможно высохшая термопаста/прокладки или карта только что была под нагрузкой.'
    }
}
if ($idlePower -ne $null -and $idlePower -gt 90) {
    Add-Result 'WARN' "Высокое потребление в простое: $idlePower Вт" 'Норма ~10–30 Вт. Проверьте, нет ли фоновой нагрузки (майнер?).'
}

# ---------------------------------------------------------------------------
# 6. Журнал Windows: ошибки видеодрайвера за последние 14 дней
#    (актуально, если карта уже стояла в этом ПК)
# ---------------------------------------------------------------------------
Write-Section "6. Журнал Windows (история сбоев драйвера)"

function Get-GpuErrors {
    param([datetime]$Since)
    $ev = @()
    try { $ev += Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='nvlddmkm'; StartTime=$Since } -ErrorAction Stop } catch {}
    try { $ev += Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Display'; Id=4101; StartTime=$Since } -ErrorAction Stop } catch {}
    return $ev
}

$histErrors = Get-GpuErrors -Since (Get-Date).AddDays(-14)
if ($histErrors.Count -gt 0) {
    $histErrors | Select-Object TimeCreated, ProviderName, Id, Message |
        Out-File -FilePath (Join-Path $LogDir 'event-log-history.txt') -Encoding utf8
    Add-Result 'WARN' "За 14 дней найдено сбоев видеодрайвера: $($histErrors.Count)" 'Если эта карта уже стояла в этом ПК — плохой знак. Подробности в logs\event-log-history.txt'
} else {
    Add-Result 'OK' 'Сбоев видеодрайвера за 14 дней не найдено' ''
}

# ---------------------------------------------------------------------------
# 7. Стресс-тест с мониторингом
# ---------------------------------------------------------------------------
$testStart = Get-Date

if (-not $SkipStress) {
    Write-Section "7. Стресс-тест ($StressMinutes мин)"

    # Ищем FurMark рядом со скриптом (на флешке)
    $furmark = Get-ChildItem -Path $Root -Recurse -Include 'furmark.exe','FurMark.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\logs_' } | Select-Object -First 1

    $stressProc = $null
    $durationSec = $StressMinutes * 60

    if ($furmark) {
        $isV2 = Test-Path (Join-Path $furmark.DirectoryName 'furmark-gui.exe')
        if ($isV2) {
            $fmArgs = "--demo furmark-gl --width 1280 --height 720 --max-time $($durationSec * 1000)"
        } else {
            $fmArgs = "/nogui /width=1280 /height=720 /msaa=0 /max_time=$($durationSec * 1000)"
        }
        Write-Host "  Запускаю FurMark: $($furmark.FullName)"
        Write-Host ""
        Write-Host "  >>> СМОТРИТЕ НА ЭКРАН: артефакты (цветные точки, полосы," -ForegroundColor Yellow
        Write-Host "  >>> мерцание, «снег») = дефектная память или чип!" -ForegroundColor Yellow
        Write-Host ""
        try {
            $stressProc = Start-Process -FilePath $furmark.FullName -ArgumentList $fmArgs -WorkingDirectory $furmark.DirectoryName -PassThru
        } catch {
            Add-Result 'WARN' 'Не удалось запустить FurMark' $_.Exception.Message
        }
    } else {
        Add-Result 'WARN' 'FurMark не найден на флешке' 'Мониторинг всё равно запустится — вручную запустите любой тяжёлый тест/игру в течение 15 секунд.'
        Write-Host "  FurMark не найден. Запустите нагрузку вручную (игра, бенчмарк) — мониторинг начнётся через 15 сек." -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    }

    # Мониторинг
    $samples = New-Object System.Collections.ArrayList
    $throttleThermal = $false
    $throttleHw = $false
    $powerCapSeen = $false
    $csvLog = Join-Path $LogDir 'stress-monitor.csv'
    'time,temp_c,power_w,clock_gr_mhz,clock_mem_mhz,fan_pct,util_pct,pcie_gen' | Out-File -FilePath $csvLog -Encoding utf8

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $earlyExit = $false
    while ($sw.Elapsed.TotalSeconds -lt $durationSec) {
        $line = (& $smi '--query-gpu=temperature.gpu,power.draw,clocks.gr,clocks.mem,fan.speed,utilization.gpu,pcie.link.gen.current' --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if ($line) {
            $s = ($line -split ',') | ForEach-Object { $_.Trim() }
            $sample = [pscustomobject]@{
                T      = $sw.Elapsed.TotalSeconds
                Temp   = Parse-Num $s[0]
                Power  = Parse-Num $s[1]
                Clock  = Parse-Num $s[2]
                MemClk = Parse-Num $s[3]
                Fan    = Parse-Num $s[4]
                Util   = Parse-Num $s[5]
                Gen    = $s[6]
            }
            [void]$samples.Add($sample)
            ('{0:N0},{1},{2},{3},{4},{5},{6},{7}' -f $sample.T,$s[0],$s[1],$s[2],$s[3],$s[4],$s[5],$s[6]) |
                Out-File -FilePath $csvLog -Append -Encoding utf8
        }

        $tl = (& $smi '--query-gpu=clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.sw_power_cap' --format=csv,noheader 2>$null | Select-Object -First 1)
        if ($tl) {
            $t = ($tl -split ',') | ForEach-Object { $_.Trim() }
            if ($t[0] -eq 'Active' -or $t[1] -eq 'Active') { $throttleThermal = $true }
            if ($t[2] -eq 'Active') { $throttleHw = $true }
            if ($t[3] -eq 'Active') { $powerCapSeen = $true }
        }

        # Прогресс раз в ~20 секунд
        if (($samples.Count % 10) -eq 1 -and $samples.Count -gt 1) {
            $last = $samples[$samples.Count - 1]
            Write-Host ("  [{0:N0}/{1} c] темп: {2}°C  частота: {3} МГц  мощность: {4} Вт  вент: {5}%  загрузка: {6}%" -f `
                $last.T, $durationSec, $last.Temp, $last.Clock, $last.Power, $last.Fan, $last.Util)
        }

        # FurMark умер раньше времени — вероятен сброс драйвера
        if ($stressProc -and $stressProc.HasExited -and $sw.Elapsed.TotalSeconds -lt ($durationSec - 20)) {
            $earlyExit = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    $sw.Stop()

    # Гасим FurMark, если ещё жив
    try {
        if ($stressProc -and -not $stressProc.HasExited) { $stressProc.Kill() }
        Get-Process -Name 'furmark*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {}

    # --- Анализ ---
    $loaded = @($samples | Where-Object { $_.Util -ne $null -and $_.Util -ge 85 })
    if ($earlyExit) {
        Add-Result 'FAIL' 'Стресс-тест завершился аварийно раньше времени' 'Вероятен сброс драйвера или вылет — карта нестабильна под нагрузкой.'
    }

    if ($loaded.Count -lt 5) {
        Add-Result 'WARN' 'Карта почти не была под нагрузкой во время мониторинга' 'Стресс-тест не запустился или шёл слишком мало. Результаты неполные.'
    } else {
        $maxTemp  = ($loaded | Measure-Object -Property Temp  -Maximum).Maximum
        $maxPower = ($loaded | Measure-Object -Property Power -Maximum).Maximum
        $maxFan   = ($loaded | Measure-Object -Property Fan   -Maximum).Maximum
        # Частоты считаем после прогрева (пропускаем первые 30 секунд нагрузки)
        $steady = @($loaded | Where-Object { $_.T -gt ($loaded[0].T + 30) })
        if ($steady.Count -eq 0) { $steady = $loaded }
        $avgClock = [Math]::Round(($steady | Measure-Object -Property Clock -Average).Average)

        Write-Host ""
        Write-Host "  Итоги нагрузки: макс. темп. $maxTemp °C, средняя частота $avgClock МГц, макс. мощность $maxPower Вт, макс. вентиляторы $maxFan %"

        if ($maxTemp -lt 80) {
            Add-Result 'OK' "Максимальная температура $maxTemp °C" 'Охлаждение в порядке.'
        } elseif ($maxTemp -le 88) {
            Add-Result 'WARN' "Температура под нагрузкой $maxTemp °C" 'Горячо. Скорее всего нужна замена термопасты/прокладок — повод для торга.'
        } else {
            Add-Result 'FAIL' "Температура под нагрузкой $maxTemp °C" 'Критически горячо, карта на грани аварийного троттлинга.'
        }

        if ($throttleThermal) {
            Add-Result 'FAIL' 'Зафиксирован ТЕРМИЧЕСКИЙ троттлинг' 'Карта сбрасывает частоты из-за перегрева. Обслуживание обязательно.'
        }
        if ($throttleHw) {
            Add-Result 'FAIL' 'Зафиксирован аппаратный сброс частот (HW Slowdown)' 'Возможны проблемы с питанием карты.'
        }
        if ($powerCapSeen) {
            Write-Host "  (Ограничение по мощности во время FurMark — это НОРМА, не дефект.)" -ForegroundColor DarkGray
        }

        if ($avgClock -lt 1000) {
            Add-Result 'WARN' "Низкая средняя частота под нагрузкой: $avgClock МГц" 'Для FurMark частоты ниже игровых — это норма, но меньше ~1000 МГц подозрительно. Прогоните игровой бенчмарк: там должно быть 1700+ МГц.'
        } else {
            Add-Result 'OK' "Средняя частота под нагрузкой $avgClock МГц" 'В FurMark частота всегда ниже игровой из-за лимита мощности — это нормально.'
        }

        $hotSamples = @($loaded | Where-Object { $_.Temp -ge 70 -and $_.Fan -ne $null -and $_.Fan -lt 10 })
        if ($hotSamples.Count -gt 3) {
            Add-Result 'FAIL' 'Вентиляторы не крутятся при температуре 70°C+' 'Похоже, вентиляторы неисправны.'
        }

        $genUnderLoad = ($loaded | Select-Object -Last 5 | ForEach-Object { $_.Gen }) | Select-Object -Last 1
        if ($genUnderLoad -and (Parse-Num $genUnderLoad) -ne $null -and (Parse-Num $genUnderLoad) -lt 3) {
            Add-Result 'WARN' "PCIe под нагрузкой: Gen$genUnderLoad" 'Ожидалось Gen3/Gen4. Возможно, дело в материнской плате этого ПК, но проверьте.'
        }
    }

    # Сбросы драйвера во время теста
    $testErrors = Get-GpuErrors -Since $testStart
    if ($testErrors.Count -gt 0) {
        $testErrors | Select-Object TimeCreated, ProviderName, Id, Message |
            Out-File -FilePath (Join-Path $LogDir 'event-log-during-test.txt') -Encoding utf8
        Add-Result 'FAIL' "Сбросы видеодрайвера ВО ВРЕМЯ теста: $($testErrors.Count)" 'Карта нестабильна под нагрузкой. Подробности в logs\event-log-during-test.txt'
    } else {
        Add-Result 'OK' 'Сбросов драйвера во время теста не было' ''
    }
}

# ---------------------------------------------------------------------------
# 8. Тест видеопамяти (memtest_vulkan)
# ---------------------------------------------------------------------------
if (-not $SkipVram) {
    Write-Section "8. Тест видеопамяти ($VramMinutes мин)"

    $mtv = Get-ChildItem -Path $Root -Recurse -Include 'memtest_vulkan*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\logs_' } | Select-Object -First 1

    if ($mtv) {
        $mtvOut = Join-Path $LogDir 'memtest_vulkan.log'
        Write-Host "  Запускаю $($mtv.Name) на $VramMinutes мин..."
        try {
            $mp = Start-Process -FilePath $mtv.FullName -WorkingDirectory $mtv.DirectoryName `
                -RedirectStandardOutput $mtvOut -PassThru -WindowStyle Hidden
            $deadline = (Get-Date).AddMinutes($VramMinutes)
            while ((Get-Date) -lt $deadline -and -not $mp.HasExited) { Start-Sleep -Seconds 5 }
            if (-not $mp.HasExited) { $mp.Kill() }
            Start-Sleep -Seconds 1

            $content = @()
            if (Test-Path $mtvOut) { $content = Get-Content $mtvOut -ErrorAction SilentlyContinue }
            $errLines = @($content | Where-Object { $_ -match '(?i)error' -and $_ -notmatch '(?i)(no|0)\s*errors?' })
            if ($errLines.Count -gt 0) {
                Add-Result 'FAIL' 'memtest_vulkan нашёл ОШИБКИ ВИДЕОПАМЯТИ' 'Память дефектная — карту брать нельзя. Подробности в logs\memtest_vulkan.log'
            } elseif ($content.Count -gt 3) {
                Add-Result 'OK' "Ошибок видеопамяти за $VramMinutes мин не найдено" 'Лог: logs\memtest_vulkan.log'
            } else {
                Add-Result 'WARN' 'Не удалось разобрать результат memtest_vulkan' 'Запустите memtest_vulkan.exe вручную и посмотрите вывод.'
            }
        } catch {
            Add-Result 'WARN' 'Не удалось запустить memtest_vulkan' $_.Exception.Message
        }
    } else {
        Add-Result 'WARN' 'memtest_vulkan не найден на флешке' 'Видеопамять не проверена! Скачайте memtest_vulkan (github.com/GpuZelenograd/memtest_vulkan) и положите рядом со скриптом.'
    }
}

# ---------------------------------------------------------------------------
# Итоги
# ---------------------------------------------------------------------------
Write-Section "ИТОГИ"

$fails = @($Results | Where-Object { $_.Status -eq 'FAIL' })
$warns = @($Results | Where-Object { $_.Status -eq 'WARN' })

foreach ($r in $Results) {
    $color = 'Green'
    if ($r.Status -eq 'WARN') { $color = 'Yellow' }
    if ($r.Status -eq 'FAIL') { $color = 'Red' }
    Write-Host ("  [{0,-4}] {1}" -f $r.Status, $r.Name) -ForegroundColor $color
}

Write-Host ""
if ($fails.Count -gt 0) {
    Write-Host  "############################################################" -ForegroundColor Red
    Write-Host ("#  ВЕРДИКТ: НЕ РЕКОМЕНДУЕТСЯ К ПОКУПКЕ ($($fails.Count) критич. проблем)") -ForegroundColor Red
    Write-Host  "############################################################" -ForegroundColor Red
} elseif ($warns.Count -gt 0) {
    Write-Host  "############################################################" -ForegroundColor Yellow
    Write-Host ("#  ВЕРДИКТ: ЕСТЬ ЗАМЕЧАНИЯ ($($warns.Count)) — проверьте их и торгуйтесь") -ForegroundColor Yellow
    Write-Host  "############################################################" -ForegroundColor Yellow
} else {
    Write-Host  "############################################################" -ForegroundColor Green
    Write-Host  "#  ВЕРДИКТ: серьёзных проблем не выявлено" -ForegroundColor Green
    Write-Host  "############################################################" -ForegroundColor Green
}

Write-Host ""
Write-Host "НЕ ЗАБУДЬТЕ проверить вручную (скрипт этого не видит):" -ForegroundColor Cyan
Write-Host "  1. GPU-Z -> Sensors во время нагрузки:"
Write-Host "     - Hot Spot: дельта с температурой GPU больше 25-30°C = плохой прижим/паста"
Write-Host "     - Memory Junction: выше 100°C под нагрузкой = убитые термопрокладки (частый след майнинга)"
Write-Host "  2. Артефакты на экране во время FurMark (точки, полосы, мерцание)"
Write-Host "  3. Внешний осмотр: сорванные шлицы винтов, пломбы, потемневший текстолит,"
Write-Host "     следы пайки, состояние разъёмов питания, люфт вентиляторов"
Write-Host "  4. Писк дросселей (coil whine) под нагрузкой"
Write-Host "  5. Если есть время — 10-15 минут игрового бенчмарка (частоты должны держаться 1700+ МГц)"
Write-Host ""
Write-Host "Полный отчёт сохранён: $LogDir" -ForegroundColor Cyan

try { Stop-Transcript | Out-Null } catch {}
Read-Host "Нажмите Enter для выхода"
