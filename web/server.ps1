# WinRUtil - variante con interfaccia HTML.
# Server locale (solo localhost, codice di accesso casuale a ogni avvio) che mostra web/index.html in una
# finestra Edge/Chrome in modalita' app e richiama le stesse funzioni della versione classica (WPF).
# Le funzioni della versione classica girano con $PARAM_NOUI = $true: niente chiamate alla finestra WPF.

$script:RWeb = [hashtable]::Synchronized(@{
        Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Label = ''; Percent = 0; Title = ''
    })
$script:RWebState = @{
    Phase = 'idle'; PS = $null; RS = $null; Handle = $null; Started = $null; Read = @{ I = 0; W = 0; E = 0 }
    Queries = @{}; LastActivity = (Get-Date).AddSeconds(40); Quit = $false; Browser = $null; BrowserProc = $null; ProfileDir = ''
    Token = ''; Port = 0; Iss = $null; Catalog = $null; Error = ''
}

function Add-RWebLog {
    param([string]$Text, [string]$Level = 'info')
    if ($null -eq $Text) { return }
    foreach ($l in ($Text -split "`r?`n")) {
        $t = $l.TrimEnd()
        if (-not $t -or $t -match '^[\s\-\\|/=]+$') { continue }
        [void]$script:RWeb.Log.Add(@{ t = (Get-Date).ToString('HH:mm:ss'); m = $t; c = $Level })
    }
}

function New-RWebSessionState {
    # Stesse funzioni e variabili della versione classica, con la barra di avanzamento collegata alla pagina
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($v in @(@('sync', $sync), @('PARAM_NOUI', $true), @('PARAM_OFFLINE', $false), @('winutildir', $winutildir), @('RWeb', $script:RWeb), @('DebugPreference', 'SilentlyContinue'))) {
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $v[0], $v[1], $null))
    }
    foreach ($f in @(Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|winrutil|WPF' -and $_.Name -ne 'Set-WinUtilProgressbar' })) {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $f.Name, $f.Definition))
    }
    $progress = 'param([string]$Label, [int]$Percent) $RWeb.Label = $Label; $RWeb.Percent = [math]::Max(0, [math]::Min(100, $Percent))'
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Set-WinUtilProgressbar', $progress))
    return $iss
}

function Get-RWebCatalog {
    $apps = New-Object System.Collections.Generic.List[object]
    foreach ($p in $sync.configs.applications.PSObject.Properties) {
        $a = $p.Value
        $apps.Add(@{ id = $p.Name; name = [string]$a.content; desc = [string]$a.description; cat = [string]$a.category; foss = [bool]$a.foss; link = [string]$a.link; winget = [string]$a.winget; choco = [string]$a.choco })
    }
    $tweaks = New-Object System.Collections.Generic.List[object]
    foreach ($p in $sync.configs.tweaks.PSObject.Properties) {
        $t = $p.Value
        $type = [string]$t.Type
        if ($type -eq 'Combobox') { continue }
        $tweaks.Add(@{ id = $p.Name; name = [string]$t.Content; desc = [string]$t.Description; cat = ([string]$t.category -replace '^z__', ''); advanced = ([string]$t.category -like 'z__*'); type = $type })
    }
    $features = New-Object System.Collections.Generic.List[object]
    foreach ($p in $sync.configs.feature.PSObject.Properties) {
        $f = $p.Value
        if ($p.Name -eq 'WPFFeatureInstall') { continue }
        $features.Add(@{ id = $p.Name; name = [string]$f.Content; desc = [string]$f.Description; cat = ([string]$f.category -replace '^z__', ''); type = [string]$f.Type })
    }
    $presets = @{}
    foreach ($p in $sync.configs.preset.PSObject.Properties) { $presets[$p.Name] = @($p.Value) }
    # Stesse voci del menu DNS della versione classica (compreso "Fastest"), altrimenti quelle di dns.json
    $dns = @(([string]$sync.configs.tweaks.WPFchangedns.ComboItems) -split '\s+' | Where-Object { $_ })
    if ($dns.Count -eq 0) { $dns = @('Default', 'DHCP') + @($sync.configs.dns.PSObject.Properties.Name) }
    return @{ apps = $apps.ToArray(); tweaks = $tweaks.ToArray(); features = $features.ToArray(); presets = $presets; dns = $dns }
}

function Get-RWebButtonIds {
    $ids = @('WPFAddUltPerf', 'WPFRemoveUltPerf', 'WPFOOSUbutton', 'WPFUpdatesdefault', 'WPFUpdatessecurity', 'WPFUpdatesdisable', 'WPFInstallUpgrade')
    foreach ($p in $sync.configs.feature.PSObject.Properties) { if ($p.Value.Type -eq 'Button' -and $p.Name -ne 'WPFFeatureInstall') { $ids += $p.Name } }
    return $ids
}

$script:RWebTasks = @{
    apps = {
        param($Ids, $Manager, $Action)
        $pk = @($Ids | ForEach-Object { $sync.configs.applicationsHashtable[$_] } | Where-Object { $_ })
        if ($pk.Count -eq 0) { Write-Host 'Nessuna applicazione selezionata.'; return }
        $sorted = Get-WinUtilSelectedPackages -PackageList $pk -Preference $Manager
        $w = @($sorted[[PackageManagers]::Winget]); $c = @($sorted[[PackageManagers]::Choco])
        $failed = @()
        if ($w.Count -gt 0) { Install-WinUtilWinget; $failed += @(Install-WinUtilProgramWinget -Action $Action -Programs $w) }
        if ($c.Count -gt 0) { Install-WinUtilChoco; $failed += @(Install-WinUtilProgramChoco -Action $Action -Programs $c) }
        $failed = @($failed | Where-Object { $_ })
        if ($failed.Count -gt 0) { Write-Warning ("Non riuscite: " + ($failed -join ', ')) } else { Write-Host 'Operazione completata.' }
    }
    upgrade = {
        param($Manager)
        Set-WinUtilProgressbar -Label 'Aggiornamento di tutte le applicazioni' -Percent 10
        if ($Manager -eq 'Choco') { Install-WinUtilChoco; & choco upgrade all -y 2>&1 | ForEach-Object { Write-Host $_ } }
        else { Install-WinUtilWinget; & winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object { Write-Host $_ } }
        Write-Host 'Aggiornamento completato.'
    }
    tweaks = {
        param($Ids, $Undo, $Dns)
        $ids = @($Ids)
        if (-not $Undo -and $ids -contains 'WPFTweaksRestorePoint') { $ids = @('WPFTweaksRestorePoint') + @($ids | Where-Object { $_ -ne 'WPFTweaksRestorePoint' }) }
        if ($Undo) { $ids = @($ids | Where-Object { $_ -ne 'WPFTweaksRestorePoint' }) }
        $n = [math]::Max(1, $ids.Count)
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $name = [string]$sync.configs.tweaks.($ids[$i]).Content
            if ($Undo) { Set-WinUtilProgressbar -Label "Annullo: $name" -Percent (100 * $i / $n); Invoke-WinUtilTweaks $ids[$i] -undo $true }
            else { Set-WinUtilProgressbar -Label "Applico: $name" -Percent (100 * $i / $n); Invoke-WinUtilTweaks $ids[$i] }
        }
        if ($Dns -and $Dns -ne 'Default') { Set-WinUtilProgressbar -Label "DNS: $Dns" -Percent 95; Set-WinUtilDNS -DNSProvider $Dns }
        Write-Host 'Ottimizzazioni completate.'
    }
    toggle = {
        param($Id, $On)
        if ($On) { Invoke-WinUtilTweaks $Id } else { Invoke-WinUtilTweaks $Id -undo $true }
        Write-Host 'Impostazione aggiornata.'
    }
    features = {
        param($Ids)
        $ids = @($Ids); $n = [math]::Max(1, $ids.Count)
        for ($i = 0; $i -lt $ids.Count; $i++) {
            Set-WinUtilProgressbar -Label ([string]$sync.configs.feature.($ids[$i]).Content) -Percent (100 * $i / $n)
            Invoke-WinUtilFeatureInstall $ids[$i]
        }
        Write-Host 'Funzionalita'' installate. Riavviare il PC per completare.'
    }
    button = {
        param($Id)
        $cfg = $sync.configs.feature.$Id
        if ($cfg -and $cfg.function -and (Get-Command $cfg.function -ErrorAction SilentlyContinue)) { & $cfg.function; return }
        if ($cfg -and $cfg.InvokeScript) { foreach ($s in $cfg.InvokeScript) { if ($s) { Invoke-Expression $s } }; return }
        switch ($Id) {
            'WPFAddUltPerf' { Invoke-WPFUltimatePerformance -Do }
            'WPFRemoveUltPerf' { Invoke-WPFUltimatePerformance }
            'WPFOOSUbutton' { Invoke-WPFOOSU }
            'WPFUpdatesdefault' { Invoke-WPFUpdatesdefault }
            'WPFUpdatessecurity' { Invoke-WPFUpdatessecurity }
            'WPFUpdatesdisable' { Invoke-WPFUpdatesdisable -Confirmed }
        }
        Write-Host 'Fatto.'
    }
}

function Start-RWebTask {
    param([string]$Kind, [string]$Title, [hashtable]$Params)
    $st = $script:RWebState
    if ($st.Phase -eq 'running') { return $false }
    Stop-RWebTask
    if (-not $st.Iss) { $st.Iss = New-RWebSessionState }
    $script:RWeb.Label = $Title; $script:RWeb.Percent = 0; $script:RWeb.Title = $Title
    Add-RWebLog "== $Title" 'head'
    $rs = [runspacefactory]::CreateRunspace($Host, $st.Iss)
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($script:RWebTasks[$Kind].ToString())
    foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
    $st.PS = $ps; $st.RS = $rs; $st.Read = @{ I = 0; W = 0; E = 0 }; $st.Error = ''
    $st.Handle = $ps.BeginInvoke(); $st.Started = Get-Date; $st.Phase = 'running'
    return $true
}

function Read-RWebStreams {
    $st = $script:RWebState
    if (-not $st.PS) { return }
    $s = $st.PS.Streams
    while ($st.Read.I -lt $s.Information.Count) { Add-RWebLog ([string]$s.Information[$st.Read.I].MessageData) 'info'; $st.Read.I++ }
    while ($st.Read.W -lt $s.Warning.Count) { Add-RWebLog ([string]$s.Warning[$st.Read.W].Message) 'warn'; $st.Read.W++ }
    while ($st.Read.E -lt $s.Error.Count) { Add-RWebLog ([string]$s.Error[$st.Read.E].Exception.Message) 'error'; $st.Read.E++ }
}

function Update-RWebPhase {
    $st = $script:RWebState
    if ($st.Phase -ne 'running') { return }
    Read-RWebStreams
    if ($st.Handle -and $st.Handle.IsCompleted) {
        try { [void]$st.PS.EndInvoke($st.Handle) } catch { $st.Error = $_.Exception.Message; Add-RWebLog $st.Error 'error' }
        Read-RWebStreams
        $script:RWeb.Percent = 100
        $st.Phase = 'done'
        Add-RWebLog 'Terminato.' 'ok'
    }
}

function Stop-RWebTask {
    $st = $script:RWebState
    if ($st.PS) {
        try { if (-not $st.Handle.IsCompleted) { $st.PS.Stop() } } catch { }
        try { $st.PS.Dispose() } catch { }
        try { $st.RS.Close(); $st.RS.Dispose() } catch { }
    }
    $st.PS = $null; $st.RS = $null; $st.Handle = $null
}

function Get-RWebQuery {
    # Letture lente (sistema, Wi-Fi) in un runspace separato: la pagina resta reattiva
    param([string]$Name, [switch]$Refresh)
    $q = $script:RWebState.Queries
    if ($Refresh -and $q.ContainsKey($Name) -and $q[$Name].Done) { [void]$q.Remove($Name) }
    if (-not $q.ContainsKey($Name)) {
        if (-not $script:RWebState.Iss) { $script:RWebState.Iss = New-RWebSessionState }
        $rs = [runspacefactory]::CreateRunspace($script:RWebState.Iss); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        switch ($Name) {
            'system' { [void]$ps.AddScript('$r = Get-WinUtilSystemReport; $r.Disks = @($r.Disks | ForEach-Object { [pscustomobject]$_ }); [pscustomobject]$r') }
            'wifi' { [void]$ps.AddScript('@(Get-WinRUtilWifiProfiles)') }
        }
        $q[$Name] = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Done = $false; Data = $null }
    }
    $e = $q[$Name]
    if (-not $e.Done -and $e.Handle.IsCompleted) {
        try { $e.Data = @($e.PS.EndInvoke($e.Handle)) } catch { $e.Data = @() }
        try { $e.PS.Dispose(); $e.RS.Close(); $e.RS.Dispose() } catch { }
        $e.Done = $true
    }
    if (-not $e.Done) { return @{ loading = $true } }
    if ($Name -eq 'system') { return @{ loading = $false; data = @($e.Data)[0] } }
    return @{ loading = $false; data = @($e.Data | ForEach-Object { @{ ssid = [string]$_.Ssid; password = [string]$_.Password; security = [string]$_.Security; auto = [string]$_.AutoConnect } }) }
}

function Get-RWebToggles {
    $o = @{}
    foreach ($p in $sync.configs.tweaks.PSObject.Properties) {
        if ($p.Value.Type -ne 'Toggle') { continue }
        try { $o[$p.Name] = [bool](Get-WinUtilToggleStatus $p.Name) } catch { $o[$p.Name] = $false }
    }
    return $o
}

function Test-RWebTokenEqual {
    param([string]$A, [string]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $d = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $d = $d -bor ([int][char]$A[$i] -bxor [int][char]$B[$i]) }
    return ($d -eq 0)
}

function Send-RWebBytes {
    param($Ctx, [byte[]]$Bytes, [string]$Type, [int]$Code = 200, [hashtable]$Extra = @{})
    $res = $Ctx.Response
    $res.StatusCode = $Code; $res.ContentType = $Type
    $res.Headers['Cache-Control'] = 'no-store'; $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $res.Headers['Referrer-Policy'] = 'no-referrer'; $res.Headers['X-Frame-Options'] = 'DENY'
    foreach ($k in $Extra.Keys) { $res.Headers[$k] = $Extra[$k] }
    $res.ContentLength64 = $Bytes.Length
    $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $res.OutputStream.Close()
}

function Send-RWebJson {
    param($Ctx, $Obj, [int]$Code = 200)
    $json = ConvertTo-Json -InputObject $Obj -Depth 6 -Compress
    Send-RWebBytes $Ctx ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $Code
}

function Read-RWebBody {
    param($Req)
    if (-not $Req.HasEntityBody) { return $null }
    $sr = New-Object IO.StreamReader($Req.InputStream, [Text.Encoding]::UTF8)
    try { $t = $sr.ReadToEnd() } finally { $sr.Dispose() }
    if ($t.Length -gt 50000) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

function Select-RWebIds {
    # Accetta solo identificativi presenti nella configurazione
    param($Ids, $Valid)
    return @(@($Ids) | ForEach-Object { [string]$_ } | Where-Object { $Valid -contains $_ } | Select-Object -Unique)
}

function Get-RWebStatus {
    param([int]$Since)
    Update-RWebPhase
    $log = $script:RWeb.Log
    $count = $log.Count
    if ($Since -lt 0 -or $Since -gt $count) { $Since = 0 }
    $items = New-Object System.Collections.Generic.List[object]
    for ($i = $Since; $i -lt $count; $i++) { $items.Add($log[$i]) }
    $st = $script:RWebState
    $el = 0; if ($st.Started) { $el = [int]((Get-Date) - $st.Started).TotalSeconds }
    return @{ phase = $st.Phase; title = [string]$script:RWeb.Title; label = [string]$script:RWeb.Label; percent = [int]$script:RWeb.Percent; logIndex = $count; log = $items.ToArray(); elapsed = $el; error = [string]$st.Error }
}

function Invoke-RWebRequest {
    param($Ctx, [string]$Html)
    $st = $script:RWebState
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    if ($req.Headers['Host'] -ne "localhost:$($st.Port)") { Send-RWebJson $Ctx @{ error = 'host' } 403; return }
    if ($path -eq '/' -or $path -eq '/index.html') {
        $nb = New-Object byte[] 16
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($nb); $rng.Dispose()
        $nonce = [Convert]::ToBase64String($nb)
        $csp = "default-src 'none'; script-src 'nonce-$nonce'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        Send-RWebBytes $Ctx ([Text.Encoding]::UTF8.GetBytes($Html.Replace('__NONCE__', $nonce))) 'text/html; charset=utf-8' 200 @{ 'Content-Security-Policy' = $csp }
        return
    }
    if (-not $path.StartsWith('/api/')) { Send-RWebJson $Ctx @{ error = 'not found' } 404; return }
    if (-not (Test-RWebTokenEqual $req.Headers['X-Token']$st.Token)) { Send-RWebJson $Ctx @{ error = 'token' } 403; return }
    $o = $req.Headers['Origin']
    if ($req.HttpMethod -eq 'POST' -and $o -and $o -ne "http://localhost:$($st.Port)") { Send-RWebJson $Ctx @{ error = 'origin' } 403; return }
    $st.LastActivity = Get-Date
    $b = $null
    if ($req.HttpMethod -eq 'POST') { $b = Read-RWebBody $req }
    $cat = $st.Catalog
    $busy = @{ error = 'Un''altra operazione e'' in corso.' }
    switch ("$($req.HttpMethod) $path") {
        'GET /api/ping' { Send-RWebJson $Ctx @{ ok = $true } }
        'GET /api/info' {
            $pm = [string]$sync.preferences.packagemanager; if (-not $pm) { $pm = 'Winget' }
            Send-RWebJson $Ctx @{ app = 'WinRUtil'; version = [string]$sync.version; pc = [Environment]::MachineName; isAdmin = $true; manager = $pm }
        }
        'GET /api/catalog' { Send-RWebJson $Ctx $cat }
        'GET /api/toggles' { Send-RWebJson $Ctx (Get-RWebToggles) }
        'GET /api/system' { Send-RWebJson $Ctx (Get-RWebQuery 'system' -Refresh:([string]$req.QueryString['refresh'] -eq '1')) }
        'GET /api/wifi' { Send-RWebJson $Ctx (Get-RWebQuery 'wifi' -Refresh:([string]$req.QueryString['refresh'] -eq '1')) }
        'GET /api/status' {
            $since = 0; [void][int]::TryParse([string]$req.QueryString['since'], [ref]$since)
            Send-RWebJson $Ctx (Get-RWebStatus $since)
        }
        'POST /api/apps' {
            $ids = Select-RWebIds $b.ids @($cat.apps | ForEach-Object { $_.id })
            $act = 'Install'; if ([string]$b.action -eq 'Uninstall') { $act = 'Uninstall' }
            $mgr = 'Winget'; if ([string]$b.manager -eq 'Choco') { $mgr = 'Choco' }
            if ($ids.Count -eq 0) { Send-RWebJson $Ctx @{ error = 'Seleziona almeno un''applicazione.' } 400; return }
            $t = "Installazione di $($ids.Count) applicazioni"; if ($act -eq 'Uninstall') { $t = "Disinstallazione di $($ids.Count) applicazioni" }
            if (Start-RWebTask 'apps' $t @{ Ids = $ids; Manager = $mgr; Action = $act }) { Send-RWebJson $Ctx @{ ok = $true } } else { Send-RWebJson $Ctx $busy 409 }
        }
        'POST /api/upgrade' {
            $mgr = 'Winget'; if ([string]$b.manager -eq 'Choco') { $mgr = 'Choco' }
            if (Start-RWebTask 'upgrade' 'Aggiornamento di tutte le applicazioni' @{ Manager = $mgr }) { Send-RWebJson $Ctx @{ ok = $true } } else { Send-RWebJson $Ctx $busy 409 }
        }
        'POST /api/tweaks' {
            $ids = Select-RWebIds $b.ids @($cat.tweaks | Where-Object { -not $_.type } | ForEach-Object { $_.id })
            $dns = [string]$b.dns; if ($cat.dns -notcontains $dns) { $dns = 'Default' }
            $undo = [bool]$b.undo
            if ($ids.Count -eq 0 -and $dns -eq 'Default') { Send-RWebJson $Ctx @{ error = 'Seleziona almeno un''ottimizzazione.' } 400; return }
            $t = "Applicazione di $($ids.Count) ottimizzazioni"; if ($undo) { $t = "Annullamento di $($ids.Count) ottimizzazioni" }
            if (Start-RWebTask 'tweaks' $t @{ Ids = $ids; Undo = $undo; Dns = $dns }) { Send-RWebJson $Ctx @{ ok = $true } } else { Send-RWebJson $Ctx $busy 409 }
        }
        'POST /api/toggle' {
            $id = [string]$b.id
            $t = @($cat.tweaks | Where-Object { $_.id -eq $id -and $_.type -eq 'Toggle' })
            if ($t.Count -ne 1) { Send-RWebJson $Ctx @{ error = 'id' } 400; return }
            $lbl = "$($t[0].name): disattivato"; if ([bool]$b.on) { $lbl = "$($t[0].name): attivato" }
            if (Start-RWebTask 'toggle' $lbl @{ Id = $id; On = [bool]$b.on }) { Send-RWebJson $Ctx @{ ok = $true } } else { Send-RWebJson $Ctx $busy 409 }
        }
        'POST /api/features' {
            $ids = Select-RWebIds $b.ids @($cat.features | Where-Object { -not $_.type } | ForEach-Object { $_.id })
            if ($ids.Count -eq 0) { Send-RWebJson $Ctx @{ error = 'Seleziona almeno una funzionalita''.' } 400; return }
            if (Start-RWebTask 'features' "Installazione di $($ids.Count) funzionalita'" @{ Ids = $ids }) { Send-RWebJson $Ctx @{ ok = $true } } else { Send-RWebJson $Ctx $busy 409 }
        }
        'POST /api/button' {
            $id = [string]$b.id
            if ((Get-RWebButtonIds) -notcontains $id) { Send-RWebJson $Ctx @{ error = 'id' } 400; return }
            if ($id -eq 'WPFInstallUpgrade') { $ok = Start-RWebTask 'upgrade' 'Aggiornamento di tutte le applicazioni' @{ Manager = 'Winget' } }
            else {
                $name = [string]$b.label; if (-not $name) { $name = $id }
                $ok = Start-RWebTask 'button' $name @{ Id = $id }
            }
            if ($ok) { Send-RWebJson $Ctx @{ ok = $true } } else { Send-RWebJson $Ctx $busy 409 }
        }
        'POST /api/manager' {
            $m = [string]$b.manager
            if ($m -in @('Winget', 'Choco')) { $sync.preferences.packagemanager = [PackageManagers]$m; try { Set-Preferences -save } catch { } }
            Send-RWebJson $Ctx @{ ok = $true }
        }
        'POST /api/classic' {
            Send-RWebJson $Ctx @{ ok = $true }
            $cmd = 'irm https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil.ps1 | iex'
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
        }
        'POST /api/exit' { Send-RWebJson $Ctx @{ ok = $true }; if ($st.Phase -ne 'running') { $st.Quit = $true } }
        default { Send-RWebJson $Ctx @{ error = 'not found' } 404 }
    }
}

function Find-RWebBrowser {
    $c = @()
    foreach ($b in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) { if ($b) { $c += Join-Path $b 'Microsoft\Edge\Application\msedge.exe' } }
    foreach ($b in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) { if ($b) { $c += Join-Path $b 'Google\Chrome\Application\chrome.exe' } }
    foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Start-WinRUtilWebApp {
    param([string]$Html, [switch]$NoBrowser, [int]$IdleTimeout = 25)
    $st = $script:RWebState
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($bytes); $rng.Dispose()
    $st.Token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $tl = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $tl.Start(); $st.Port = ([Net.IPEndPoint]$tl.LocalEndpoint).Port; $tl.Stop()
    $st.Catalog = Get-RWebCatalog
    $prefix = "http://localhost:$($st.Port)/"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    try { $listener.Start() } catch { Write-Host "Impossibile avviare l'interfaccia su $prefix : $($_.Exception.Message)" -ForegroundColor Red; return }
    $url = "$prefix#$($st.Token)"
    if ($NoBrowser) { $IdleTimeout = 900; Write-Host "WinRUtil web in ascolto: $url" }
    else {
        $st.Browser = Find-RWebBrowser
        $st.ProfileDir = Join-Path ([IO.Path]::GetTempPath()) ('WinRUtilUI_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
        if ($st.Browser) {
            $argList = @("--app=$url", "--user-data-dir=`"$($st.ProfileDir)`"", '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync', '--window-size=1320,900')
            $st.BrowserProc = Start-Process -FilePath $st.Browser -ArgumentList $argList -PassThru
        } else { Start-Process $url }
        Write-Host ''
        Write-Host '  WinRUtil e'' aperto nella sua finestra. Questa console si chiude da sola quando chiudi WinRUtil.' -ForegroundColor Green
    }
    try {
        while (-not $st.Quit) {
            $task = $listener.GetContextAsync()
            while (-not $task.AsyncWaitHandle.WaitOne(400)) {
                Update-RWebPhase
                $idle = ((Get-Date) - $st.LastActivity).TotalSeconds
                if ($st.Phase -ne 'running' -and $idle -gt $IdleTimeout) { $st.Quit = $true; break }
                if ($st.Quit) { break }
            }
            if ($st.Quit) { break }
            $ctx = $null
            try { $ctx = $task.GetAwaiter().GetResult() } catch { continue }
            try { Invoke-RWebRequest $ctx $Html } catch { try { Send-RWebJson $ctx @{ error = $_.Exception.Message } 500 } catch { } }
        }
    } finally {
        if ($st.Phase -eq 'running') {
            Write-Host '  Attendo la fine dell''operazione in corso...' -ForegroundColor Yellow
            while ($st.Handle -and -not $st.Handle.IsCompleted) { Start-Sleep -Milliseconds 500; Read-RWebStreams }
        }
        try { $listener.Stop(); $listener.Close() } catch { }
        Stop-RWebTask
        foreach ($q in @($st.Queries.Values)) { try { $q.PS.Dispose(); $q.RS.Close() } catch { } }
        if ($st.BrowserProc) { try { if (-not $st.BrowserProc.HasExited) { [void]$st.BrowserProc.CloseMainWindow() } } catch { } }
        if ($st.ProfileDir -and (Test-Path -LiteralPath $st.ProfileDir)) {
            Start-Sleep -Milliseconds 800
            try { Remove-Item -LiteralPath $st.ProfileDir -Recurse -Force -ErrorAction Stop } catch { }
        }
    }
}
