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
Assert 'Pagina senza risorse esterne' { $html -notmatch '(?i)(src|href)\s*=\s*"https?:' -and $html -notmatch '(?i)@import|url\(\s*["'']?https?:' }
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

Write-Host "`n== Letture ==" -ForegroundColor Cyan
$t0 = Get-Date; do { $q = Get-RWebQuery 'system'; if ($q.loading) { Start-Sleep -Milliseconds 300 } } while ($q.loading -and ((Get-Date) - $t0).TotalSeconds -lt 90)
Assert 'Informazioni di sistema lette in background' { -not $q.loading -and $q.data.OSCaption -and $q.data.CpuName }
Assert 'Informazioni di sistema convertibili in JSON' { $j = ConvertTo-Json -InputObject $q -Depth 6 -Compress; $j -like '*OSCaption*' -and $j -like '*Disks*' }
$t0 = Get-Date; do { $w = Get-RWebQuery 'wifi'; if ($w.loading) { Start-Sleep -Milliseconds 300 } } while ($w.loading -and ((Get-Date) - $t0).TotalSeconds -lt 60)
Assert 'Reti Wi-Fi lette (anche nessuna) senza errori' { -not $w.loading -and $null -ne $w.data }

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
