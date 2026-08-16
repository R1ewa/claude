# ============================================================================
#  Test-GPU.ps1 — универсальная проверка б/у видеокарты (NVIDIA / AMD / Intel)
#
#  Запуск: двойной клик по CHECK_GPU.bat (лежит рядом) или из PowerShell:
#      powershell -ExecutionPolicy Bypass -File .\Test-GPU.ps1
#
#  Параметры:
#      -StressMinutes N   длительность стресс-теста в минутах (по умолчанию 5)
#      -VramMinutes N     длительность теста видеопамяти в минутах (по умолчанию 4)
#      -SkipStress        пропустить стресс-тест
#      -SkipVram          пропустить тест видеопамяти
#
#  Что проверяет (для любой карты):
#      1. Карта определяется системой, драйвер установлен
#      2. Подлинность: PCI Device ID сверяется с базой популярных карт
#         (защита от «перешитых» подделок)
#      3. Объём видеопамяти (из реестра — работает для всех вендоров)
#      4. Ширина и поколение PCIe (следы райзеров/майнинг-ферм)
#      5. Журнал Windows: сбросы/ошибки видеодрайвера за последние 14 дней
#      6. Стресс-тест (FurMark, если лежит рядом на флешке) + контроль
#         вылетов и сбросов драйвера во время теста
#      7. Тест видеопамяти (memtest_vulkan, если лежит рядом) — все вендоры
#
#  Дополнительно для NVIDIA (через nvidia-smi):
#      температуры, частоты, потребление, вентиляторы, троттлинг.
#  Для AMD/Intel температуры смотрите в GPU-Z во время теста —
#  без стороннего софта Windows их не отдаёт.
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
Write-Host "#   УНИВЕРСАЛЬНАЯ ПРОВЕРКА Б/У ВИДЕОКАРТЫ                  #" -ForegroundColor Cyan
Write-Host "#   Логи сохраняются в: $LogDir" -ForegroundColor Cyan
Write-Host "############################################################" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# База PCI Device ID популярных карт.
# Match — регулярное выражение, которому ДОЛЖНО соответствовать название
# карты с этим Device ID. Несовпадение = перешитый BIOS/подделка.
# MemMiB — допустимые объёмы памяти для этого чипа (если указаны).
# В базе только ID, известные достоверно; отсутствие в базе — не приговор.
# ---------------------------------------------------------------------------
$GpuDb = @(
    # --- NVIDIA (VEN 10DE) ---
    @{ Vendor='10DE'; Dev='1C02'; Label='GTX 1060 3GB';        Match='1060';                MemMiB=@(3072) }
    @{ Vendor='10DE'; Dev='1C03'; Label='GTX 1060 6GB';        Match='1060';                MemMiB=@(6144) }
    @{ Vendor='10DE'; Dev='1B81'; Label='GTX 1070';            Match='1070';                MemMiB=@(8192) }
    @{ Vendor='10DE'; Dev='1B82'; Label='GTX 1070 Ti';         Match='1070';                MemMiB=@(8192) }
    @{ Vendor='10DE'; Dev='1B80'; Label='GTX 1080';            Match='1080';                MemMiB=@(8192) }
    @{ Vendor='10DE'; Dev='1B06'; Label='GTX 1080 Ti';         Match='1080';                MemMiB=@(11264) }
    @{ Vendor='10DE'; Dev='2184'; Label='GTX 1660';            Match='1660';                MemMiB=@(6144) }
    @{ Vendor='10DE'; Dev='2182'; Label='GTX 1660 Ti';         Match='1660';                MemMiB=@(6144) }
    @{ Vendor='10DE'; Dev='21C4'; Label='GTX 1660 SUPER';      Match='1660';                MemMiB=@(6144) }
    @{ Vendor='10DE'; Dev='1F08'; Label='RTX 2060';            Match='2060';                MemMiB=@(6144) }
    @{ Vendor='10DE'; Dev='1E84'; Label='RTX 2070 SUPER';      Match='2070';                MemMiB=@(8192) }
    @{ Vendor='10DE'; Dev='1E04'; Label='RTX 2080 Ti';         Match='2080';                MemMiB=@(11264) }
    @{ Vendor='10DE'; Dev='2503'; Label='RTX 3060';            Match='3060';                MemMiB=@(12288) }
    @{ Vendor='10DE'; Dev='2504'; Label='RTX 3060 LHR';        Match='3060';                MemMiB=@(12288) }
    @{ Vendor='10DE'; Dev='2486'; Label='RTX 3060 Ti';         Match='3060';                MemMiB=@(8192) }
    @{ Vendor='10DE'; Dev='2489'; Label='RTX 3060 Ti LHR';     Match='3060';                MemMiB=@(8192) }
    @{ Vendor='10DE'; Dev='2484'; Label='RTX 3070';            Match='3070';                MemMiB=@(8192) }
    @{ Vendor='10DE'; Dev='2488'; Label='RTX 3070 LHR';        Match='3070';                MemMiB=@(8192) }
    @{ Vendor='10DE'; Dev='2482'; Label='RTX 3070 Ti';         Match='3070';                MemMiB=@(8192) }
    @{ Vendor='10DE'; Dev='2206'; Label='RTX 3080 10GB';       Match='3080';                MemMiB=@(10240) }
    @{ Vendor='10DE'; Dev='2216'; Label='RTX 3080 10GB LHR';   Match='3080';                MemMiB=@(10240) }
    @{ Vendor='10DE'; Dev='220A'; Label='RTX 3080 12GB';       Match='3080';                MemMiB=@(12288) }
    @{ Vendor='10DE'; Dev='2208'; Label='RTX 3080 Ti';         Match='3080';                MemMiB=@(12288) }
    @{ Vendor='10DE'; Dev='2204'; Label='RTX 3090';            Match='3090';                MemMiB=@(24576) }
    @{ Vendor='10DE'; Dev='2786'; Label='RTX 4070';            Match='4070';                MemMiB=@(12288) }
    @{ Vendor='10DE'; Dev='2782'; Label='RTX 4070 Ti';         Match='4070';                MemMiB=@(12288) }
    @{ Vendor='10DE'; Dev='2704'; Label='RTX 4080';            Match='4080';                MemMiB=@(16384) }
    @{ Vendor='10DE'; Dev='2684'; Label='RTX 4090';            Match='4090';                MemMiB=@(24576) }
    # --- AMD (VEN 1002) — device ID часто общий для семейства ---
    @{ Vendor='1002'; Dev='67DF'; Label='Radeon RX 470/480/570/580/590'; Match='RX ?(4[78]0|5[789]0)'; MemMiB=@(4096,8192) }
    @{ Vendor='1002'; Dev='731F'; Label='Radeon RX 5600 XT/5700/5700 XT'; Match='RX ?5(6|7)00';        MemMiB=@(6144,8192) }
    @{ Vendor='1002'; Dev='73BF'; Label='Radeon RX 6800/6800 XT/6900 XT'; Match='RX ?6[89]00';         MemMiB=@(16384) }
    @{ Vendor='1002'; Dev='73DF'; Label='Radeon RX 6700 XT/6750 XT';      Match='RX ?67[05]0';         MemMiB=@(12288) }
    @{ Vendor='1002'; Dev='744C'; Label='Radeon RX 7900 XT/XTX/GRE';      Match='RX ?7900';            MemMiB=@(16384,20480,24576) }
)

$VendorNames = @{ '10DE' = 'NVIDIA'; '1002' = 'AMD'; '8086' = 'Intel' }

# ---------------------------------------------------------------------------
# 1. Поиск видеокарт в системе
# ---------------------------------------------------------------------------
Write-Section "1. Поиск видеокарт"

$controllers = @()
try {
    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object {
        $_.PNPDeviceID -match '^PCI\\VEN_' -and
        $_.Name -notmatch 'Basic Display|Basic Render|Remote|Virtual|Parsec|DisplayLink'
    })
} catch {}

if ($controllers.Count -eq 0) {
    Add-Result 'FAIL' 'Не найдено ни одной физической видеокарты' 'Карта не определяется системой либо нет драйвера. Проверьте Диспетчер устройств.'
    try { Stop-Transcript | Out-Null } catch {}
    Read-Host "Нажмите Enter для выхода"
    exit 1
}

for ($i = 0; $i -lt $controllers.Count; $i++) {
    Write-Host ("  [{0}] {1}  (драйвер {2})" -f $i, $controllers[$i].Name, $controllers[$i].DriverVersion)
}

$target = $controllers[0]
if ($controllers.Count -gt 1) {
    # Если есть дискретная NVIDIA/AMD — предложим её по умолчанию
    $defIdx = 0
    for ($i = 0; $i -lt $controllers.Count; $i++) {
        if ($controllers[$i].PNPDeviceID -match 'VEN_(10DE|1002)' -and $controllers[$i].Name -notmatch 'Graphics [0-9]|UHD|Iris|Vega [0-9]|Radeon\(TM\) Graphics') { $defIdx = $i; break }
    }
    $ans = Read-Host "Найдено несколько GPU. Номер проверяемой карты [$defIdx]"
    $ansNum = Parse-Num $ans
    if ($ansNum -ne $null -and $ansNum -ge 0 -and $ansNum -lt $controllers.Count) { $target = $controllers[[int]$ansNum] }
    else { $target = $controllers[$defIdx] }
}

$gpuName = $target.Name
$pnp = $target.PNPDeviceID
$venId = $null; $devId = $null
if ($pnp -match 'VEN_([0-9A-Fa-f]{4})') { $venId = $Matches[1].ToUpper() }
if ($pnp -match 'DEV_([0-9A-Fa-f]{4})') { $devId = $Matches[1].ToUpper() }
$vendorName = 'Неизвестный вендор'
if ($venId -and $VendorNames.ContainsKey($venId)) { $vendorName = $VendorNames[$venId] }
$isNvidia = ($venId -eq '10DE')

Write-Host ""
Write-Host "  Проверяем: $gpuName  [$vendorName, PCI ID $venId`:$devId]" -ForegroundColor White
Add-Result 'OK' 'Карта определяется системой' "$gpuName (драйвер $($target.DriverVersion))"

# ---------------------------------------------------------------------------
# 2. Объём видеопамяти (из реестра — надёжно для всех вендоров;
#    WMI AdapterRAM врёт на картах >4 ГБ)
# ---------------------------------------------------------------------------
Write-Section "2. Видеопамять"

function Get-RegistryVramMiB {
    param([string]$Ven, [string]$Dev)
    try {
        $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        $keys = Get-ChildItem $classKey -ErrorAction Stop | Where-Object { $_.PSChildName -match '^\d{4}$' }
        foreach ($k in $keys) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.MatchingDeviceId -and $p.MatchingDeviceId -match ("ven_" + $Ven + "&dev_" + $Dev)) {
                $q = $p.'HardwareInformation.qwMemorySize'
                if ($q) { return [Math]::Round($q / 1MB) }
            }
        }
    } catch {}
    return $null
}

$vramMiB = $null
if ($venId -and $devId) { $vramMiB = Get-RegistryVramMiB -Ven $venId -Dev $devId }
if ($vramMiB) {
    Write-Host ("  Объём видеопамяти: {0} МиБ (~{1} ГБ)" -f $vramMiB, [Math]::Round($vramMiB / 1024))
} else {
    Write-Host "  Не удалось прочитать объём из реестра."
}

# ---------------------------------------------------------------------------
# 3. Подлинность по PCI Device ID
#    Подделки — это старые карты с перешитым BIOS: название подменить легко,
#    а Device ID чипа — нет.
# ---------------------------------------------------------------------------
Write-Section "3. Подлинность (PCI Device ID)"

$dbEntry = $null
foreach ($e in $GpuDb) {
    if ($e.Vendor -eq $venId -and $e.Dev -eq $devId) { $dbEntry = $e; break }
}

if (-not $devId) {
    Add-Result 'WARN' 'Не удалось прочитать PCI Device ID' 'Проверьте карту в GPU-Z (там есть детектор подделок).'
} elseif ($dbEntry) {
    if ($gpuName -match $dbEntry.Match) {
        Add-Result 'OK' 'Чип соответствует названию карты' ("$venId`:$devId = " + $dbEntry.Label)
    } else {
        Add-Result 'FAIL' 'Название карты НЕ соответствует чипу!' ("Чип $venId`:$devId — это «$($dbEntry.Label)», а карта представляется как «$gpuName». Очень похоже на перешитую подделку.")
    }
    if ($dbEntry.MemMiB -and $vramMiB) {
        $memOk = $false
        foreach ($m in $dbEntry.MemMiB) { if ([Math]::Abs($vramMiB - $m) -le 400) { $memOk = $true } }
        if ($memOk) {
            Add-Result 'OK' 'Объём видеопамяти соответствует чипу' ("$vramMiB МиБ")
        } else {
            Add-Result 'FAIL' 'Объём видеопамяти НЕ соответствует чипу' ("$vramMiB МиБ, ожидалось: $($dbEntry.MemMiB -join ' или ') МиБ — признак подделки")
        }
    }
} else {
    Add-Result 'INFO' "PCI ID $venId`:$devId нет в базе скрипта" 'Это не приговор — просто сверьте модель в GPU-Z (детектор подделок) вручную.'
}

# ---------------------------------------------------------------------------
# 4. NVIDIA: телеметрия через nvidia-smi
# ---------------------------------------------------------------------------
$smi = $null
$smiSel = @()
if ($isNvidia) {
    Write-Section "4. Телеметрия NVIDIA (nvidia-smi)"

    $smiCandidates = @(
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
        (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )
    foreach ($p in $smiCandidates) { if (Test-Path $p) { $smi = $p; break } }
    if (-not $smi) {
        $w = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
        if ($w) { $smi = $w.Source }
    }

    if (-not $smi) {
        Add-Result 'WARN' 'nvidia-smi не найден' 'Драйвер NVIDIA не установлен? Телеметрия (температуры, троттлинг) будет недоступна.'
    } else {
        # Если карт NVIDIA несколько — уточним индекс
        $list = @(& $smi -L 2>$null)
        if ($list.Count -gt 1) {
            $list | ForEach-Object { Write-Host "  $_" }
            $ans = Read-Host "  Индекс NVIDIA-карты для nvidia-smi [0]"
            $ansNum = Parse-Num $ans
            if ($ansNum -ne $null -and $ansNum -ge 0) { $smiSel = @('-i', [int]$ansNum) } else { $smiSel = @('-i', 0) }
        }

        & $smi @smiSel -q | Out-File -FilePath (Join-Path $LogDir 'nvidia-smi-full.txt') -Encoding utf8

        $fields = 'name,driver_version,vbios_version,serial,memory.total,pcie.link.gen.max,pcie.link.width.max,pcie.link.width.current,temperature.gpu,power.draw,power.limit,power.max_limit,fan.speed'
        $raw = (& $smi @smiSel ("--query-gpu=" + $fields) --format=csv,noheader,nounits 2>&1 | Select-Object -First 1)

        if (-not $raw -or $raw -match 'NVIDIA-SMI has failed|No devices') {
            Add-Result 'WARN' 'nvidia-smi не видит GPU' ("Вывод: " + $raw)
            $smi = $null
        } else {
            $f = ($raw -split ',') | ForEach-Object { $_.Trim() }
            $vbios      = $f[2]
            $serial     = $f[3]
            $smiMem     = Parse-Num $f[4]
            $pcieGenMax = $f[5]
            $pcieWMax   = $f[6]
            $pcieWCur   = $f[7]
            $idleTemp   = Parse-Num $f[8]
            $idlePower  = Parse-Num $f[9]
            $powerLimit = Parse-Num $f[10]
            $powerMax   = Parse-Num $f[11]

            Write-Host "  VBIOS:          $vbios"
            Write-Host "  Серийный номер: $serial"
            Write-Host "  Память (smi):   $smiMem МиБ"
            Write-Host "  Лимит питания:  $powerLimit Вт (макс. $powerMax Вт)"
            Write-Host "  PCIe:           максимум Gen$pcieGenMax x$pcieWMax, сейчас x$pcieWCur"

            if (-not $vramMiB -and $smiMem) { $vramMiB = $smiMem }

            $wCur = Parse-Num $pcieWCur
            $wMax = Parse-Num $pcieWMax
            if ($wCur -ne $null -and $wMax -ne $null -and $wCur -lt $wMax) {
                Add-Result 'WARN' "Ширина шины x$pcieWCur вместо x$pcieWMax" 'Возможно неполноценный слот этого ПК либо повреждённые контакты. x1 — типичный след райзера с майнинг-фермы.'
            } elseif ($wCur -ne $null) {
                Add-Result 'OK' "Ширина шины PCIe x$pcieWCur" ''
            }

            if ($idleTemp -ne $null) {
                if ($idleTemp -le 55) {
                    Add-Result 'OK' "Температура в простое $idleTemp °C" ''
                } else {
                    Add-Result 'WARN' "Высокая температура в простое: $idleTemp °C" 'Возможно высохшая термопаста/прокладки, либо карта только что была под нагрузкой.'
                }
            }
            if ($idlePower -ne $null -and $idlePower -gt 90) {
                Add-Result 'WARN' "Высокое потребление в простое: $idlePower Вт" 'Норма ~10–30 Вт. Нет ли фоновой нагрузки (майнер?).'
            }
        }
    }
} else {
    Write-Section "4. Телеметрия"
    Write-Host "  Карта не NVIDIA: температуры и частоты без стороннего софта Windows не отдаёт." -ForegroundColor Yellow
    Write-Host "  Откройте GPU-Z -> Sensors и следите за температурами во время стресс-теста." -ForegroundColor Yellow
    Add-Result 'INFO' 'Телеметрия ограничена (не NVIDIA)' 'Температуры под нагрузкой смотрите в GPU-Z вручную.'
}

# ---------------------------------------------------------------------------
# 5. Журнал Windows: ошибки видеодрайвера за последние 14 дней
#    (актуально, если карта уже стояла в этом ПК)
# ---------------------------------------------------------------------------
Write-Section "5. Журнал Windows (история сбоев драйвера)"

function Get-GpuErrors {
    param([datetime]$Since)
    $ev = @()
    # nvlddmkm — NVIDIA; amdkmdag/atikmdag/amdwddmg — AMD; igfx/igfxn — Intel
    foreach ($prov in @('nvlddmkm', 'amdkmdag', 'atikmdag', 'amdwddmg', 'igfx', 'igfxn')) {
        try { $ev += Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName=$prov; StartTime=$Since } -ErrorAction Stop } catch {}
    }
    # TDR: «Видеодрайвер перестал отвечать и был восстановлен»
    try { $ev += Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Display'; Id=4101; StartTime=$Since } -ErrorAction Stop } catch {}
    return $ev
}

$histErrors = @(Get-GpuErrors -Since (Get-Date).AddDays(-14))
if ($histErrors.Count -gt 0) {
    $histErrors | Select-Object TimeCreated, ProviderName, Id, Message |
        Out-File -FilePath (Join-Path $LogDir 'event-log-history.txt') -Encoding utf8
    Add-Result 'WARN' "За 14 дней найдено сбоев видеодрайвера: $($histErrors.Count)" 'Если эта карта уже стояла в этом ПК — плохой знак. Подробности в logs\event-log-history.txt'
} else {
    Add-Result 'OK' 'Сбоев видеодрайвера за 14 дней не найдено' ''
}

# ---------------------------------------------------------------------------
# Загрузка GPU через счётчики Windows (работает для всех вендоров,
# может быть недоступна на некоторых системах)
# ---------------------------------------------------------------------------
function Get-GpuUtilPct {
    try {
        $c = Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop
        $sum = ($c.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum
        return [Math]::Min(100, [Math]::Round($sum))
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# 6. Стресс-тест с мониторингом
# ---------------------------------------------------------------------------
$testStart = Get-Date

if (-not $SkipStress) {
    Write-Section "6. Стресс-тест ($StressMinutes мин)"

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
        if (-not $isNvidia) {
            Write-Host "  >>> И держите открытым GPU-Z -> Sensors: температуры GPU/Hot Spot/памяти." -ForegroundColor Yellow
        }
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

    # --- Мониторинг ---
    $samples = New-Object System.Collections.ArrayList
    $throttleThermal = $false
    $throttleHw = $false
    $powerCapSeen = $false
    $csvLog = Join-Path $LogDir 'stress-monitor.csv'
    'time,temp_c,power_w,clock_gr_mhz,clock_mem_mhz,fan_pct,util_pct,pcie_gen' | Out-File -FilePath $csvLog -Encoding utf8

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $earlyExit = $false
    while ($sw.Elapsed.TotalSeconds -lt $durationSec) {
        $sample = $null
        if ($smi) {
            $line = (& $smi @smiSel '--query-gpu=temperature.gpu,power.draw,clocks.gr,clocks.mem,fan.speed,utilization.gpu,pcie.link.gen.current' --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
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
                ('{0:N0},{1},{2},{3},{4},{5},{6},{7}' -f $sample.T,$s[0],$s[1],$s[2],$s[3],$s[4],$s[5],$s[6]) |
                    Out-File -FilePath $csvLog -Append -Encoding utf8
            }

            $tl = (& $smi @smiSel '--query-gpu=clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.sw_power_cap' --format=csv,noheader 2>$null | Select-Object -First 1)
            if ($tl) {
                $t = ($tl -split ',') | ForEach-Object { $_.Trim() }
                if ($t[0] -eq 'Active' -or $t[1] -eq 'Active') { $throttleThermal = $true }
                if ($t[2] -eq 'Active') { $throttleHw = $true }
                if ($t[3] -eq 'Active') { $powerCapSeen = $true }
            }
        } else {
            # Универсальный путь: только загрузка GPU через счётчики Windows
            $util = Get-GpuUtilPct
            $sample = [pscustomobject]@{
                T = $sw.Elapsed.TotalSeconds; Temp = $null; Power = $null; Clock = $null
                MemClk = $null; Fan = $null; Util = $util; Gen = ''
            }
            ('{0:N0},,,,,,{1},' -f $sample.T, $util) | Out-File -FilePath $csvLog -Append -Encoding utf8
        }
        if ($sample) { [void]$samples.Add($sample) }

        # Прогресс раз в ~20 секунд
        if (($samples.Count % 10) -eq 1 -and $samples.Count -gt 1) {
            $last = $samples[$samples.Count - 1]
            if ($smi) {
                Write-Host ("  [{0:N0}/{1} c] темп: {2}°C  частота: {3} МГц  мощность: {4} Вт  вент: {5}%  загрузка: {6}%" -f `
                    $last.T, $durationSec, $last.Temp, $last.Clock, $last.Power, $last.Fan, $last.Util)
            } else {
                Write-Host ("  [{0:N0}/{1} c] загрузка GPU: {2}%  (температуры — в GPU-Z)" -f $last.T, $durationSec, $last.Util)
            }
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
    if ($earlyExit) {
        Add-Result 'FAIL' 'Стресс-тест завершился аварийно раньше времени' 'Вероятен сброс драйвера или вылет — карта нестабильна под нагрузкой.'
    }

    $loaded = @($samples | Where-Object { $_.Util -ne $null -and $_.Util -ge 85 })

    if ($smi) {
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

            Add-Result 'INFO' "Средняя частота под нагрузкой: $avgClock МГц" 'В FurMark частоты всегда ниже игровых из-за лимита мощности. В игровом бенчмарке частоты должны быть заметно выше.'

            $hotSamples = @($loaded | Where-Object { $_.Temp -ge 70 -and $_.Fan -ne $null -and $_.Fan -lt 10 })
            if ($hotSamples.Count -gt 3) {
                Add-Result 'FAIL' 'Вентиляторы не крутятся при температуре 70°C+' 'Похоже, вентиляторы неисправны.'
            }
        }
    } else {
        # Не-NVIDIA (или nvidia-smi недоступен)
        if ($loaded.Count -ge 5) {
            Add-Result 'OK' 'Карта держала нагрузку весь тест без вылетов' 'Температуры оцените по GPU-Z (см. чек-лист в конце).'
        } elseif ($samples.Count -gt 0 -and ($samples[0].Util -eq $null)) {
            Add-Result 'INFO' 'Счётчики загрузки GPU недоступны на этой системе' 'Ориентируйтесь на вылеты, сбросы драйвера и показания GPU-Z.'
            if (-not $earlyExit -and $stressProc) {
                Add-Result 'OK' 'Стресс-тест отработал без аварийного завершения' ''
            }
        } else {
            Add-Result 'WARN' 'Нагрузка на GPU не была зафиксирована' 'Стресс-тест не запустился? Результаты неполные.'
        }
    }

    # Сбросы драйвера во время теста
    $testErrors = @(Get-GpuErrors -Since $testStart)
    if ($testErrors.Count -gt 0) {
        $testErrors | Select-Object TimeCreated, ProviderName, Id, Message |
            Out-File -FilePath (Join-Path $LogDir 'event-log-during-test.txt') -Encoding utf8
        Add-Result 'FAIL' "Сбросы видеодрайвера ВО ВРЕМЯ теста: $($testErrors.Count)" 'Карта нестабильна под нагрузкой. Подробности в logs\event-log-during-test.txt'
    } else {
        Add-Result 'OK' 'Сбросов драйвера во время теста не было' ''
    }
}

# ---------------------------------------------------------------------------
# 7. Тест видеопамяти (memtest_vulkan — работает на любых картах с Vulkan)
# ---------------------------------------------------------------------------
if (-not $SkipVram) {
    Write-Section "7. Тест видеопамяти ($VramMinutes мин)"

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
    $color = 'Gray'
    if ($r.Status -eq 'OK')   { $color = 'Green' }
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
Write-Host "     - Memory Junction (есть не у всех карт): выше 100°C = убитые термопрокладки"
Write-Host "  2. GPU-Z -> главная вкладка: детектор подделок ругнётся сам ([FAKE] в названии)"
Write-Host "  3. Артефакты на экране во время FurMark (точки, полосы, мерцание)"
Write-Host "  4. Внешний осмотр: сорванные шлицы винтов, пломбы, потемневший текстолит,"
Write-Host "     следы пайки, состояние разъёмов питания, люфт вентиляторов"
Write-Host "  5. Писк дросселей (coil whine) под нагрузкой"
Write-Host "  6. Если есть время — 10-15 минут игрового бенчмарка: частоты должны быть"
Write-Host "     стабильно выше, чем в FurMark, без просадок и фризов"
Write-Host ""
Write-Host "Полный отчёт сохранён: $LogDir" -ForegroundColor Cyan

try { Stop-Transcript | Out-Null } catch {}
Read-Host "Нажмите Enter для выхода"
