# Avvio della variante con interfaccia HTML (winrutil-web.ps1)
if (-not ('PackageManagers' -as [type])) {
    Add-Type @"
public enum PackageManagers
{
    Winget,
    Choco
}
"@
}

$PARAM_NOUI = $true
$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}
try { Set-Preferences } catch { }
if (-not $sync.preferences.packagemanager) { $sync.preferences.packagemanager = [PackageManagers]::Winget }

$Host.UI.RawUI.WindowTitle = "WinRUtil (Admin) - interfaccia web"
Show-WinRUtilLogo
Start-WinRUtilWebApp -Html $WinRUtilWebHtml -NoBrowser:($env:WINRUTIL_WEB_NOBROWSER -eq '1')
try { Stop-Transcript | Out-Null } catch { }
