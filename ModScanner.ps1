[CmdletBinding()]
param(
    [int]$MaxJarSizeMB    = 50,
    [int]$MaxReportSizeMB = 500
)

function Write-Info  ($m) { Write-Host "[i] $m" -ForegroundColor Cyan }
function Write-Ok    ($m) { Write-Host "[+] $m" -ForegroundColor Cyan }
function Write-Warn2 ($m) { Write-Host "[!] $m" -ForegroundColor Cyan }
function Write-Err   ($m) { Write-Host "[x] $m" -ForegroundColor Cyan }
function Write-Line  ($m) { Write-Host $m       -ForegroundColor Cyan }

function Format-Size ($bytes) {
    if ($bytes -ge 1MB) { return ("{0:N2} МБ" -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ("{0:N2} КБ" -f ($bytes / 1KB)) }
    return "$bytes Б"
}

function Format-Time ($sec) {
    if ($sec -lt 60) { return ("{0:N0} сек" -f $sec) }
    if ($sec -lt 3600) { return ("{0:N0} мин {1:N0} сек" -f [math]::Floor($sec/60), ($sec % 60)) }
    return ("{0:N0} ч {1:N0} мин" -f [math]::Floor($sec/3600), [math]::Floor(($sec % 3600)/60))
}

function Get-ShortDir {
    param([string]$Root, [int]$MaxLen = 200)
    if ($Root.Length -le $MaxLen) { return $Root }
    $root = [System.IO.Path]::GetPathRoot($Root)
    $rest = $Root.Substring($root.Length)
    $hash = [System.Security.Cryptography.SHA1]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($rest))
    $h = -join ($hash[0..3] | ForEach-Object { $_.ToString("X2") })
    return (Join-Path $root "_d_$h")
}

Clear-Host
Write-Line "=========================================================="
Write-Line "     MINECRAFT MOD BEHAVIOR ANALYZER v3.4                "
Write-Line "                  by 976hk                               "
Write-Line "=========================================================="
Write-Line ""
Write-Line "Лимиты:"
Write-Line "  JAR > $MaxJarSizeMB МБ          -> пропускается"
Write-Line "  Отчёт > $MaxReportSizeMB МБ     -> остановка"
Write-Line ""

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Write-Ok "Права администратора: есть." }
else          { Write-Warn2 "Права администратора: нет." }

Write-Line ""

do {
    $inputPath = Read-Host "Путь к JAR или папке"
    $inputPath = $inputPath.Trim('"').Trim("'").Trim()
    if ([string]::IsNullOrWhiteSpace($inputPath)) { Write-Err "Пустой путь."; continue }
    if (-not (Test-Path -LiteralPath $inputPath)) { Write-Err "Не найдено: $inputPath"; continue }
    break
} while ($true)

$isFolderMode = (Get-Item -LiteralPath $inputPath).PSIsContainer
$jarList = @()

if ($isFolderMode) {
    Write-Info "Сканирую папку на .jar..."
    $jarList = Get-ChildItem -LiteralPath $inputPath -Recurse -File -Filter *.jar | Sort-Object FullName
    if ($jarList.Count -eq 0) { Write-Err "JAR-файлов не найдено."; Read-Host "Enter..."; exit 1 }
    Write-Ok "Найдено JAR: $($jarList.Count)"
} else {
    if ([System.IO.Path]::GetExtension($inputPath).ToLower() -ne ".jar") {
        Write-Warn2 "Расширение не .jar, продолжаю..."
    }
    $jarList = @(Get-Item -LiteralPath $inputPath)
    Write-Ok "Файл: $($jarList[0].FullName)"
}

$maxJarBytes = $MaxJarSizeMB * 1MB
$skippedBySize = New-Object System.Collections.Generic.List[object]
$acceptedJars  = New-Object System.Collections.Generic.List[object]

foreach ($j in $jarList) {
    if ($j.Length -gt $maxJarBytes) { $skippedBySize.Add($j) }
    else { $acceptedJars.Add($j) }
}

if ($skippedBySize.Count -gt 0) {
    Write-Line ""
    Write-Warn2 "Пропущено из-за размера (> $MaxJarSizeMB МБ): $($skippedBySize.Count)"
    foreach ($s in $skippedBySize) {
        Write-Line ("    - {0}  ({1})" -f $s.Name, (Format-Size $s.Length))
    }
    Write-Line ""
}

if ($acceptedJars.Count -eq 0) {
    Write-Err "Нечего обрабатывать. Попробуй -MaxJarSizeMB 200"
    Read-Host "Enter..."; exit 1
}

$jarList = $acceptedJars
Write-Ok "К обработке: $($jarList.Count) JAR"

$stamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$workRoot = Join-Path $env:TEMP "ModAnalyze_$stamp"
$cfrDir   = Join-Path $env:LOCALAPPDATA "ModAnalyzer\cfr"
$cfrJar   = Join-Path $cfrDir "cfr.jar"
$outFile  = Join-Path ([Environment]::GetFolderPath("Desktop")) ("MOD_ANALYSIS_$stamp.txt")

New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
New-Item -ItemType Directory -Path $cfrDir   -Force | Out-Null

Write-Info "Рабочая папка: $workRoot"
Write-Info "Отчёт: $outFile"
Write-Line ""

function Get-JavaPath {
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java) { return $java.Source }
    $candidates = @(
        "$env:ProgramFiles\Java",
        "$env:ProgramFiles\Eclipse Adoptium",
        "${env:ProgramFiles(x86)}\Java",
        "$env:LOCALAPPDATA\Programs\Eclipse Adoptium"
    )
    foreach ($base in $candidates) {
        if (Test-Path $base) {
            $found = Get-ChildItem -Path $base -Recurse -Filter java.exe -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    return $null
}

$javaPath = Get-JavaPath
if ($javaPath) { Write-Ok "Java: $javaPath" }
else           { Write-Warn2 "Java НЕ найдена. Декомпиляция отключена." }

$cfrReady = $false
if ($javaPath) {
    if (Test-Path $cfrJar) {
        Write-Ok "CFR в кэше."
        $cfrReady = $true
    } else {
        Write-Info "Скачиваю CFR..."
        try {
            Invoke-WebRequest -Uri "https://repo1.maven.org/maven2/org/benf/cfr/0.152/cfr-0.152.jar" `
                              -OutFile $cfrJar -UseBasicParsing -TimeoutSec 60
            Write-Ok "CFR скачан."
            $cfrReady = $true
        } catch { Write-Err "Ошибка загрузки CFR: $($_.Exception.Message)" }
    }
}

function Expand-JarSafe {
    param([string]$JarPath, [string]$DestDir)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $rel  = $entry.FullName -replace '/','\'
            if ($rel.Length -gt 180) {
                $ext = [System.IO.Path]::GetExtension($rel)
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($rel)
                $shortBase = if ($baseName.Length -gt 60) { $baseName.Substring(0,60) } else { $baseName }
                $hashBytes = [System.Security.Cryptography.SHA1]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($rel))
                $h = -join ($hashBytes[0..3] | ForEach-Object { $_.ToString("X2") })
                $rel = "long_${shortBase}_$h$ext"
            }
            $dest = Join-Path $DestDir $rel
            $dir  = [System.IO.Path]::GetDirectoryName($dest)
            if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            try {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
            } catch { }
        }
    } finally { $zip.Dispose() }
}

function Get-ClassStringLines {
    param([string]$Path, [int]$MinLen = 4)
    $result = New-Object System.Collections.Generic.List[string]
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $bufSize = 65536
            $buf = New-Object byte[] $bufSize
            $cur = New-Object System.Collections.Generic.List[byte]
            $read = 0
            while (($read = $fs.Read($buf, 0, $bufSize)) -gt 0) {
                for ($i = 0; $i -lt $read; $i++) {
                    $b = $buf[$i]
                    if ($b -ge 32 -and $b -le 126) { $cur.Add($b) }
                    else {
                        if ($cur.Count -ge $MinLen) {
                            $result.Add([System.Text.Encoding]::ASCII.GetString($cur.ToArray()))
                        }
                        $cur.Clear()
                    }
                }
            }
            if ($cur.Count -ge $MinLen) {
                $result.Add([System.Text.Encoding]::ASCII.GetString($cur.ToArray()))
            }
        } finally { $fs.Dispose() }
    } catch { }
    return $result
}

$patterns = @(
    @{Name="События Forge";        Regex='@SubscribeEvent|net\.minecraftforge\.event|EventBus|register\(.*Event'},
    @{Name="Инициализация Fabric"; Regex='onInitialize|ClientModInitializer|DedicatedServerModInitializer|ModInitializer'},
    @{Name="Команды";              Regex='CommandRegistrationCallback|RegisterCommandsEvent|CommandDispatcher|literal\(|argument\('},
    @{Name="Регистрация блоков";   Regex='BlockRegistry|registerBlock|DeferredRegister.*BLOCK|BLOCKS\.register'},
    @{Name="Регистрация предметов";Regex='ItemRegistry|registerItem|DeferredRegister.*ITEM|ITEMS\.register'},
    @{Name="Регистрация сущностей";Regex='EntityType|registerEntity|ENTITY_TYPES\.register'},
    @{Name="Миксины";              Regex='@Mixin|MixinConfig|mixins\.json|org\.spongepowered\.asm\.mixin'},
    @{Name="Сеть / пакеты";        Regex='Packet|NetworkHandler|SimpleChannel|ServerPlayNetHandler|sendToServer|sendToPlayer'},
    @{Name="GUI / экраны";         Regex='Screen|ContainerScreen|MenuType|GuiScreen|openScreen'},
    @{Name="Рендер";               Regex='RenderType|RenderSystem|VertexConsumer|ModelPart|draw'},
    @{Name="Конфиги";              Regex='Config|Configuration|Properties|loadConfig|saveConfig'},
    @{Name="Файловый ввод-вывод";  Regex='java\.io\.File|Files\.|FileInputStream|FileOutputStream|FileWriter|Path\.of'},
    @{Name="HTTP / веб-запросы";   Regex='HttpURLConnection|URLConnection|OkHttp|HttpClient|java\.net\.URL|openStream'},
    @{Name="Сокеты";               Regex='java\.net\.Socket|ServerSocket|DatagramSocket'},
    @{Name="Потоки";               Regex='new Thread|ExecutorService|CompletableFuture|ScheduledExecutor'},
    @{Name="Рефлексия";            Regex='java\.lang\.reflect|Class\.forName|getDeclaredMethod|setAccessible'},
    @{Name="Runtime.exec / Process";Regex='Runtime\.getRuntime|ProcessBuilder|\.exec\('},
    @{Name="Крипто / кошельки";    Regex='bitcoin|wallet|ethereum|monero|xmr|stratum|mining|miner'},
    @{Name="Запуск авторизации";   Regex='getSession|accessToken|refreshToken|session\.getToken'},
    @{Name="Чтение буфера обмена"; Regex='Clipboard|Toolkit\.getDefaultToolkit|getSystemClipboard'}
)

$suspiciousPatterns = @(
    @{Name="!!! Майнер крипты";        Regex='stratum\+tcp|xmrig|minerd|coinhive|cryptonight|monero.*pool|nicehash'},
    @{Name="!!! Кража токена сессии";  Regex='getAccessToken|refreshToken|session\.getToken\(\)|MinecraftSessionService'},
    @{Name="!!! Скриншоты экрана";     Regex='Robot\(\)\.createScreenCapture|getScreenCapture|screenshot'},
    @{Name="!!! Кейлоггер";            Regex='GlobalKeyListener|addKeyListener|KeyEventDispatcher|nativeHook'},
    @{Name="!!! Запуск .exe/.bat";     Regex='Runtime\.getRuntime\(\)\.exec|ProcessBuilder|startProcess'},
    @{Name="!!! Скачивание файлов";    Regex='openConnection\(\)|openStream\(\)|downloadFile|saveToDisk'},
    @{Name="!!! Чтение паролей";       Regex='password|credentials|LoginData|keychain|\.ssh|id_rsa'},
    @{Name="!!! Скрытая сеть";         Regex='\.onion|pastebin\.com|discord.*webhook|telegram.*bot|api\.telegram'},
    @{Name="!!! Обфускация/шифрование";Regex='AES|DES|Base64\.decode|XOR.*key|decrypt.*payload|ClassLoader.*defineClass'}
)

$compiledPatterns = $patterns | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Rx = [regex]::new($_.Regex, 'Compiled') }
}
$compiledSuspicious = $suspiciousPatterns | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Rx = [regex]::new($_.Regex, 'Compiled, IgnoreCase') }
}

function Get-BehaviorReport {
    param([string]$Root)
    $behavior = [ordered]@{}
    foreach ($p in $patterns) { $behavior[$p.Name] = New-Object System.Collections.Generic.HashSet[string] }
    $suspicious = New-Object System.Collections.Generic.List[string]

    $classFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.class -ErrorAction SilentlyContinue
    $javaFiles  = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.java  -ErrorAction SilentlyContinue
    $scanFiles  = @($classFiles) + @($javaFiles)
    $total = $scanFiles.Count
    $i = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($f in $scanFiles) {
        $i++
        if ($i % 50 -eq 0 -or $i -eq $total) {
            $elapsed = $sw.Elapsed.TotalSeconds
            $rate = if ($i -gt 0 -and $elapsed -gt 0) { $i / $elapsed } else { 0 }
            $eta  = if ($rate -gt 0) { ($total - $i) / $rate } else { 0 }
            Write-Progress -Activity "Анализ поведения" `
                -Status "Файл $i / $total  |  ETA: $(Format-Time $eta)  |  $([math]::Round($rate,1)) файл/сек" `
                -PercentComplete (($i / $total) * 100)
        }
        try {
            if ($f.Extension -eq ".java") {
                $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            } else {
                $lines = Get-ClassStringLines -Path $f.FullName -MinLen 4
                $text  = [string]::Join("`n", $lines)
            }
            if ([string]::IsNullOrEmpty($text)) { continue }
            $rel = $f.FullName.Substring($Root.Length).TrimStart('\','/')

            foreach ($cp in $compiledPatterns) {
                if ($cp.Rx.IsMatch($text)) { [void]$behavior[$cp.Name].Add($rel) }
            }
            foreach ($cp in $compiledSuspicious) {
                if ($cp.Rx.IsMatch($text)) {
                    $suspicious.Add("$($cp.Name) :: $rel")
                }
            }
        } catch { }
    }
    Write-Progress -Activity "Анализ поведения" -Completed
    return @{ Behavior = $behavior; Suspicious = $suspicious }
}

function Get-ModMetadata {
    param([string]$Root)
    $meta = New-Object System.Collections.Generic.List[string]
    $possible = @("fabric.mod.json","quilt.mod.json","META-INF/mods.toml",
                  "META-INF/MANIFEST.MF","mcmod.info","META-INF/neoforge.mods.toml")
    foreach ($p in $possible) {
        $full = Join-Path $Root $p
        if (Test-Path -LiteralPath $full) {
            $meta.Add("### $p")
            $meta.Add((Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue))
            $meta.Add("")
        }
    }
    return $meta
}

function Get-MixinInfo {
    param([string]$Root)
    $mixins = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.mixins.json -ErrorAction SilentlyContinue
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($m in $mixins) {
        $result.Add("### $($m.Name)")
        $result.Add((Get-Content -LiteralPath $m.FullName -Raw -ErrorAction SilentlyContinue))
        $result.Add("")
    }
    return $result
}

function Get-JavaFilesSafe {
    param([string]$Root)
    $result = New-Object System.Collections.Generic.List[object]
    try {
        $dirs = New-Object System.Collections.Generic.Stack[string]
        $dirs.Push($Root)
        while ($dirs.Count -gt 0) {
            $cur = $dirs.Pop()
            try {
                foreach ($sub in [System.IO.Directory]::GetDirectories($cur)) {
                    $dirs.Push($sub)
                }
                foreach ($f in [System.IO.Directory]::GetFiles($cur, "*.java")) {
                    $result.Add([System.IO.FileInfo]::new($f))
                }
            } catch { }
        }
    } catch { }
    return $result
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$writer = New-Object System.IO.StreamWriter($outFile, $false, $utf8NoBom)
$writer.AutoFlush = $false

function W($line) { $script:writer.WriteLine($line) }

$maxReportBytes = $MaxReportSizeMB * 1MB
$script:reportAborted = $false

function Test-ReportLimit {
    if ($script:writer.BaseStream.Length -ge $script:maxReportBytes) {
        Write-Err "Отчёт превысил $MaxReportSizeMB МБ. Останавливаюсь."
        $script:reportAborted = $true
        return $true
    }
    return $false
}

W "================================================================"
W "     АНАЛИЗ ПОВЕДЕНИЯ MINECRAFT-МОДА"
W "                  by 976hk"
W "================================================================"
W "Дата анализа : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
W "Источник     : $inputPath"
W "Режим        : $(if ($isFolderMode) { 'ПАПКА (рекурсивно)' } else { 'ОДИН JAR' })"
W "JAR найдено  : $($jarList.Count + $skippedBySize.Count)"
W "JAR принято  : $($jarList.Count)"
W "JAR пропущено: $($skippedBySize.Count) (лимит $MaxJarSizeMB МБ)"
W "Лимит отчёта : $MaxReportSizeMB МБ"
W "Java         : $(if ($javaPath) { $javaPath } else { 'НЕ НАЙДЕНА' })"
W "CFR          : $(if ($cfrReady) { 'готов' } else { 'не готов' })"
W "================================================================"
W ""
if ($skippedBySize.Count -gt 0) {
    W "Пропущенные JAR (> $MaxJarSizeMB МБ):"
    foreach ($s in $skippedBySize) {
        W ("  - {0}  ({1})" -f $s.FullName, (Format-Size $s.Length))
    }
    W ""
}

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add("================================================================")
$summaryLines.Add("  РАЗДЕЛ 1. СВОДКА ПО МОДАМ")
$summaryLines.Add("================================================================")
$summaryLines.Add("")

$jarIndex = 0
$jarResults = @()
$globalSw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($jarItem in $jarList) {
    if ($reportAborted) { break }
    $jarIndex++
    Write-Line ""
    Write-Line "=========================================================="
    Write-Line "[$jarIndex/$($jarList.Count)] $($jarItem.Name)"
    Write-Line "   Размер: $(Format-Size $jarItem.Length)"
    Write-Line "=========================================================="

    $extractDir = Get-ShortDir -Root (Join-Path $workRoot ("jar_$jarIndex"))
    $decompDir  = Get-ShortDir -Root (Join-Path $workRoot ("decomp_$jarIndex"))

    $extractOk = $false
    try {
        Expand-JarSafe -JarPath $jarItem.FullName -DestDir $extractDir
        $extractOk = $true
        Write-Ok "Распакован."
    } catch {
        Write-Err "Ошибка распаковки: $($_.Exception.Message)"
    }

    $decompOk = $false
    if ($cfrReady) {
        Write-Info "Декомпилирую (CFR)..."
        New-Item -ItemType Directory -Path $decompDir -Force | Out-Null
        $cfrSw = [System.Diagnostics.Stopwatch]::StartNew()

        $classCount = 0
        if ($extractOk) {
            try {
                $classCount = (Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter *.class -ErrorAction SilentlyContinue).Count
            } catch { }
        }
        Write-Info "  .class файлов: $classCount"

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $javaPath
            $psi.Arguments = "-jar `"$cfrJar`" `"$($jarItem.FullName)`" --outputdir `"$decompDir`" --silent true"
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)

            $lastCheck = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $proc.HasExited) {
                Start-Sleep -Milliseconds 400
                if ($lastCheck.Elapsed.TotalSeconds -ge 1) {
                    $lastCheck.Restart()
                    $sec = $cfrSw.Elapsed.TotalSeconds
                    Write-Progress -Activity "CFR декомпилирует $($jarItem.Name)" `
                        -Status "Прошло: $(Format-Time $sec)  |  .class: $classCount" `
                        -PercentComplete (-1)
                }
            }
            $proc.WaitForExit()
            Write-Progress -Activity "CFR декомпилирует $($jarItem.Name)" -Completed

            $cfrSw.Stop()
            $javaOut = Get-JavaFilesSafe -Root $decompDir
            if ($javaOut.Count -gt 0) {
                $decompOk = $true
                Write-Ok "  CFR: $($javaOut.Count) .java за $(Format-Time $cfrSw.Elapsed.TotalSeconds)."
            } else {
                Write-Warn2 "  CFR не создал .java за $(Format-Time $cfrSw.Elapsed.TotalSeconds)."
            }
        } catch {
            Write-Err "  Ошибка CFR: $($_.Exception.Message)"
        }
    }

    Write-Info "Анализирую поведение..."
    $analysisRoot = if ($decompOk) { $decompDir } elseif ($extractOk) { $extractDir } else { $null }
    if ($analysisRoot) {
        $report = Get-BehaviorReport -Root $analysisRoot
    } else {
        $empty = [ordered]@{}
        foreach ($p in $patterns) { $empty[$p.Name] = New-Object System.Collections.Generic.HashSet[string] }
        $report = @{ Behavior = $empty; Suspicious = (New-Object System.Collections.Generic.List[string]) }
    }

    $meta   = if ($extractOk) { Get-ModMetadata -Root $extractDir } else { @() }
    $mixins = if ($extractOk) { Get-MixinInfo   -Root $extractDir } else { @() }

    $jarResults += [pscustomobject]@{
        Jar = $jarItem; ExtractDir = $extractDir
        DecompDir = if ($decompOk) { $decompDir } else { $null }
        Ok = $extractOk
        Behavior = $report.Behavior; Suspicious = $report.Suspicious
        Meta = $meta; Mixins = $mixins
    }

    $summaryLines.Add("### $($jarIndex). $($jarItem.Name)")
    $summaryLines.Add("   Путь   : $($jarItem.FullName)")
    $summaryLines.Add("   Размер : $(Format-Size $jarItem.Length)")
    $summaryLines.Add("   Код    : $(if ($decompOk) { 'декомпилирован (.java)' } else { 'только байт-код' })")
    $nonEmpty = @()
    foreach ($k in $report.Behavior.Keys) {
        if ($report.Behavior[$k].Count -gt 0) { $nonEmpty += "$k ($($report.Behavior[$k].Count))" }
    }
    $summaryLines.Add("   Делает : " + ($(if ($nonEmpty.Count) { ($nonEmpty -join ', ') } else { 'явных признаков не найдено' })))
    if ($report.Suspicious.Count -gt 0) {
        $summaryLines.Add("   !!! ПОДОЗРИТЕЛЬНО: $($report.Suspicious.Count) совпадений")
    } else {
        $summaryLines.Add("   Подозрительное: не найдено")
    }
    $summaryLines.Add("")
}

foreach ($l in $summaryLines) {
    if (Test-ReportLimit) { break }
    W $l
}

if (-not $reportAborted) {
    W ""
    W "================================================================"
    W "  РАЗДЕЛ 2. ПОДРОБНЫЙ АНАЛИЗ"
    W "================================================================"

    $jarIndex = 0
    foreach ($r in $jarResults) {
        if (Test-ReportLimit) { break }
        $jarIndex++
        $jar = $r.Jar
        W ""
        W "################################################################"
        W "##  JAR [$jarIndex]: $($jar.Name)"
        W "##  Путь   : $($jar.FullName)"
        W "##  Размер : $(Format-Size $jar.Length)"
        W "##  Изменён: $($jar.LastWriteTime)"
        W "################################################################"
        W ""

        if (-not $r.Ok) {
            W "<НЕ УДАЛОСЬ РАСПАКОВАТЬ>"
            continue
        }

        W "========== 2.1 МЕТАДАННЫЕ =========="
        if ($r.Meta.Count -gt 0) { foreach ($m in $r.Meta) { W $m } }
        else { W "(не найдены)" }
        W ""

        W "========== 2.2 МИКСИНЫ =========="
        if ($r.Mixins.Count -gt 0) { foreach ($m in $r.Mixins) { W $m } }
        else { W "(миксинов нет)" }
        W ""

        W "========== 2.3 ПОВЕДЕНИЕ =========="
        foreach ($k in $r.Behavior.Keys) {
            if (Test-ReportLimit) { break }
            $set = $r.Behavior[$k]
            if ($set.Count -eq 0) { continue }
            W ""
            W "--- $k  [совпадений: $($set.Count)] ---"
            foreach ($item in ($set | Sort-Object)) { W "    $item" }
        }
        W ""

        W "========== 2.4 ПОДОЗРИТЕЛЬНЫЕ НАХОДКИ =========="
        if ($r.Suspicious.Count -eq 0) {
            W "Не найдено. Мод выглядит безопасно."
        } else {
            W "ВНИМАНИЕ! Возможные угрозы:"
            W ""
            foreach ($s in ($r.Suspicious | Sort-Object -Unique)) { W "  $s" }
        }
        W ""

        W "========== 2.5 КОД МОДА =========="
        if ($r.DecompDir) {
            $javaFiles = Get-JavaFilesSafe -Root $r.DecompDir | Sort-Object FullName
            W "Всего .java: $($javaFiles.Count)"
            W ""
            $jj = 0
            $totalJ = $javaFiles.Count
            $swJ = [System.Diagnostics.Stopwatch]::StartNew()
            foreach ($jf in $javaFiles) {
                if (Test-ReportLimit) { break }
                $jj++
                if ($jj % 20 -eq 0 -or $jj -eq $totalJ) {
                    $rate = if ($swJ.Elapsed.TotalSeconds -gt 0) { $jj / $swJ.Elapsed.TotalSeconds } else { 0 }
                    $eta  = if ($rate -gt 0) { ($totalJ - $jj) / $rate } else { 0 }
                    Write-Progress -Activity "Запись кода в отчёт ($($jar.Name))" `
                        -Status "$jj / $totalJ  |  ETA: $(Format-Time $eta)" `
                        -PercentComplete (($jj / $totalJ) * 100)
                }
                $rel = $jf.FullName.Substring($r.DecompDir.Length).TrimStart('\','/')
                W "----- $rel -----"
                try { W (Get-Content -LiteralPath $jf.FullName -Raw -ErrorAction Stop) }
                catch { W "<ошибка чтения>" }
                W ""
            }
            Write-Progress -Activity "Запись кода в отчёт ($($jar.Name))" -Completed
        } else {
            $classFiles = Get-ChildItem -LiteralPath $r.ExtractDir -Recurse -File -Filter *.class -ErrorAction SilentlyContinue |
                          Sort-Object FullName
            W "Декомпиляция недоступна. Читаемые строки из .class:"
            W "Всего .class: $($classFiles.Count)"
            W ""
            $cj = 0
            $totalC = $classFiles.Count
            foreach ($cf in $classFiles) {
                if (Test-ReportLimit) { break }
                $cj++
                if ($cj % 20 -eq 0 -or $cj -eq $totalC) {
                    Write-Progress -Activity "Запись байт-кода ($($jar.Name))" `
                        -Status "$cj / $totalC" `
                        -PercentComplete (($cj / $totalC) * 100)
                }
                $rel = $cf.FullName.Substring($r.ExtractDir.Length).TrimStart('\','/')
                W "----- $rel -----"
                try {
                    $lines = Get-ClassStringLines -Path $cf.FullName -MinLen 4
                    foreach ($ln in $lines) { W $ln }
                } catch { W "<ошибка чтения>" }
                W ""
            }
            Write-Progress -Activity "Запись байт-кода ($($jar.Name))" -Completed
        }
    }
}

$globalSw.Stop()
$sizeNow = [math]::Round($writer.BaseStream.Length / 1MB, 2)
W ""
W "================================================================"
W "                     КОНЕЦ ОТЧЁТА"
W "                     by 976hk"
W "================================================================"
if ($reportAborted) {
    W "!!! ОТЧЁТ ОБРЕЗАН: превышен лимит $MaxReportSizeMB МБ"
    W "    Обработано JAR: $($jarResults.Count) из $($jarList.Count)"
}
W "Всего JAR найдено    : $($jarList.Count + $skippedBySize.Count)"
W "JAR обработано       : $($jarResults.Count)"
W "JAR пропущено (размер): $($skippedBySize.Count)"
W "Декомпилировано      : $(($jarResults | Where-Object { $_.DecompDir }).Count)"
W "С подозрениями       : $(($jarResults | Where-Object { $_.Suspicious.Count -gt 0 }).Count)"
W "Общее время          : $(Format-Time $globalSw.Elapsed.TotalSeconds)"
W "Размер отчёта        : $sizeNow МБ"
W "Отчёт                : $outFile"
W "================================================================"

$writer.Flush()
$writer.Close()

Write-Line ""
Write-Ok "ГОТОВО за $(Format-Time $globalSw.Elapsed.TotalSeconds)!"
Write-Line "Отчёт: $outFile  ($sizeNow МБ)"

if ($reportAborted) {
    Write-Warn2 "Отчёт обрезан. Увеличь: -MaxReportSizeMB 1000"
}

$openAns = Read-Host "Открыть отчёт сейчас? (Y/n)"
if ($openAns -notmatch '^[NnНн]$') {
    try {
        if ($sizeNow -gt 100) {
            Write-Warn2 "Отчёт большой ($sizeNow МБ). Открываю через notepad.exe..."
            Start-Process "notepad.exe" -ArgumentList "`"$outFile`""
        } else {
            Start-Process $outFile
            Write-Ok "Отчёт открыт в программе по умолчанию."
        }
    } catch {
        Write-Err "Не удалось открыть: $($_.Exception.Message)"
        Write-Line "Открой вручную: $outFile"
    }
}

$ans = Read-Host "Удалить временные файлы? (y/N)"
if ($ans -match '^[YyДд]$') {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Удалено."
}

Write-Line ""
Read-Host "Нажмите Enter для выхода"
