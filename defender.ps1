<#
  DiscordAntiStealer - self-contained PowerShell defender (Python'suz).
  Gercek-zamanli calistirma korumasi: yeni surec basladiginda komut satirini +
  calistirilan script'i (.bat vb.) analiz eder, saldiri NIYETINI siniflandirir,
  tehlikeliyse surec agacini oldurur + kaynagi karantinaya alir. Indirme = sadece
  uyari. Savunma amaclidir; saldiri yapmaz.

  Kullanim:
    powershell -ExecutionPolicy Bypass -File defender.ps1 -Action install      (YONETICI: gorevi kurar + baslatir)
    powershell -ExecutionPolicy Bypass -File defender.ps1 -Action monitor       (gercek-zamanli koruma)
    ...                                       -Action check                     (tek seferlik tarama)
    ...                                       -Action show    -Name <ad>         (karantinadaki kodu goster)
    ...                                       -Action restore -Name <ad>         (geri yukle)
    ...                                       -Action uninstall / -Action status
#>
[CmdletBinding()]
param(
    [ValidateSet('install','uninstall','status','monitor','check','show','restore','scan')]
    [string]$Action = 'monitor',
    [string]$Name,
    [string]$Path,
    [switch]$AlertOnly,
    [switch]$NoPopup
)

$ErrorActionPreference = 'Continue'
$TASK = 'DiscordAntiStealer'
$BASE = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$SELF = $PSCommandPath
$LOGDIR = Join-Path $BASE 'logs'
$QDIR   = Join-Path $BASE 'quarantine'
$REPDIR = Join-Path $BASE 'reports'
$ALLOW  = Join-Path $BASE 'allowlist.txt'
$EVTLOG = Join-Path $LOGDIR 'events.log'
$DETLOG = Join-Path $LOGDIR 'detections.jsonl'
$null = New-Item -ItemType Directory -Force -Path $LOGDIR, $QDIR, $REPDIR -ErrorAction SilentlyContinue

$MAXBYTES = 3MB
$SCRIPT_EXTS = 'bat|cmd|ps1|psm1|vbs|vbe|js|jse|wsf|hta|py|jar|scr'

# ---------------- signatures: command / script INTENT ----------------
$RULES = @(
    @{re='vssadmin(\.exe)?\s+delete\s+shadows'; w=45; i='ransomware'; l='golge kopyalari siliyor (vssadmin)'; lethal=$true}
    @{re='wmic\s+shadowcopy\s+delete'; w=45; i='ransomware'; l='golge kopyalari siliyor (wmic)'; lethal=$true}
    @{re='bcdedit.*recoveryenabled\s+no'; w=40; i='ransomware'; l='Windows kurtarmayi kapatiyor'; lethal=$true}
    @{re='wbadmin\s+delete\s+(catalog|systemstatebackup|backup)'; w=35; i='ransomware'; l='yedekleri siliyor (wbadmin)'; lethal=$true}
    @{re='\bcipher\s+/w'; w=22; i='ransomware'; l='bos alani siliyor (cipher /w)'; lethal=$false}
    @{re='New-Object\s+System\.Net\.Sockets\.TCPClient'; w=38; i='rat'; l='PowerShell ters kabuk'; lethal=$true}
    @{re='/dev/tcp/\d'; w=35; i='rat'; l='ters kabuk (/dev/tcp)'; lethal=$true}
    @{re='\b(nc|ncat|netcat)(\.exe)?\b[^\r\n]{0,300}\s-e\b'; w=38; i='rat'; l='netcat ters kabuk (-e)'; lethal=$true}
    @{re='\b(njrat|quasar|asyncrat|remcos|nanocore|darkcomet|venomrat|warzone|orcus|netwire|cobalt\s*strike|meterpreter|powercat)\b'; w=42; i='rat'; l='bilinen RAT/saldiri araci'; lethal=$true}
    @{re='Invoke-(Shellcode|Mimikatz|DllInjection|ReflectivePEInjection)'; w=40; i='rat'; l='saldiri (PowerSploit) modulu'; lethal=$true}
    @{re='\bmimikatz\b'; w=40; i='rat'; l='kimlik bilgisi calma araci'; lethal=$true}
    @{re='certutil(\.exe)?[^\r\n]{0,300}-urlcache[^\r\n]{0,300}-f[^\r\n]{0,300}https?'; w=35; i='downloader'; l='certutil ile indiriyor'; lethal=$true}
    @{re='bitsadmin[^\r\n]{0,300}/transfer'; w=28; i='downloader'; l='bitsadmin ile indiriyor'; lethal=$false}
    @{re='(DownloadString|DownloadFile|DownloadData)\s*\('; w=25; i='downloader'; l='internetten indiriyor'; lethal=$false}
    @{re='Net\.WebClient'; w=15; i='downloader'; l='WebClient kullaniyor'; lethal=$false}
    @{re='\bmshta(\.exe)?\s+https?://'; w=35; i='downloader'; l='mshta ile uzak kod calistiriyor'; lethal=$true}
    @{re='rundll32[^\r\n]{0,300}javascript:'; w=35; i='downloader'; l='rundll32 javascript:'; lethal=$true}
    @{re='regsvr32[^\r\n]{0,300}/i:https?'; w=35; i='downloader'; l='regsvr32 squiblydoo'; lethal=$true}
    @{re='(IEX|Invoke-Expression)\b[^\r\n]{0,300}(DownloadString|DownloadData|Net\.WebClient|https?://)'; w=40; i='downloader'; l='indir-ve-calistir tek satiri'; lethal=$true}
    @{re='Set-MpPreference[^\r\n]{0,300}-DisableRealtimeMonitoring[^\r\n]{0,300}(\$true|1|true)'; w=45; i='defense_evasion'; l='Defender korumayi kapatiyor'; lethal=$true}
    @{re='Add-MpPreference[^\r\n]{0,300}-ExclusionPath'; w=33; i='defense_evasion'; l='Defender istisnasi ekliyor'; lethal=$false}
    @{re='\bsc\b[^\r\n]{0,300}\b(stop|config|delete)\b[^\r\n]{0,300}WinDefend'; w=40; i='defense_evasion'; l='Defender servisini durduruyor'; lethal=$true}
    @{re='netsh\s+advfirewall\s+set[^\r\n]{0,300}\boff\b'; w=30; i='defense_evasion'; l='guvenlik duvarini kapatiyor'; lethal=$false}
    @{re='reg\s+add[^\r\n]{0,300}EnableLUA[^\r\n]{0,300}/d\s+0'; w=35; i='defense_evasion'; l='UAC kapatiyor'; lethal=$true}
    @{re='powershell[^\r\n]{0,300}\s-(enc|encodedcommand)\b'; w=30; i='defense_evasion'; l='gizli/base64 PowerShell komutu'; lethal=$false}
    @{re='powershell[^\r\n]{0,300}\s-(w|windowstyle)\s+hidden'; w=16; i='defense_evasion'; l='gizli pencerede PowerShell'; lethal=$false}
    @{re='net\s+localgroup\s+administrators?\s+\S+\s+/add'; w=35; i='privilege'; l='yonetici grubuna ekliyor'; lethal=$true}
    @{re='net\s+user\s+\S+\s+\S+\s+/add'; w=25; i='privilege'; l='yeni kullanici olusturuyor'; lethal=$false}
    @{re='reg\s+add[^\r\n]{0,300}\\(Run|RunOnce)\b'; w=20; i='persistence'; l='Run anahtarina ekliyor'; lethal=$false}
    @{re='schtasks[^\r\n]{0,300}/create'; w=16; i='persistence'; l='zamanlanmis gorev olusturuyor'; lethal=$false}
    @{re='GetAsyncKeyState'; w=28; i='infostealer'; l='tus kaydi (keylogger) API'; lethal=$false}
    @{re='SetWindowsHookEx[^\r\n]{0,300}WH_KEYBOARD'; w=32; i='infostealer'; l='klavye kancasi (keylogger)'; lethal=$true}
    @{re='\bxmrig\b'; w=42; i='cryptominer'; l='Monero madencisi (xmrig)'; lethal=$true}
    @{re='stratum\+(tcp|ssl)://'; w=42; i='cryptominer'; l='madencilik havuzu (stratum)'; lethal=$true}
    @{re='--donate-level'; w=30; i='cryptominer'; l='madenci bagis parametresi'; lethal=$false}
    @{re='\b(nanopool|supportxmr|minexmr|minergate|nicehash|moneroocean)\b'; w=30; i='cryptominer'; l='bilinen madencilik havuzu'; lethal=$false}
    @{re='\b(PRIVMSG|JOIN)\s+#\S+'; w=22; i='botnet'; l='IRC bot komut kanali'; lethal=$false}
)
# stealer IOC keywords (all map to infostealer intent)
$IOC = @(
    @{re='Local Storage\\\\?leveldb'; w=12; l='discord token deposu'}
    @{re='/api/v\d+/users/@me'; w=10; l='discord kimlik ucu'}
    @{re='dQw4w9WgXcQ'; w=30; l='grabber/token isareti'}
    @{re='\bmfa\.[A-Za-z0-9_\-]{50,}'; w=22; l='sifreli MFA token'}
    @{re='Login Data'; w=8; l='chrome login db'}
    @{re='os_crypt'; w=10; l='chrome ana anahtar'}
    @{re='cookies\.sqlite'; w=8; l='firefox cookies'}
    @{re='wallet\.dat'; w=12; l='bitcoin cuzdan'}
    @{re='token[\s_]*grabber'; w=35; l='self-id: token grabber'}
    @{re='\bstealer\b'; w=25; l='self-id: stealer'}
    @{re='\bnitro[\s_]*gen'; w=25; l='self-id: nitro generator'}
    @{re='grab[_ ]?tokens?\b'; w=22; l='self-id: grab tokens'}
)
$WEBHOOK_RE  = 'https?://(canary\.|ptb\.)?discord(app)?\.com/api/(v\d+/)?webhooks/\d+/[A-Za-z0-9_\-]{40,}'
$TELEGRAM_RE = 'https?://api\.telegram\.org/bot\d+:[A-Za-z0-9_\-]{30,}/send\w+'
$TOKEN_THEFT_LABELS = @('discord token deposu','discord kimlik ucu','grabber/token isareti','sifreli MFA token')
$INTENT_SUMMARY = @{
    infostealer='Sifre/veri calma (tarayici sifreleri, Discord token, kripto cuzdan, tus kaydi).'
    ransomware='Fidye yazilimi - dosyalari sifreleyip yedek/golge kopyalari silme.'
    rat='Uzaktan kontrol (RAT) - saldirgana uzaktan komut / ters kabuk.'
    cryptominer='Izinsiz kripto madenciligi - islemcini saldirgan icin kullanma.'
    botnet='Botnete dahil etme - uzaktan komuta edilen aga katma.'
    downloader='Indirici/dropper - internetten ek zararli indirip calistirma.'
    persistence='Kalicilik - her acilista otomatik calisma.'
    privilege='Yetki yukseltme / izinsiz yonetici hesabi.'
    defense_evasion='Savunmayi atlatma - AV/guvenlik duvarini kapatma, gizlenme.'
}
$CRITICAL = @('system','registry','memory compression','smss.exe','csrss.exe','wininit.exe',
    'winlogon.exe','services.exe','lsass.exe','lsaiso.exe','svchost.exe','fontdrvhost.exe',
    'dwm.exe','explorer.exe','spoolsv.exe','taskhostw.exe','sihost.exe','ctfmon.exe',
    'runtimebroker.exe','conhost.exe','dllhost.exe','searchindexer.exe')

# ---------------- engine ----------------
function Read-Text([string]$p) {
    try {
        $fi = Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if ($fi.PSIsContainer -or $fi.Length -eq 0) { return '' }
        $len = [int][Math]::Min([int64]$fi.Length, [int64]$MAXBYTES)
        $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $buf = New-Object byte[] $len; $null = $fs.Read($buf, 0, $len) } finally { $fs.Dispose() }
        $ext = $fi.Extension.TrimStart('.').ToLower()
        $textexts = 'bat,cmd,ps1,psm1,vbs,vbe,js,jse,wsf,hta,py,jar,txt,json,log,ini,cfg,html'.Split(',')
        if ($textexts -contains $ext) { return [System.Text.Encoding]::UTF8.GetString($buf) }
        $s = [System.Text.Encoding]::ASCII.GetString($buf)
        return ($s -replace '[^\x20-\x7e]+', ' ')
    } catch { return '' }
}

function Analyze([string]$text) {
    $score = 0; $hits = @(); $webhooks = @()
    if (-not $text) { return @{ score=0; hits=@(); webhooks=@() } }
    foreach ($m in [regex]::Matches($text, "(?i)$WEBHOOK_RE")) {
        if ($webhooks -notcontains $m.Value) { $webhooks += $m.Value; $score += 60; $hits += @{ i='infostealer'; l='exfil webhook'; w=60; lethal=$false } }
    }
    foreach ($m in [regex]::Matches($text, "(?i)$TELEGRAM_RE")) {
        if ($webhooks -notcontains $m.Value) { $webhooks += $m.Value; $score += 50; $hits += @{ i='infostealer'; l='telegram exfil'; w=50; lethal=$false } }
    }
    foreach ($r in $RULES) { if ([regex]::IsMatch($text, "(?i)$($r.re)")) { $score += $r.w; $hits += @{ i=$r.i; l=$r.l; w=$r.w; lethal=$r.lethal } } }
    foreach ($r in $IOC)   { if ([regex]::IsMatch($text, "(?i)$($r.re)")) { $score += $r.w; $hits += @{ i='infostealer'; l=$r.l; w=$r.w; lethal=$false } } }
    return @{ score=$score; hits=$hits; webhooks=$webhooks }
}

function Classify($hits) {
    $g = @{}
    foreach ($h in $hits) {
        if (-not $g.ContainsKey($h.i)) { $g[$h.i] = @{ intent=$h.i; score=0; why=@(); lethal=$false } }
        $g[$h.i].score += $h.w
        if ($h.lethal) { $g[$h.i].lethal = $true }
        if ($g[$h.i].why -notcontains $h.l) { $g[$h.i].why += $h.l }
    }
    $r = @($g.Values | Sort-Object @{e={[int]$_.lethal}}, @{e={$_.score}} -Descending)
    foreach ($x in $r) { $x.summary = $INTENT_SUMMARY[$x.intent] }
    return ,$r
}

function Test-Dangerous($hits) {
    if (@($hits | Where-Object { $_.lethal }).Count -gt 0) { return $true }
    $total = (@($hits | ForEach-Object { $_.w }) | Measure-Object -Sum).Sum
    $intents = @($hits | ForEach-Object { $_.i } | Sort-Object -Unique)
    return (($intents.Count -ge 2 -and $total -ge 50) -or $intents.Count -ge 3)
}

function Test-Stealer($hits, $webhooks) {
    if (-not $webhooks -or @($webhooks).Count -eq 0) { return $false }
    $labels = @($hits | ForEach-Object { $_.l })
    if (@($labels | Where-Object { $_ -like '*self-id*' }).Count -gt 0) { return $true }
    if (@($labels | Where-Object { $TOKEN_THEFT_LABELS -contains $_ }).Count -gt 0) { return $true }
    return $false
}

function Get-Severity([int]$s) {
    if ($s -ge 85) { 'CRITICAL' } elseif ($s -ge 45) { 'SUSPICIOUS' } elseif ($s -ge 20) { 'LOW' } else { 'CLEAN' }
}

# ---------------- helpers ----------------
function Norm([string]$p) { if (-not $p) { return '' } return $p.Replace('\\?\', '').ToLower() }

function Test-SuspiciousPath([string]$exe) {
    $low = Norm $exe
    foreach ($h in '\temp\', '\downloads\', '\desktop\', '\appdata\roaming\', '\appdata\local\temp\', '\public\', '\tmp\') {
        if ($low.Contains($h)) { return $true }
    }
    return $false
}

function Get-RefScripts([string]$cmd) {
    $out = @()
    if (-not $cmd) { return $out }
    $rx = '"([A-Za-z]:\\[^"\r\n]+?\.(?:' + $SCRIPT_EXTS + '))"|([A-Za-z]:\\[^\s"''<>|?*\r\n]+?\.(?:' + $SCRIPT_EXTS + '))'
    foreach ($m in [regex]::Matches($cmd, "(?i)$rx")) {
        $p = if ($m.Groups[1].Value) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf) -and -not (Test-Excluded $p)) { $out += $p }
    }
    return $out
}

function Test-TrustedExe([string]$exe) {
    if (-not $exe) { return $false }
    $low = Norm $exe
    foreach ($v in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:SystemRoot)) {
        if ($v -and $low.StartsWith((Norm $v))) { return $true }
    }
    if ($env:LOCALAPPDATA) {
        foreach ($s in @('\programs', '\microsoft', '\discord')) {
            if ($low.StartsWith((Norm ($env:LOCALAPPDATA + $s)))) { return $true }
        }
    }
    return $false
}

function Test-Killable([int]$procid, [string]$exe, [string]$pname) {
    if ($procid -le 4 -or $procid -eq $PID) { return $false }
    $n = $pname.ToLower()
    if ($CRITICAL -contains $n -or $CRITICAL -contains "$n.exe") { return $false }
    return $true
}

function Test-Quarantinable([string]$p) {
    if (-not $p) { return $false }
    return -not (Norm $p).StartsWith((Norm $env:SystemRoot))
}

function Test-Excluded([string]$p) {
    if (-not $p) { return $false }
    $rp = Norm $p
    if ($rp.StartsWith((Norm $BASE))) { return $true }
    if ($env:LOCALAPPDATA -and $rp.StartsWith((Norm ($env:LOCALAPPDATA + '\discord')))) { return $true }
    if (Test-Path $ALLOW) { foreach ($a in (Get-Content $ALLOW -ErrorAction SilentlyContinue)) { if ((Norm $a) -eq $rp) { return $true } } }
    return $false
}

# ---------------- actions ----------------
function Write-EventLog2([string]$m) {
    try { Add-Content -LiteralPath $EVTLOG -Value ("[{0}] {1}" -f (Get-Date -Format s), $m) -Encoding UTF8 } catch {}
}
function Write-DetLog($o) {
    try { Add-Content -LiteralPath $DETLOG -Value ($o | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8 } catch {}
}
function Show-Popup([string]$title, [string]$msg) {
    if ($NoPopup) { return }
    try {
        $sb = {
            param($t, $m)
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show($m, $t, 'OK', 'Warning', 'Button1', 'DefaultDesktopOnly') | Out-Null
        }
        $p = [PowerShell]::Create()
        $null = $p.AddScript($sb).AddArgument($title).AddArgument($msg)
        $null = $p.BeginInvoke()
    } catch {}
}
function Send-Alert($det) {
    $col = switch ($det.severity) { 'CRITICAL' { 'Red' } 'SUSPICIOUS' { 'Yellow' } default { 'DarkYellow' } }
    Write-Host ("[{0}] {1} score={2} :: {3}" -f $det.severity, $det.kind, $det.score, $det.target) -ForegroundColor $col
    foreach ($it in @($det.intents | Select-Object -First 4)) {
        $mk = if ($it.lethal) { '!!' } else { ' -' }
        Write-Host ("   NIYET {0} {1}: {2}" -f $mk, $it.intent, $it.summary)
    }
    Write-EventLog2 ("{0} {1} score={2} :: {3}" -f $det.severity, $det.kind, $det.score, $det.target)
    Write-DetLog $det
    if ($det.severity -eq 'CRITICAL') {
        Show-Popup "DiscordAntiStealer: TEHDIT" ("Tehdit engellendi/uyarildi!`n`nTur: {0}`nHedef: {1}`nSkor: {2}`n`nDetaylar loglarda." -f $det.kind, $det.target, $det.score)
    }
}
function New-Report($det) {
    try {
        $f = Join-Path $REPDIR ("report_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $det | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $f -Encoding UTF8
        Write-Host "   -> rapor olusturuldu: $f" -ForegroundColor Green
    } catch {}
}
function Invoke-Quarantine([string]$src) {
    try {
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { return $null }
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss_ffffff'
        $dest = Join-Path $QDIR ("{0}__{1}.quarantine" -f $ts, (Split-Path $src -Leaf))
        Move-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
        (@{ original=$src; quarantined=(Split-Path $dest -Leaf); ts=(Get-Date -Format s) } | ConvertTo-Json) |
            Set-Content -LiteralPath ($dest + '.meta.json') -Encoding UTF8
        Write-EventLog2 "QUARANTINED $src -> $dest"
        Write-Host "   -> karantinaya alindi: $dest" -ForegroundColor Green
        return $dest
    } catch { Write-EventLog2 "QUARANTINE FAILED $src : $_"; return $null }
}
function Stop-Tree([int]$procid) {
    try { $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$procid" -ErrorAction SilentlyContinue) } catch { $kids = @() }
    foreach ($k in $kids) { Stop-Tree ([int]$k.ProcessId) }
    try {
        $p = Get-Process -Id $procid -ErrorAction Stop
        $exe = ''; try { $exe = $p.Path } catch {}
        if (Test-Killable $procid $exe $p.Name) {
            Stop-Process -Id $procid -Force -ErrorAction Stop
            Write-EventLog2 "KILLED pid=$procid ($($p.Name))"
            Write-Host "   -> islem sonlandirildi: $($p.Name) ($procid)" -ForegroundColor Green
        }
    } catch {}
}

# ---------------- detection handlers ----------------
function Invoke-HandleProcess([int]$procid) {
    if ($script:SeenPids.Contains($procid)) { return }
    [void]$script:SeenPids.Add($procid)
    try { $wp = Get-CimInstance Win32_Process -Filter "ProcessId=$procid" -ErrorAction Stop } catch { return }
    if (-not $wp) { return }
    $name = [string]$wp.Name; $exe = [string]$wp.ExecutablePath; $cmd = [string]$wp.CommandLine
    if ($exe -and (Test-Excluded $exe)) { return }
    if ($name -eq 'Discord.exe' -and $exe -and $exe.ToLower().Contains('\discord\')) { return }

    $texts = @($cmd)
    $scripts = @(Get-RefScripts $cmd)
    foreach ($s in $scripts) { $t = Read-Text $s; if ($t) { $texts += $t } }
    $ext = ''; if ($exe) { $ext = ([System.IO.Path]::GetExtension($exe)).TrimStart('.').ToLower() }
    if ($exe -and ((($SCRIPT_EXTS -split '\|') -contains $ext) -or (Test-SuspiciousPath $exe))) {
        $t = Read-Text $exe; if ($t) { $texts += $t }
    }
    $blob = ($texts -join "`n")
    $a = Analyze $blob
    $sev = Get-Severity $a.score
    $dangerous = Test-Dangerous $a.hits
    $stealer = Test-Stealer $a.hits $a.webhooks
    if ($sev -eq 'CLEAN' -and -not $dangerous) { return }
    if ($dangerous -and $sev -ne 'CRITICAL') { $sev = 'CRITICAL' }
    $lethal = @($a.hits | Where-Object { $_.lethal }).Count -gt 0
    $risky = ($scripts.Count -gt 0) -or (($SCRIPT_EXTS -split '\|') -contains $ext) -or (Test-SuspiciousPath $exe)
    $auto = $lethal -or (($dangerous -or $stealer) -and $risky)
    $source = if ($scripts.Count -gt 0) { $scripts[0] } else { $exe }
    $det = @{ kind='process'; target="$name (pid $procid)"; score=$a.score; severity=$sev;
              intents=(Classify $a.hits); webhooks=$a.webhooks; source=$source; pid=$procid; ts=(Get-Date -Format s) }
    Send-Alert $det
    if ($sev -eq 'CRITICAL') { New-Report $det }
    if ($auto -and -not $AlertOnly) {
        Stop-Tree $procid
        if (Test-Quarantinable $source) { Invoke-Quarantine $source }
    }
}

function Invoke-HandleFile([string]$path) {
    if (Test-Excluded $path) { return }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $t = Read-Text $path
    if (-not $t) { return }
    $a = Analyze $t
    $sev = Get-Severity $a.score
    if ($sev -eq 'CLEAN') { return }
    # downloads are alert-only (never auto-blocked)
    $det = @{ kind='file'; target=$path; score=$a.score; severity=$sev;
              intents=(Classify $a.hits); webhooks=$a.webhooks; ts=(Get-Date -Format s) }
    Send-Alert $det
}

function Invoke-ProcessSweep {
    try { $cur = Get-Process -ErrorAction SilentlyContinue } catch { return }
    foreach ($p in $cur) { if (-not $script:SeenPids.Contains($p.Id)) { Invoke-HandleProcess $p.Id } }
}
function Get-WatchDirs {
    @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", $env:TEMP,
      "$env:LOCALAPPDATA\Temp", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup") |
        Where-Object { $_ -and (Test-Path $_) }
}
function Invoke-FileSweep {
    foreach ($d in (Get-WatchDirs)) {
        try { $files = Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue } catch { continue }
        foreach ($f in $files) {
            $mt = $f.LastWriteTimeUtc.Ticks
            if ($script:SeenFiles[$f.FullName] -ne $mt) { $script:SeenFiles[$f.FullName] = $mt; Invoke-HandleFile $f.FullName }
        }
    }
}
function Invoke-InjectionSweep {
    foreach ($n in @('discord','discordcanary','discordptb','Lightcord','Vencord')) {
        $root = Join-Path $env:APPDATA $n
        if (-not (Test-Path $root)) { continue }
        try { $js = @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.js -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt $MAXBYTES }) } catch { continue }
        foreach ($f in $js) {
            $t = Read-Text $f.FullName; if (-not $t) { continue }
            $a = Analyze $t
            $self = @($a.hits | Where-Object { $_.l -like '*self-id*' }).Count -gt 0
            if (@($a.webhooks).Count -gt 0 -or $self) {
                $score = [Math]::Max([int]$a.score, 70)
                $det = @{ kind='injection'; target=$f.FullName; score=$score; severity='CRITICAL';
                          intents=(Classify $a.hits); webhooks=$a.webhooks; ts=(Get-Date -Format s) }
                Send-Alert $det; New-Report $det   # alert only (client dosyasi tasinmaz)
            }
        }
    }
}

# ---------------- modes ----------------
function Start-Monitor {
    $created = $false
    try { $script:Mutex = New-Object System.Threading.Mutex($true, 'Global\DiscordAntiStealerPS_Guard', [ref]$created) } catch { $created = $true }
    if (-not $created) { Write-Host "[i] zaten calisiyor; ikinci kopya kapandi."; return }

    $script:SeenPids = New-Object 'System.Collections.Generic.HashSet[int]'
    $script:SeenFiles = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { [void]$script:SeenPids.Add($p.Id) }  # prime

    $useEvents = $false
    try { Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace -SourceIdentifier 'ASG_Proc' -ErrorAction Stop; $useEvents = $true }
    catch { Write-EventLog2 "WMI olaylari yok (yoklama moduna gecildi): $_" }

    Write-Host ("=" * 60) -ForegroundColor Green
    Write-Host "  DiscordAntiStealer (PowerShell) - koruma AKTIF"
    Write-Host ("  gercek-zamanli: {0}" -f $(if ($useEvents) { 'WMI olaylari + yoklama' } else { 'yoklama (~1.5sn)' }))
    Write-Host ("  aksiyon: {0}" -f $(if ($AlertOnly) { 'sadece uyari' } else { 'oldur + karantina' }))
    Write-Host ("=" * 60) -ForegroundColor Green

    $last = @{ proc=(Get-Date); file=(Get-Date); inject=(Get-Date) }
    while ($true) {
        if ($useEvents) {
            $evt = Wait-Event -SourceIdentifier 'ASG_Proc' -Timeout 1
            if ($evt) {
                try { Invoke-HandleProcess ([int]$evt.SourceEventArgs.NewEvent.ProcessID) } catch {}
                Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
            }
        } else { Start-Sleep -Milliseconds 1000 }
        $now = Get-Date
        if (($now - $last.proc).TotalSeconds -ge 1.5) { Invoke-ProcessSweep; $last.proc = $now }
        if (($now - $last.file).TotalSeconds -ge 4)   { Invoke-FileSweep;    $last.file = $now }
        if (($now - $last.inject).TotalSeconds -ge 120) { Invoke-InjectionSweep; $last.inject = $now }
    }
}

function Invoke-Check {
    $script:AlertOnly = $true
    $script:SeenPids = New-Object 'System.Collections.Generic.HashSet[int]'
    $script:SeenFiles = @{}
    Write-Host "[*] sistem taramasi: calisan islemler..."
    Invoke-ProcessSweep
    Write-Host "[*] sistem taramasi: indirilenler/temp/startup..."
    Invoke-FileSweep
    Write-Host "[*] sistem taramasi: discord injection..."
    Invoke-InjectionSweep
    Write-Host "[*] tamam."
}

function Show-Quarantined([string]$n) {
    if (-not $n) {
        Get-ChildItem $QDIR -Filter *.quarantine -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  - $($_.Name)" }
        return
    }
    $q = Join-Path $QDIR (Split-Path $n -Leaf)
    if (-not (Test-Path $q)) { Write-Host "bulunamadi: $q"; return }
    $meta = "$q.meta.json"
    if (Test-Path $meta) { $m = Get-Content $meta -Raw | ConvertFrom-Json; Write-Host "  orijinal: $($m.original)  ($($m.ts))" }
    $t = Read-Text $q
    $a = Analyze $t
    Write-Host "  == niyet ozeti ==" -ForegroundColor Yellow
    foreach ($it in (Classify $a.hits)) { $mk = if ($it.lethal) { '!!' } else { ' -' }; Write-Host "     $mk $($it.intent): $($it.summary)" }
    Write-Host "  --- ICERIK (yalnizca goruntuleme, calistirilmaz) ---" -ForegroundColor DarkGray
    $i = 0
    foreach ($line in ($t -split "`r?`n")) {
        $i++; if ($i -gt 500) { Write-Host "  ... (kisaltildi)"; break }
        $flag = ''
        foreach ($r in $RULES) { if ([regex]::IsMatch($line, "(?i)$($r.re)")) { $flag = "   << $($r.i): $($r.l)"; break } }
        Write-Host ("  {0,4} | {1}{2}" -f $i, $line, $flag)
    }
}

function Restore-Quarantined([string]$n) {
    if (-not $n) { Get-ChildItem $QDIR -Filter *.quarantine -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  - $($_.Name)" }; return }
    $q = Join-Path $QDIR (Split-Path $n -Leaf)
    if (-not (Test-Path $q)) { Write-Host "bulunamadi: $q"; return }
    $meta = "$q.meta.json"
    if (-not (Test-Path $meta)) { Write-Host "meta dosyasi yok; orijinal yol bilinmiyor."; return }
    $orig = (Get-Content $meta -Raw | ConvertFrom-Json).original
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $orig -Parent) -ErrorAction SilentlyContinue | Out-Null
        Move-Item -LiteralPath $q -Destination $orig -Force -ErrorAction Stop
        Add-Content -LiteralPath $ALLOW -Value $orig -Encoding UTF8
        Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue
        Write-Host "  geri yuklendi: $orig  (allowlist'e eklendi)" -ForegroundColor Green
    } catch { Write-Host "  geri yukleme basarisiz (yonetici gerekebilir): $_" }
}

function Invoke-ScanPath([string]$target) {
    if (-not $target -or -not (Test-Path $target)) { Write-Host "yol bulunamadi: $target"; return }
    $script:SeenPids = New-Object 'System.Collections.Generic.HashSet[int]'
    if (Test-Path $target -PathType Container) {
        Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { Invoke-HandleFile $_.FullName }
    } else { Invoke-HandleFile $target }
    Write-Host "[*] tarama tamam."
}

function Install-Guard {
    try { & icacls $BASE /reset /T /C /Q | Out-Null; Write-Host "[OK] klasor izinleri normallestirildi." } catch {}
    $psexe = Join-Path $PSHOME 'powershell.exe'
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SELF`" -Action monitor"
    $action = New-ScheduledTaskAction -Execute $psexe -Argument $arg -WorkingDirectory $BASE
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    $settings.MultipleInstances = 'IgnoreNew'
    Register-ScheduledTask -TaskName $TASK -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "[OK] Gorev kuruldu: '$TASK' (PowerShell, oturum acilista, admin, sinirsiz)."
    try { Start-ScheduledTask -TaskName $TASK -ErrorAction Stop; Write-Host "[OK] Monitor arka planda baslatildi." }
    catch { Write-Host "[i] Hemen baslatilamadi; sonraki oturum acilista calisacak." }
    Write-Host "kullanici: $me"
}

function Uninstall-Guard {
    try { Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue } catch {}
    try { Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*defender.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    Write-Host "[OK] Otomatik baslatma kaldirildi, monitor durduruldu."
}

function Show-Status {
    $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    if ($t) { $i = $t | Get-ScheduledTaskInfo; Write-Host "Gorev   : $($t.State)  | son calisma: $($i.LastRunTime) (sonuc $($i.LastTaskResult))" }
    else { Write-Host "Gorev   : (kurulu degil - start.bat calistir)" }
    $p = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*defender.ps1*' })
    if ($p.Count) { Write-Host "Monitor : calisiyor (pid $(($p | ForEach-Object { $_.ProcessId }) -join ', '))" } else { Write-Host "Monitor : calismiyor" }
    if (Test-Path $DETLOG) { Write-Host "--- son 5 tespit ---"; Get-Content $DETLOG -Tail 5 }
}

# ---------------- dispatch ----------------
switch ($Action) {
    'install'   { Install-Guard }
    'uninstall' { Uninstall-Guard }
    'status'    { Show-Status }
    'monitor'   { Start-Monitor }
    'check'     { Invoke-Check }
    'show'      { Show-Quarantined $Name }
    'restore'   { Restore-Quarantined $Name }
    'scan'      { Invoke-ScanPath $Path }
}
