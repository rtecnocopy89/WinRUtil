<#
.SYNOPSIS
    Test della variante web di WinRUtil. Non applica modifiche al sistema: verifica catalogo,
    esecuzione delle operazioni (con un'operazione di prova), letture e sicurezza del server HTTP.
    Uso: pwsh -File .\web\Test-WinRUtilWeb.ps1   (esce con 0 se tutto passa)
#>
param([switch]$Serve)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$PSDefaultParameterValues['Get-Content:Encoding'] = 'utf8'

# Stesso ambiente che prepara scripts\start.ps1, senza finestra WPF
$sync = [Hashtable]::Synchronized(@{})
$sync.configs = @{}; $sync.preferences = @{}; $sync.version = 'test'
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.SessionActions = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
$winutildir = Join-Path ([IO.Path]::GetTempPath()) 'winrutil_webtest'
New-Item $winutildir -ItemType Directory -Force | Out-Null
# I sorgenti sono UTF-8 senza BOM: Windows PowerShell 5.1 li leggerebbe come ANSI, quindi si caricano in UTF-8
function Import-Utf8Script { param([string]$Path) return [scriptblock]::Create([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)) }
foreach ($f in @(Get-ChildItem (Join-Path $root 'functions') -Recurse -File -Filter *.ps1)) { . (Import-Utf8Script $f.FullName) }
foreach ($f in @(Get-ChildItem (Join-Path $root 'config') -Filter *.json)) {
    $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
    if ($f.Name -eq 'applications.json') {
        foreach ($n in @($j.PSObject.Properties.Name)) { $v = $j.$n; $j.PSObject.Properties.Remove($n); $j | Add-Member -MemberType NoteProperty -Name "WPFInstall$n" -Value $v }
    }
    $sync.configs[$f.BaseName] = $j
}
if (-not ('PackageManagers' -as [type])) { Add-Type 'public enum PackageManagers { Winget, Choco }' }
$PARAM_NOUI = $true
$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object { $sync.configs.applicationsHashtable[$_.Name] = $_.Value }
$sync.configs.appxHashtable = @{}
$sync.configs.appx.PSObject.Properties | ForEach-Object { $sync.configs.appxHashtable[$_.Name] = $_.Value }
. (Import-Utf8Script (Join-Path $PSScriptRoot 'server.ps1'))

if ($Serve) {
    Start-WinRUtilWebApp -Html ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'index.html'))) -NoBrowser
    return
}

$script:pass = 0; $script:fail = 0
function Assert {
    param([string]$Name, [scriptblock]$Test)
    try { if (& $Test) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red } }
    catch { $script:fail++; Write-Host "  FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red }
}

Write-Host "`n== Sorgenti ==" -ForegroundColor Cyan
foreach ($f in @('server.ps1', 'main.ps1')) {
    Assert "$f senza errori di sintassi" { $t = $null; $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $f), [ref]$t, [ref]$e); $e.Count -eq 0 }
}
$html = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'index.html'))
Assert 'Pagina senza risorse esterne (solo le icone dei siti delle app)' {
    $urls = @([regex]::Matches($html, 'https?://[^\s"''<>)\\]+') | ForEach-Object { $_.Value })
    $html -notmatch '(?i)(src|href)\s*=\s*"https?:' -and $html -notmatch '(?i)@import|url\(\s*["'']?https?:' -and
    @($urls | Where-Object { $_ -notmatch '^(http://www\.w3\.org/2000/svg|https://www\.google\.com/s2/favicons\?)' }).Count -eq 0
}
$server = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server.ps1'))
Assert 'Tutte le sezioni della versione classica nella barra laterale' {
    @('sys', 'inst', 'tw', 'appx', 'cfg', 'upd', 'prn', 'wifi', 'rep', 'sec' | Where-Object { $html -notlike "*data-v=""$_""*" -or $html -notlike "*id=""v-$_""*" }).Count -eq 0
}
Assert 'Ogni chiamata della pagina ha il suo percorso nel server' {
    $routes = @([regex]::Matches($server, "'(GET|POST) (/api/[a-z/]+)'") | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
    $calls = @([regex]::Matches($html, "api\('(GET|POST)', '(/api/[a-z/]+)") | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
    $calls += @([regex]::Matches($html, "query\('(/api/[a-z/]+)") | ForEach-Object { "GET $($_.Groups[1].Value)" })
    $calls += @([regex]::Matches($html, "run\('(/api/[a-z/]+)") | ForEach-Object { "POST $($_.Groups[1].Value)" })
    $miss = @($calls | Select-Object -Unique | Where-Object { $routes -notcontains $_ })
    if ($miss.Count) { Write-Host "    mancano: $($miss -join ', ')" -ForegroundColor DarkYellow }
    $calls.Count -gt 20 -and $miss.Count -eq 0
}
Assert 'Ogni elemento cercato dallo script esiste nella pagina' {
    $dynamic = @('sysCpuLoad', 'sysCpuBar', 'sysRamText', 'sysRamFree', 'sysRamBar', 'sysUptime')
    $miss = @([regex]::Matches($html, "\`$\('([A-Za-z]+)'\)") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Where-Object { $dynamic -notcontains $_ -and $html -notlike "*id=""$_""*" })
    if ($miss.Count) { Write-Host "    mancano: $($miss -join ', ')" -ForegroundColor DarkYellow }
    $miss.Count -eq 0
}
Assert 'Ogni operazione avviata dal server esiste' {
    $kinds = @([regex]::Matches($server, "& \`$start '([a-z]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $kinds.Count -gt 10 -and @($kinds | Where-Object { -not $script:RWebTasks.ContainsKey($_) }).Count -eq 0
}
Assert 'Versione classica aperta da file, senza irm | iex sulla riga di comando (bloccato dagli antivirus)' {
    $c = $script:RWebTasks['classic'].ToString()
    $c -match "'-File'" -and $c -notmatch '\|\s*iex|Invoke-Expression|-Command' -and $server -notmatch '\|\s*iex'
}
Assert 'CyberRSecurityCheck avviato da file solo dopo la verifica SHA256' {
    $c = $script:RWebTasks['cyber'].ToString()
    $c -match "'-File'" -and $c -match 'Test-WinRUtilSha256' -and $c -match '\.sha256' -and $c -notmatch '\|\s*iex|Invoke-Expression|-Command' -and
    $c.IndexOf('Test-WinRUtilSha256') -lt $c.IndexOf('Start-Process') -and $script:RWebStrictKinds -contains 'cyber'
}
$shaFile = Join-Path $winutildir 'prova-sha.txt'
[IO.File]::WriteAllText($shaFile, 'contenuto di prova')
$shaGood = (Get-FileHash -LiteralPath $shaFile -Algorithm SHA256).Hash.ToLower() + '  prova-sha.txt'
Assert 'Impronta SHA256: accetta il file giusto' { Test-WinRUtilSha256 -Path $shaFile -ShaText $shaGood }
Assert 'Impronta SHA256: rifiuta file modificati, impronte vuote o non valide' {
    -not (Test-WinRUtilSha256 -Path $shaFile -ShaText ('0' * 64)) -and -not (Test-WinRUtilSha256 -Path $shaFile -ShaText '') -and
    -not (Test-WinRUtilSha256 -Path $shaFile -ShaText '<html>404</html>') -and -not (Test-WinRUtilSha256 -Path (Join-Path $winutildir 'manca.txt') -ShaText $shaGood)
}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $crsUrl = 'https://raw.githubusercontent.com/rtecnocopy89/CyberRSecurityCheck/main/cyberrsecuritycheck.ps1'
    $crsTmp = Join-Path $winutildir 'crs.ps1'
    Invoke-WebRequest -Uri $crsUrl -OutFile $crsTmp -UseBasicParsing -ErrorAction Stop
    $crsSha = [string](Invoke-WebRequest -Uri "$crsUrl.sha256" -UseBasicParsing -ErrorAction Stop).Content
    Assert 'CyberRSecurityCheck pubblicato su GitHub con impronta corrispondente' { Test-WinRUtilSha256 -Path $crsTmp -ShaText $crsSha }
} catch { Write-Host "  NOTA  GitHub non raggiungibile, impronta di CyberRSecurityCheck non verificata: $($_.Exception.Message)" -ForegroundColor DarkYellow }
Assert 'Pagina con script protetto da nonce (CSP)' { $html -like '*<script nonce="__NONCE__">*' -and ([regex]::Matches($html, '<script')).Count -eq 1 }
foreach ($f in @('index.html', 'server.ps1', 'main.ps1')) {
    Assert "$f solo ASCII (il file unico deve essere ASCII)" { @([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $f)) | Where-Object { $_ -gt 127 }).Count -eq 0 }
}
Assert 'Pagina senza riga che chiude la here-string del file unico' { $html -notmatch "(?m)^'@" }
Assert 'Pagina senza gestori di eventi inline (bloccati dalla CSP)' { $html -notmatch '(?i)\son(click|load|change|input)\s*=' }

Write-Host "`n== Catalogo ==" -ForegroundColor Cyan
$cat = Get-RWebCatalog
Assert 'Tutte le applicazioni del catalogo' { $cat.apps.Count -eq @($sync.configs.applications.PSObject.Properties).Count -and $cat.apps.Count -gt 100 }
Assert 'Id delle app con prefisso WPFInstall (come la versione classica)' { @($cat.apps | Where-Object { $_.id -notlike 'WPFInstall*' }).Count -eq 0 }
Assert 'Ottimizzazioni, interruttori e pulsanti presenti' { @($cat.tweaks | Where-Object { -not $_.type }).Count -gt 20 -and @($cat.tweaks | Where-Object { $_.type -eq 'Toggle' }).Count -gt 10 -and @($cat.tweaks | Where-Object { $_.type -eq 'Button' }).Count -ge 2 }
$twIds = @($cat.tweaks | ForEach-Object { $_.id })
$missing = @($cat.presets['Standard'] + $cat.presets['Minimal'] | Where-Object { $twIds -notcontains $_ } | Select-Object -Unique)
if ($missing.Count) { Write-Host "  NOTA  preset.json cita voci assenti da tweaks.json (la pagina le ignora): $($missing -join ', ')" -ForegroundColor DarkYellow }
Assert 'Preset Standard, Minimo e Avanzato con ottimizzazioni utilizzabili' { @($cat.presets['Standard'] | Where-Object { $twIds -contains $_ }).Count -ge 5 -and @($cat.presets['Minimal'] | Where-Object { $twIds -contains $_ }).Count -ge 3 -and @($cat.presets['Advanced'] | Where-Object { $twIds -contains $_ }).Count -ge 5 }
Assert 'DNS: stesse voci della versione classica (predefinito, DHCP, il piu'' veloce, provider)' { $cat.dns -contains 'Default' -and $cat.dns -contains 'DHCP' -and $cat.dns -contains 'Fastest' -and $cat.dns -contains 'Cloudflare' }
Assert 'Pagina con tutti i preset del catalogo per le ottimizzazioni' { @('Standard', 'Minimal', 'Advanced' | Where-Object { $html -notlike "*data-preset=""$_""*" }).Count -eq 0 }
Assert 'Categorie senza prefisso tecnico z__' { @($cat.tweaks + $cat.features | Where-Object { $_.cat -like 'z__*' }).Count -eq 0 }
Assert 'Disattivazione aggiornamenti senza finestra di conferma WPF (la conferma e'' nella pagina)' { $script:RWebTasks['button'].ToString() -like '*Invoke-WPFUpdatesdisable -Confirmed*' -and $html -like '*data-btn="WPFUpdatesdisable"*data-confirm=*' }
Assert 'Ogni pulsante ha una funzione o uno script' {
    $bad = @(Get-RWebButtonIds | Where-Object {
            $c = $sync.configs.feature.$_
            -not (($c -and $c.function -and (Get-Command $c.function -ErrorAction SilentlyContinue)) -or ($c -and $c.InvokeScript) -or ($_ -in @('WPFAddUltPerf', 'WPFRemoveUltPerf', 'WPFOOSUbutton', 'WPFUpdatesdefault', 'WPFUpdatessecurity', 'WPFUpdatesdisable', 'WPFInstallUpgrade')))
        })
    $bad.Count -eq 0
}
Assert 'Funzioni usate dalle operazioni disponibili' { @('Invoke-WinUtilTweaks', 'Invoke-WinUtilFeatureInstall', 'Install-WinUtilProgramWinget', 'Install-WinUtilProgramChoco', 'Get-WinUtilSelectedPackages', 'Set-WinUtilDNS', 'Invoke-WPFUltimatePerformance', 'Invoke-WPFUpdatesdefault', 'Get-WinUtilSystemReport', 'Get-WinRUtilWifiProfiles' | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }).Count -eq 0 }
Assert 'Filtro id: accetta solo voci del catalogo' { $r = @(Select-RWebIds @('WPFInstall7zip', 'Remove-Item', 'WPFInstall7zip') @('WPFInstall7zip')); $r.Count -eq 1 -and $r[0] -eq 'WPFInstall7zip' }
Assert 'App di Windows nel catalogo, con il nome del pacchetto' { $cat.appx.Count -eq @($sync.configs.appx.PSObject.Properties).Count -and $cat.appx.Count -gt 10 -and @($cat.appx | Where-Object { -not $_.pkg }).Count -eq 0 }
Assert 'Menu Multiplane Overlay con le sue tre scelte' { $m = @($cat.combos | Where-Object { $_.id -eq 'WPFMultiplaneOverlay' }); $m.Count -eq 1 -and $m[0].items.Count -eq 3 }
Assert 'Funzioni della versione classica usate dalle nuove sezioni disponibili' {
    $need = @('Remove-WinUtilAPPX', 'Install-WinUtilAPPX', 'Remove-WinUtilProvisionedAPPX', 'Get-WinUtilInstalledAPPX', 'Export-WinUtilWifiProfiles', 'Import-WinUtilWifiProfiles', 'Test-WinUtilWlanService',
        'ConvertTo-WinUtilQRCode', 'Get-WinUtilWifiQRText', 'ConvertTo-WinUtilWifiQRCard', 'Save-WinUtilReportSettings', 'Get-WinUtilReportSettings', 'ConvertTo-WinUtilInterventionReportHtml',
        'ConvertTo-WinUtilSystemReportHtml', 'ConvertTo-WinUtilSystemReportText', 'Update-WinUtilProgram', 'Get-WinUtilProgramUpdates', 'Invoke-WinUtilCurrentSystem', 'Set-WinUtilRegistryComboState',
        'Get-WinUtilRegistryComboState', 'Test-WinUtilPackageManager', 'Format-WinUtilUptime', 'Set-WinUtilSystemMemory', 'Add-WinUtilSessionAction')
    $miss = @($need | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($miss.Count) { Write-Host "    mancano: $($miss -join ', ')" -ForegroundColor DarkYellow }
    $miss.Count -eq 0
}
$iss = New-RWebSessionState
Assert 'Le operazioni vedono le funzioni della versione classica e la finestra Apri/Salva' { $names = @($iss.Commands | ForEach-Object { $_.Name }); $names -contains 'Show-WinRUtilWebFileDialog' -and $names -contains 'Update-WinUtilProgram' -and $names -contains 'ConvertTo-WinUtilWifiQRCard' }
Assert 'QR code Wi-Fi: moduli per la pagina con i riquadri di posizione' {
    $qr = ConvertTo-WinUtilQRCode -Text (Get-WinUtilWifiQRText -Network ([pscustomobject]@{ Ssid = 'Casa; prova'; Password = 'pass:word'; Security = 'WPA2-Personal'; Hidden = $false }))
    $m = ConvertTo-RWebQRModules $qr
    $m.Length -eq $qr.Size * $qr.Size -and $m.Substring(0, 7) -eq '1111111' -and $m.Substring($qr.Size - 7, 7) -eq '1111111'
}
Assert 'Testo del QR code Wi-Fi con i caratteri speciali protetti' { (Get-WinUtilWifiQRText -Network ([pscustomobject]@{ Ssid = 'Casa; prova'; Password = 'pass:word'; Security = 'WPA2-Personal'; Hidden = $false })) -eq 'WIFI:T:WPA;S:Casa\; prova;P:pass\:word;;' }
Assert 'Stato dei menu (Multiplane Overlay) letto dal registro' { $script:RWebState.Catalog = $cat; $c = Get-RWebCombos; $c.ContainsKey('WPFMultiplaneOverlay') -and ($c['WPFMultiplaneOverlay'] -eq '' -or ($cat.combos | Where-Object { $_.id -eq 'WPFMultiplaneOverlay' }).items -contains $c['WPFMultiplaneOverlay']) }
[void]$sync.SessionActions.Clear()
Add-WinUtilSessionAction -Area 'Prova' -Text 'Operazione di prova'
Assert 'Rapporto: operazioni della sessione per la pagina' { $r = Get-RWebReport; @($r.actions).Count -eq 1 -and $r.actions[0].area -eq 'Prova' -and $r.actions[0].result -eq 'Eseguito' -and (ConvertTo-Json -InputObject $r -Depth 5) -like '*Operazione di prova*' }
[void]$sync.SessionActions.Clear()
Assert 'Testi limitati nella lunghezza' { (Get-RWebText ('x' * 5000) 200).Length -eq 200 -and (Get-RWebText '  a  ') -eq 'a' }

Write-Host "`n== Esecuzione delle operazioni ==" -ForegroundColor Cyan
$script:RWebTasks['prova'] = { param($Testo) Set-WinUtilProgressbar -Label 'passo di prova' -Percent 40; Write-Host "eco: $Testo"; Write-Host "etichetta: $($RWeb.Label)"; Write-Warning 'avviso di prova'; if (-not $PARAM_NOUI) { throw 'PARAM_NOUI non attivo' }; if (-not (Get-Command Invoke-WinUtilTweaks -ErrorAction SilentlyContinue)) { throw 'funzioni mancanti' } }
$script:RWebTasks['lenta'] = { Start-Sleep -Seconds 3 }
Assert 'Avvio di un''operazione' { Start-RWebTask 'prova' 'Operazione di prova' @{ Testo = 'ciao' } }
$t0 = Get-Date; while ($script:RWebState.Phase -eq 'running' -and ((Get-Date) - $t0).TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200; Update-RWebPhase }
$st = Get-RWebStatus 0
Assert 'Operazione completata senza errori' { $st.phase -eq 'done' -and -not $st.error }
Assert 'Messaggi di Write-Host mostrati nel registro' { @($st.log | Where-Object { $_.m -eq 'eco: ciao' }).Count -eq 1 }
Assert 'Barra di avanzamento collegata alla pagina' { @($st.log | Where-Object { $_.m -eq 'etichetta: passo di prova' }).Count -eq 1 -and $st.percent -eq 100 }
Assert 'Avvisi mostrati come avvisi' { @($st.log | Where-Object { $_.m -eq 'avviso di prova' -and $_.c -eq 'warn' }).Count -eq 1 }
Assert 'Registro letto in modo incrementale' { (Get-RWebStatus $st.logIndex).log.Count -eq 0 }
[void](Start-RWebTask 'lenta' 'Lenta' @{})
Assert 'Una sola operazione alla volta' { -not (Start-RWebTask 'prova' 'Seconda' @{ Testo = 'x' }) }
$t0 = Get-Date; while ($script:RWebState.Phase -eq 'running' -and ((Get-Date) - $t0).TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200; Update-RWebPhase }
$script:RWebTasks['errore'] = { throw 'errore voluto' }
[void](Start-RWebTask 'errore' 'Errore' @{})
$t0 = Get-Date; while ($script:RWebState.Phase -eq 'running' -and ((Get-Date) - $t0).TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200; Update-RWebPhase }
Assert 'Errore dell''operazione riportato alla pagina' { (Get-RWebStatus 0).error -like '*errore voluto*' }
$script:RWebTasks['scritto'] = { Write-Error 'errore scritto' }
$script:RWebStrictKinds += 'scritto'
[void](Start-RWebTask 'scritto' 'Errore scritto' @{})
$t0 = Get-Date; while ($script:RWebState.Phase -eq 'running' -and ((Get-Date) - $t0).TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200; Update-RWebPhase }
Assert 'Errore scritto dalle operazioni di questa variante = non riuscita' { (Get-RWebStatus 0).error -like '*errore scritto*' }
$script:RWebTasks['risultati'] = { $RWeb.Results['app1'] = @{ t = 'Aggiornata'; l = 'Success'; ok = $true } }
[void](Start-RWebTask 'risultati' 'Risultati' @{})
$t0 = Get-Date; while ($script:RWebState.Phase -eq 'running' -and ((Get-Date) - $t0).TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200; Update-RWebPhase }
Assert 'Esito di ogni applicazione aggiornata passato alla pagina' { $s = Get-RWebStatus 0; $s.kind -eq 'risultati' -and $s.results['app1'].ok -and (ConvertTo-Json -InputObject $s -Depth 6) -like '*Aggiornata*' }

Write-Host "`n== Letture ==" -ForegroundColor Cyan
$t0 = Get-Date; do { $q = Get-RWebQuery 'system'; if ($q.loading) { Start-Sleep -Milliseconds 300 } } while ($q.loading -and ((Get-Date) - $t0).TotalSeconds -lt 90)
Assert 'Informazioni di sistema lette in background' { -not $q.loading -and $q.data.OSCaption -and $q.data.CpuName }
Assert 'Informazioni di sistema convertibili in JSON' { $j = ConvertTo-Json -InputObject $q -Depth 6 -Compress; $j -like '*OSCaption*' -and $j -like '*Disks*' }
$t0 = Get-Date; do { $w = Get-RWebQuery 'wifi'; if ($w.loading) { Start-Sleep -Milliseconds 300 } } while ($w.loading -and ((Get-Date) - $t0).TotalSeconds -lt 60)
Assert 'Reti Wi-Fi lette (anche nessuna) senza errori' { -not $w.loading -and $null -ne $w.data }
Assert 'Reti Wi-Fi con l''indicazione del QR code' { @($w.data | Where-Object { -not $_.ContainsKey('canShare') }).Count -eq 0 }
$t0 = Get-Date; do { $l = Get-RWebQuery 'live' -Refresh; if ($l.loading) { Start-Sleep -Milliseconds 300 } } while ($l.loading -and ((Get-Date) - $t0).TotalSeconds -lt 30)
Assert 'Processore e memoria aggiornati in tempo reale' { -not $l.loading -and $l.data.RamText -like '*GB*' -and $l.data.CpuLoad -like '*%' -and $l.data.Uptime }
$t0 = Get-Date; do { $p = Get-RWebQuery 'printers'; if ($p.loading) { Start-Sleep -Milliseconds 300 } } while ($p.loading -and ((Get-Date) - $t0).TotalSeconds -lt 60)
Assert 'Stampanti lette (o errore spiegato)' { -not $p.loading -and ($p.error -or @($p.data | Where-Object { -not $_.name }).Count -eq 0) }

Write-Host "`n== Server HTTP ==" -ForegroundColor Cyan
$psExe = (Get-Process -Id $PID).Path
$out = Join-Path $winutildir 'serve.txt'
Remove-Item $out -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Serve') -RedirectStandardOutput $out -WindowStyle Hidden -PassThru
$url = $null; $t0 = Get-Date
while (-not $url -and ((Get-Date) - $t0).TotalSeconds -lt 60) {
    Start-Sleep -Milliseconds 300
    $txt = ''
    try {
        $fs = New-Object IO.FileStream($out, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $txt = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { $txt = '' }
    if ($txt) { $m = [regex]::Match($txt, 'in ascolto: (http://localhost:\d+/)#([0-9a-f]{64})'); if ($m.Success) { $url = $m.Groups[1].Value; $tok = $m.Groups[2].Value } }
}
Assert 'Server avviato su localhost con codice di accesso' { [bool]$url }
if ($url) {
    Add-Type -AssemblyName System.Net.Http
    $hc = New-Object System.Net.Http.HttpClient
    function Send-T {
        param([string]$Method, [string]$Path, [string]$Body = $null, [hashtable]$Headers = @{}, [switch]$NoToken)
        $rq = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($Method)), ($url.TrimEnd('/') + $Path)
        if (-not $NoToken) { [void]$rq.Headers.TryAddWithoutValidation('X-Token', $tok) }
        foreach ($k in $Headers.Keys) { if ($k -eq 'Host') { $rq.Headers.Host = $Headers[$k] } else { [void]$rq.Headers.TryAddWithoutValidation($k, $Headers[$k]) } }
        if ($Body) { $rq.Content = New-Object System.Net.Http.StringContent($Body, [Text.Encoding]::UTF8, 'application/json') }
        $r = $hc.SendAsync($rq).GetAwaiter().GetResult()
        $vals = $null; $csp = ''
        if ($r.Headers.TryGetValues('Content-Security-Policy', [ref]$vals)) { $csp = @($vals) -join '' }
        return [pscustomobject]@{ Code = [int]$r.StatusCode; Text = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult(); Csp = $csp }
    }
    $p = Send-T GET '/' -NoToken
    Assert 'Pagina servita con nonce sostituito' { $p.Code -eq 200 -and $p.Text -notlike '*__NONCE__*' -and $p.Text -like '*<script nonce="*' }
    Assert 'CSP restrittiva con lo stesso nonce della pagina' { $n = [regex]::Match($p.Text, '<script nonce="([^"]+)"').Groups[1].Value; $p.Csp -like "*script-src 'nonce-$n'*" -and $p.Csp -like "*default-src 'none'*" -and $p.Csp -like "*connect-src 'self'*" }
    Assert 'API senza codice di accesso rifiutata' { (Send-T GET '/api/info' -NoToken).Code -eq 403 }
    Assert 'API con codice sbagliato rifiutata' { (Send-T GET '/api/info' -NoToken -Headers @{ 'X-Token' = ('0' * 64) }).Code -eq 403 }
    Assert 'Host diverso da localhost rifiutato (DNS rebinding)' { (Send-T GET '/api/info' -Headers @{ Host = 'evil.example' }).Code -in @(400, 403) }
    Assert 'POST da un''altra origine rifiutato' { (Send-T POST '/api/apps' '{"ids":["WPFInstall7zip"]}' -Headers @{ Origin = 'http://evil.example' }).Code -eq 403 }
    $i = Send-T GET '/api/info'
    Assert 'Informazioni dell''app' { $i.Code -eq 200 -and ($i.Text | ConvertFrom-Json).app -eq 'WinRUtil' }
    $c = Send-T GET '/api/catalog'
    Assert 'Catalogo via HTTP' { $c.Code -eq 200 -and @(($c.Text | ConvertFrom-Json).apps).Count -eq $cat.apps.Count }
    Assert 'Installazione senza app valide rifiutata' { (Send-T POST '/api/apps' '{"ids":["non-esiste","Remove-Item"],"action":"Install"}').Code -eq 400 }
    Assert 'Ottimizzazioni senza voci valide rifiutate' { (Send-T POST '/api/tweaks' '{"ids":["Remove-Item"],"dns":"Evil"}').Code -eq 400 }
    Assert 'Pulsante non previsto rifiutato' { (Send-T POST '/api/button' '{"id":"Invoke-Expression"}').Code -eq 400 }
    Assert 'Interruttore non previsto rifiutato' { (Send-T POST '/api/toggle' '{"id":"WPFTweaksActivity","on":true}').Code -eq 400 }
    Assert 'Funzionalita'' non previste rifiutate' { (Send-T POST '/api/features' '{"ids":["WPFPanelControl"]}').Code -eq 400 }
    Assert 'Percorso sconosciuto = 404' { (Send-T GET '/api/niente').Code -eq 404 }
    Assert 'Icone delle app ammesse dalla CSP solo dal servizio delle icone' { $p.Csp -match "img-src data: https://www\.google\.com https://\*\.gstatic\.com;" }
    Assert 'App di Windows non previste rifiutate' { (Send-T POST '/api/appx' '{"ids":["Remove-Item"],"action":"Remove"}').Code -eq 400 }
    Assert 'Scelta del menu non prevista rifiutata' { (Send-T POST '/api/combo' '{"id":"WPFMultiplaneOverlay","state":"Evil"}').Code -eq 400 }
    Assert 'Azione stampanti non prevista rifiutata' { (Send-T POST '/api/printer' '{"action":"format"}').Code -eq 400 }
    Assert 'Rimozione di un driver non in elenco rifiutata' { (Send-T POST '/api/printer' '{"action":"remove","driver":"Microsoft Print To PDF"}').Code -eq 400 }
    Assert 'Aggiornamento senza ricerca rifiutato' { (Send-T POST '/api/updates' '{"ids":["Microsoft.Edge"],"manager":"Winget"}').Code -eq 400 }
    Assert 'QR code di una rete sconosciuta rifiutato' { (Send-T POST '/api/wifiqr' '{"ssid":"rete-che-non-esiste"}').Code -eq 400 }
    Assert 'Rapporto: elenco delle operazioni' { $r = Send-T GET '/api/report'; $r.Code -eq 200 -and $null -ne ($r.Text | ConvertFrom-Json).actions }
    Assert 'Stato dei menu via HTTP' { $r = Send-T GET '/api/combos'; $r.Code -eq 200 -and $r.Text -like '*WPFMultiplaneOverlay*' }
    $s = Send-T GET '/api/status?since=0'
    Assert 'Stato iniziale: nessuna operazione' { $s.Code -eq 200 -and ($s.Text | ConvertFrom-Json).phase -eq 'idle' }
    Assert 'Uscita richiesta dalla pagina chiude il server' { (Send-T POST '/api/exit' '{}').Code -eq 200 -and $proc.WaitForExit(15000) }
}
if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }

Remove-Item $winutildir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
$col = 'Green'; if ($script:fail) { $col = 'Red' }
Write-Host ("Test superati: {0}   falliti: {1}" -f $script:pass, $script:fail) -ForegroundColor $col
if ($script:fail) { exit 1 } else { exit 0 }
