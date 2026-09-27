#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Yes,
    [string]$LicenseName = "ckey.run",
    [string]$ExpiryDate  = "2099-12-31",
    [string[]]$VtApiKeys = @(),
    [string]$VtApiKey    = "",
    [switch]$SkipVtCheck
)

$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ============ Конфиг ============
$UrlBase     = "https://ckey.run"
$UrlDownload = "$UrlBase/ja-netfilter"
$UrlLicense  = "$UrlBase/generateLicense/file"

$UserHome      = $env:USERPROFILE
$DirWork       = Join-Path $UserHome ".jb_run"
$DirConfig     = Join-Path $DirWork "config"
$DirPlugins    = Join-Path $DirWork "plugins"
$DirBackups    = Join-Path $DirWork "backups"
$FileNetfilter = Join-Path $DirWork "ja-netfilter.jar"

$DirConfigJb   = Join-Path $env:APPDATA "JetBrains"

$VtBase       = "https://www.virustotal.com/api/v3"
$VtMaxKeys    = 50
$VtPerKeyGap  = 16   # сек между запросами одним ключом (free tier: 4/мин)
$script:VtKeyPool        = @()
$script:VtCurrentKeyIdx  = 0

$Products = @(
    [pscustomobject]@{ Name="idea";      Code="II,PCWMP,PSI" }
    [pscustomobject]@{ Name="clion";     Code="CL,PSI,PCWMP" }
    [pscustomobject]@{ Name="phpstorm";  Code="PS,PCWMP,PSI" }
    [pscustomobject]@{ Name="goland";    Code="GO,PSI,PCWMP" }
    [pscustomobject]@{ Name="pycharm";   Code="PC,PSI,PCWMP" }
    [pscustomobject]@{ Name="webstorm";  Code="WS,PCWMP,PSI" }
    [pscustomobject]@{ Name="rider";     Code="RD,PDB,PSI,PCWMP" }
    [pscustomobject]@{ Name="datagrip";  Code="DB,PSI,PDB" }
    [pscustomobject]@{ Name="rubymine";  Code="RM,PCWMP,PSI" }
    [pscustomobject]@{ Name="appcode";   Code="AC,PCWMP,PSI" }
    [pscustomobject]@{ Name="dataspell"; Code="DS,PSI,PDB,PCWMP" }
    [pscustomobject]@{ Name="rustrover"; Code="RR,PSI,PCWP" }
)

# ============ Лог ============
function Write-Log {
    param([string]$Level, [string]$Message)
    $color = switch ($Level) {
        "INFO"  { "Gray" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "OK"    { "Green" }
        default { "White" }
    }
    Write-Host ("[{0}][{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $color
}

function Short-Key { param([string]$K) if ($K.Length -ge 8) { return $K.Substring(0,8) } else { return $K } }

# ============ Пул VT-ключей ============
function Get-VtKeysFromFile {
    $localFile = Join-Path $PSScriptRoot "vtkeys.txt"
    if (Test-Path $localFile) {
        Write-Log INFO "VT: читаю ключи из $localFile"
        $lines = Get-Content -Path $localFile -ErrorAction Stop
        return @($lines | ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -and -not $_.StartsWith("#") })
    }
    $homeFile = Join-Path $UserHome ".vt_keys"
    if (Test-Path $homeFile) {
        Write-Log WARN "VT: vtkeys.txt не найден, читаю $homeFile"
        $lines = Get-Content -Path $homeFile -ErrorAction Stop
        return @($lines | ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -and -not $_.StartsWith("#") })
    }
    return @()
}

function Initialize-VtKeyPool {
    param([string[]]$Explicit = @())

    $keys = @()
    if ($Explicit -and $Explicit.Count -gt 0) {
        $keys = $Explicit
    } elseif ($env:VT_API_KEYS) {
        $keys = $env:VT_API_KEYS -split '[,;]'
    } elseif ($env:VT_API_KEY) {
        $keys = @($env:VT_API_KEY)
    } else {
        $keys = Get-VtKeysFromFile
    }

    $keys = @($keys | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

    if ($keys.Count -eq 0) {
        $script:VtKeyPool = @()
        return
    }
    if ($keys.Count -gt $VtMaxKeys) {
        Write-Log WARN "VT: получено $($keys.Count) ключей, обрезаю до $VtMaxKeys"
        $keys = $keys[0..($VtMaxKeys - 1)]
    }

    $script:VtKeyPool = @($keys | ForEach-Object {
        [pscustomobject]@{
            Key      = $_
            LastUsed = [DateTime]::MinValue
            Dead     = $false
        }
    })
    $script:VtCurrentKeyIdx = 0
    Write-Log INFO "VT: загружено ключей: $($script:VtKeyPool.Count) (макс. $VtMaxKeys)"
}

function Get-AliveKeyCount {
    if (-not $script:VtKeyPool) { return 0 }
    return @($script:VtKeyPool | Where-Object { -not $_.Dead }).Count
}

function Get-ReadyVtKey {
    $n = $script:VtKeyPool.Count
    if ($n -eq 0) { return $null }
    $now = [DateTime]::Now

    for ($i = 0; $i -lt $n; $i++) {
        $idx = ($script:VtCurrentKeyIdx + $i) % $n
        $k = $script:VtKeyPool[$idx]
        if ($k.Dead) { continue }
        if (($now - $k.LastUsed).TotalSeconds -ge $VtPerKeyGap) {
            $script:VtCurrentKeyIdx = $idx
            return $k
        }
    }

    $bestIdx = -1
    $bestTime = [DateTime]::MaxValue
    for ($i = 0; $i -lt $n; $i++) {
        $k = $script:VtKeyPool[$i]
        if ($k.Dead) { continue }
        if ($k.LastUsed -lt $bestTime) { $bestTime = $k.LastUsed; $bestIdx = $i }
    }
    if ($bestIdx -lt 0) { return $null }

    $wait = [math]::Ceiling($VtPerKeyGap - ($now - $bestTime).TotalSeconds)
    if ($wait -gt 0) {
        Write-Log INFO "  VT: все живые ключи в кулдауне, sleep ${wait}s"
        Start-Sleep -Seconds $wait
    }
    $script:VtCurrentKeyIdx = $bestIdx
    return $script:VtKeyPool[$bestIdx]
}

function Rotate-VtKey {
    param([string]$Reason)
    $n = $script:VtKeyPool.Count
    if ($n -le 1) { return }
    $start = ($script:VtCurrentKeyIdx + 1) % $n
    for ($i = 0; $i -lt $n; $i++) {
        $idx = ($start + $i) % $n
        if (-not $script:VtKeyPool[$idx].Dead) {
            $script:VtCurrentKeyIdx = $idx
            Write-Log WARN "  VT: переключение на ...$(Short-Key $script:VtKeyPool[$idx].Key) ($Reason)"
            return
        }
    }
}

function Mark-CurrentVtKeyDead {
    param([string]$Reason)
    if ($script:VtKeyPool.Count -eq 0) { return }
    $k = $script:VtKeyPool[$script:VtCurrentKeyIdx]
    if (-not $k.Dead) {
        $k.Dead = $true
        Write-Log WARN "  VT: ключ ...$(Short-Key $k.Key) помечен мёртвым ($Reason). Живых: $(Get-AliveKeyCount)"
    }
}

# ============ VT REST ============
function Invoke-VtRest {
    param(
        [string]$Method,
        [string]$Uri,
        $Body = $null,
        [string]$ContentType = $null
    )
    $maxAttempts = 12
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ((Get-AliveKeyCount) -eq 0) { throw "VT: все ключи исчерпаны" }
        $keyObj = Get-ReadyVtKey
        if (-not $keyObj) { throw "VT: нет доступных ключей" }
        $keyObj.LastUsed = [DateTime]::Now

        try {
            $args = @{
                Method          = $Method
                Uri             = $Uri
                Headers         = @{ "x-apikey" = $keyObj.Key }
                ErrorAction     = "Stop"
                UseBasicParsing = $true
            }
            if ($Body)        { $args.Body = $Body }
            if ($ContentType) { $args.ContentType = $ContentType }
            return Invoke-RestMethod @args
        } catch {
            $code = $null
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            switch ($code) {
                401 { Mark-CurrentVtKeyDead "401 invalid"; continue }
                403 { Mark-CurrentVtKeyDead "403 revoked"; continue }
                429 {
                    if ((Get-AliveKeyCount) -gt 1) {
                        Rotate-VtKey "429 rate limit"
                        continue
                    } else {
                        Write-Log INFO "  VT: единственный живой ключ в лимите, sleep 25s"
                        Start-Sleep -Seconds 25
                        continue
                    }
                }
                404 { throw $_ }  # пусть вызывающий обработает (файл не найден в базе)
                default {
                    if ($attempt -lt $maxAttempts) {
                        Write-Log WARN "  VT: HTTP $code, retry через 5s ($attempt/$maxAttempts)"
                        Start-Sleep -Seconds 5
                        continue
                    }
                    throw
                }
            }
        }
    }
    throw "VT: исчерпаны попытки ($maxAttempts)"
}

function Get-VtReportByHash {
    param([string]$Hash)
    try {
        return Invoke-VtRest -Method Get -Uri "$VtBase/files/$Hash"
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 404) { return $null }
        throw
    }
}

function Send-VtFile {
    param([string]$Path)
    Add-Type -AssemblyName System.Net.Http | Out-Null

    $maxAttempts = 12
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ((Get-AliveKeyCount) -eq 0) { throw "VT: все ключи исчерпаны" }
        $keyObj = Get-ReadyVtKey
        if (-not $keyObj) { throw "VT: нет доступных ключей" }
        $keyObj.LastUsed = [DateTime]::Now

        $client = New-Object System.Net.Http.HttpClient
        $client.DefaultRequestHeaders.Add("x-apikey", $keyObj.Key)
        try {
            $multipart = New-Object System.Net.Http.MultipartFormDataContent
            $fs = [System.IO.File]::OpenRead($Path)
            try {
                $fileContent = New-Object System.Net.Http.StreamContent($fs)
                $fileContent.Headers.ContentType =
                    [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
                $multipart.Add($fileContent, "file", (Split-Path $Path -Leaf))

                $resp = $client.PostAsync("$VtBase/files", $multipart).Result
                $text = $resp.Content.ReadAsStringAsync().Result
                $code = [int]$resp.StatusCode

                if ($code -eq 200 -or $code -eq 201) {
                    return ($text | ConvertFrom-Json)
                } elseif ($code -eq 401 -or $code -eq 403) {
                    Mark-CurrentVtKeyDead "$code on upload"
                    continue
                } elseif ($code -eq 429) {
                    if ((Get-AliveKeyCount) -gt 1) { Rotate-VtKey "429 upload"; continue }
                    else { Start-Sleep -Seconds 25; continue }
                } else {
                    if ($attempt -lt $maxAttempts) {
                        Write-Log WARN "  VT upload: HTTP $code, retry ($attempt/$maxAttempts)"
                        Start-Sleep -Seconds 5
                        continue
                    }
                    throw "VT upload failed: HTTP $code $text"
                }
            } finally { $fs.Dispose() }
        } finally { $client.Dispose() }
    }
    throw "VT upload: исчерпаны попытки"
}

function Wait-VtAnalysis {
    param([string]$AnalysisId, [int]$MaxWaitSec = 240)
    $start = [DateTime]::Now
    while (([DateTime]::Now - $start).TotalSeconds -lt $MaxWaitSec) {
        $a = Invoke-VtRest -Method Get -Uri "$VtBase/analyses/$AnalysisId"
        if ($a.data.attributes.status -eq "completed") { return $a }
        Write-Log INFO "  VT: анализ в процессе ($($a.data.attributes.status))"
        Start-Sleep -Seconds 15
    }
    throw "VT: таймаут анализа $AnalysisId"
}

function Test-VtFile {
    param([string]$Path)
    if ($SkipVtCheck) {
        Write-Log WARN "  SkipVtCheck: пропускаю VT"
        return
    }

    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    Write-Log INFO "  SHA256: $hash"

    $report = Get-VtReportByHash -Hash $hash
    if (-not $report) {
        Write-Log INFO "  Файла нет в базе VT, загружаю..."
        $upload = Send-VtFile -Path $Path
        $analysisId = $upload.data.id
        if (-not $analysisId) { throw "VT: upload не вернул analysis id" }
        $analysis = Wait-VtAnalysis -AnalysisId $analysisId
        $stats = $analysis.data.attributes.stats
    } else {
        $stats = $report.data.attributes.last_analysis_stats
    }

    $malicious  = [int]$stats.malicious
    $suspicious = [int]$stats.suspicious
    $harmless   = [int]$stats.harmless
    $undetected = [int]$stats.undetected
    $total      = $malicious + $suspicious + $harmless + $undetected

    if ($malicious -gt 0 -or $suspicious -gt 0) {
        throw "VirusTotal: $malicious malicious / $suspicious suspicious (из $total движков) в $Path"
    }
    Write-Log OK "  VT: чисто ($total движков, 0 malicious/suspicious)"
}

# ============ Скачивание ============
function Save-RemoteFile {
    param([string]$Url, [string]$Destination)

    Write-Log INFO "Downloading $Url"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "Download failed: $Url -> $($_.Exception.Message)"
    }

    if (-not (Test-Path $Destination) -or (Get-Item $Destination).Length -eq 0) {
        throw "Downloaded file is empty: $Destination"
    }

    if ($Destination -like "*.jar") {
        $fs = [System.IO.File]::OpenRead($Destination)
        try { $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte() } finally { $fs.Dispose() }
        if ($b0 -ne 0x50 -or $b1 -ne 0x4B) {
            throw "File is not a valid JAR (no PK magic): $Destination"
        }
    }

    Test-VtFile -Path $Destination
}

# ============ Бэкап ============
function Backup-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $stamp = Join-Path $DirBackups (Get-Date -Format "yyyyMMdd_HHmmss")
    if (-not (Test-Path $stamp)) { New-Item -ItemType Directory -Path $stamp -Force | Out-Null }
    Copy-Item -Path $Path -Destination (Join-Path $stamp (Split-Path $Path -Leaf)) -Force
    Write-Log INFO "  Backup: $Path -> $stamp"
}

# ============ vmoptions ============
function Get-VmOptionsFiles {
    param([string]$ConfigProductDir)
    Get-ChildItem -Path $ConfigProductDir -Filter "*.vmoptions" -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName -Unique
}

function Clean-VmOptions {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $keywords = @(
        "-javaagent",
        "--add-opens=java.base/jdk.internal.org.objectweb.asm.tree=ALL-UNNAMED",
        "--add-opens=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED"
    )
    $lines = Get-Content -Path $Path -ErrorAction SilentlyContinue
    if (-not $lines) { Set-Content -Path $Path -Value "" -Encoding ASCII; return }
    $kept = foreach ($line in $lines) {
        $hit = $false
        foreach ($kw in $keywords) { if ($line -like "*$kw*") { $hit = $true; break } }
        if (-not $hit) { $line }
    }
    Set-Content -Path $Path -Value $kept -Encoding ASCII
}

function Add-VmOptionsLine {
    param([string]$Path, [string]$Line)
    Add-Content -Path $Path -Value $Line -Encoding ASCII
}

# ============ Лицензия ============
function Request-LicenseKey {
    param([string]$ProductName, [string]$ProductCode, [string]$ProductDir)
    $licenseFile = Join-Path $ProductDir "$ProductName.key"
    if (Test-Path $licenseFile) { Remove-Item $licenseFile -Force }

    $body = @{
        assigneeName = ""
        expiryDate   = $ExpiryDate
        licenseName  = $LicenseName
        productCode  = $ProductCode
    } | ConvertTo-Json -Compress

    try {
        Invoke-RestMethod -Uri $UrlLicense -Method Post `
            -ContentType "application/json" -Body $body -OutFile $licenseFile -ErrorAction Stop
        if ((Test-Path $licenseFile) -and (Get-Item $licenseFile).Length -gt 0) {
            Write-Log OK "  License saved: $licenseFile"
        } else {
            Write-Log WARN "  Server returned empty license for $ProductName"
        }
    } catch {
        Write-Log WARN "  License request failed for ${ProductName}: $($_.Exception.Message)"
    }
}

# ============ Патч продукта ============
function Get-ProductInfo {
    param([string]$DirName)
    $lower = $DirName.ToLower()
    foreach ($p in $Products) { if ($lower -like "*$($p.Name)*") { return $p } }
    return $null
}

function Invoke-ProductPatch {
    param([string]$ProductDir)

    $dirName = Split-Path $ProductDir -Leaf
    $info = Get-ProductInfo -DirName $dirName
    if (-not $info) { return }

    Write-Log INFO "Processing: $dirName"

    $vmFiles = Get-VmOptionsFiles -ConfigProductDir $ProductDir
    if (-not $vmFiles -or $vmFiles.Count -eq 0) {
        $default = Join-Path $ProductDir "$($info.Name)64.exe.vmoptions"
        Write-Log INFO "  Нет .vmoptions, создаю $default"
        New-Item -ItemType File -Path $default -Force | Out-Null
        $vmFiles = @($default)
    }

    foreach ($f in $vmFiles) {
        Backup-File -Path $f
        Clean-VmOptions -Path $f
        Add-VmOptionsLine -Path $f -Line "-javaagent:$FileNetfilter"
        Write-Log INFO "  Updated $f"
    }

    $disabled = Join-Path $ProductDir "disabled_plugins.txt"
    if (Test-Path $disabled) {
        Backup-File -Path $disabled
        $content  = Get-Content $disabled -ErrorAction SilentlyContinue
        $filtered = $content | Where-Object { $_ -ne "com.intellij.modules.ultimate" }
        Set-Content -Path $disabled -Value $filtered -Encoding ASCII
        Write-Log INFO "  Cleaned disabled_plugins.txt"
    }

    Request-LicenseKey -ProductName $info.Name -ProductCode $info.Code -ProductDir $ProductDir
}

# ============ Main ============
function Main {
    Clear-Host
    Write-Host ""
    Write-Host "  JetBrains Activation (Windows) + VirusTotal key pool" -ForegroundColor Cyan
    Write-Host "  =====================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Log WARN "Рабочая папка:  $DirWork"
    Write-Log WARN "Папка бэкапов:  $DirBackups"
    Write-Log WARN "Папка IDE:      $DirConfigJb"

    # Инициализация пула ключей
    $explicit = @()
    if ($VtApiKey)    { $explicit += $VtApiKey }
    if ($VtApiKeys)   { $explicit += $VtApiKeys }
    Initialize-VtKeyPool -Explicit $explicit

    if ($SkipVtCheck) {
        Write-Log WARN "VirusTotal: ОТКЛЮЧЁН (-SkipVtCheck)"
    } elseif ((Get-AliveKeyCount) -gt 0) {
        Write-Log INFO "VirusTotal: включён, живых ключей: $(Get-AliveKeyCount)"
    } else {
        Write-Log ERROR "VirusTotal: ключи не найдены."
        Write-Log ERROR "  Положите vtkeys.txt рядом со скриптом (один ключ на строку),"
        Write-Log ERROR "  либо задайте -VtApiKeys, \$env:VT_API_KEYS, \$env:VT_API_KEY."
        Write-Log ERROR "  Либо запустите с -SkipVtCheck, если проверка не нужна."
        return
    }
    Write-Host ""

    if (-not $Yes) {
        $answer = Read-Host "Закройте все JetBrains IDE. Введите 'yes' для продолжения"
        if ($answer -ne "yes") { Write-Log INFO "Отменено."; return }

        $ln = Read-Host "Имя лицензии [$LicenseName]"
        if ($ln) { $LicenseName = $ln }

        $ed = Read-Host "Дата окончания yyyy-MM-dd [$ExpiryDate]"
        if ($ed) {
            if ($ed -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Log ERROR "Неверный формат даты: $ed"; return }
            $ExpiryDate = $ed
        }
    }

    if (-not (Test-Path $DirConfigJb)) {
        Write-Log ERROR "Не найдена папка: $DirConfigJb"
        Write-Log ERROR "Установите и запустите хотя бы одну JetBrains IDE."
        return
    }

    foreach ($d in @($DirConfig, $DirPlugins, $DirBackups)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    Write-Log INFO "Скачиваю ресурсы и проверяю через VirusTotal..."
    if (-not $SkipVtCheck) {
        $alive = Get-AliveKeyCount
        if ($alive -gt 0) {
            $throughput = [math]::Floor($alive * 60 / $VtPerKeyGap)
            Write-Log INFO "  Ключей: $alive, теоретический потолок ≈ $throughput запросов/мин"
        }
    }

    $resources = @(
        @{ Url="$UrlDownload/ja-netfilter.jar";    Path=$FileNetfilter }
        @{ Url="$UrlDownload/config/dns.conf";     Path=(Join-Path $DirConfig "dns.conf") }
        @{ Url="$UrlDownload/config/env.conf";     Path=(Join-Path $DirConfig "env.conf") }
        @{ Url="$UrlDownload/config/native.conf";  Path=(Join-Path $DirConfig "native.conf") }
        @{ Url="$UrlDownload/config/power.conf";   Path=(Join-Path $DirConfig "power.conf") }
        @{ Url="$UrlDownload/config/url.conf";     Path=(Join-Path $DirConfig "url.conf") }
        @{ Url="$UrlDownload/plugins/dns.jar";     Path=(Join-Path $DirPlugins "dns.jar") }
        @{ Url="$UrlDownload/plugins/env.jar";     Path=(Join-Path $DirPlugins "env.jar") }
        @{ Url="$UrlDownload/plugins/native.jar";  Path=(Join-Path $DirPlugins "native.jar") }
        @{ Url="$UrlDownload/plugins/power.jar";   Path=(Join-Path $DirPlugins "power.jar") }
        @{ Url="$UrlDownload/plugins/url.jar";     Path=(Join-Path $DirPlugins "url.jar") }
        @{ Url="$UrlDownload/plugins/hideme.jar";  Path=(Join-Path $DirPlugins "hideme.jar") }
        @{ Url="$UrlDownload/plugins/privacy.jar"; Path=(Join-Path $DirPlugins "privacy.jar") }
    )

    foreach ($r in $resources) {
        try {
            Save-RemoteFile -Url $r.Url -Destination $r.Path
        } catch {
            Write-Log ERROR "STOP: $($_.Exception.Message)"
            Write-Log ERROR "Файл не принят. Дальше не иду."
            if ((Get-AliveKeyCount) -eq 0 -and -not $SkipVtCheck) {
                Write-Log ERROR "Все VT-ключи мертвы."
            }
            return
        }
    }
    Write-Log OK "Все ресурсы скачаны и проверены."
    if (-not $SkipVtCheck) {
        Write-Log INFO "VT-ключей осталось живых: $(Get-AliveKeyCount)"
    }

    $productDirs = Get-ChildItem -Path $DirConfigJb -Directory -ErrorAction SilentlyContinue
    if (-not $productDirs) { Write-Log WARN "Не найдено ни одного продукта JetBrains."; return }

    foreach ($pd in $productDirs) {
        try { Invoke-ProductPatch -ProductDir $pd.FullName }
        catch { Write-Log ERROR "Ошибка обработки $($pd.Name): $($_.Exception.Message)" }
    }

    Write-Log OK "Готово. Бэкапы: $DirBackups"
    if (-not $Yes) { Start-Process $UrlBase }
}

Main
