<div align="center">

# WinRUtil

**A modern Windows toolkit — install apps, apply tweaks, manage updates, build a Windows 11 image, and handle printer drivers, from one glassmorphism UI.**

</div>

## Launch

Open **PowerShell as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/main/winrutil.ps1 | iex
```

> If PowerShell is not elevated, WinRUtil will attempt to relaunch itself as Administrator automatically.

## Features

- **Install** — install and upgrade applications via WinGet or Chocolatey.
- **Tweaks** — privacy, performance and quality-of-life tweaks, with presets and one-click undo.
- **Config** — enable/disable Windows features.
- **Updates** — manage the Windows Update policy (default / security-only / disabled).
- **Printers** — detect installed printers (driver, port, status, queued jobs), install/update drivers from an INF package, remove drivers, restart the spooler and clear the print queue.
- **Win11 Creator** — build a customized Windows 11 image.

## UI

Dark glassmorphism theme (OLED background, frosted panels, neon-mint accent), sidebar navigation, and a custom title bar. Built with the `ui-ux-pro-max` design system — see [`docs/DESIGN-SYSTEM.md`](docs/DESIGN-SYSTEM.md).

## Build from source

```powershell
git clone https://github.com/rtecnocopy89/WinRUtil
cd WinRUtil
.\Compile.ps1          # produces winrutil.ps1
.\Compile.ps1 -Run     # build and launch
```

## Credits & License

WinRUtil is based on [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) and is distributed under the **MIT License**. The original copyright notice is retained in [`LICENSE`](LICENSE). Printer management and the glassmorphism UI are additions in this project.
