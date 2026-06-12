<div align="center">

# WinRUtil

**Un toolkit moderno per Windows — installa app, applica ottimizzazioni, gestisci gli aggiornamenti, crea un'immagine di Windows 11 e gestisci i driver delle stampanti, da un'unica interfaccia glassmorphism.**

</div>

## Distribuzione e Avvio Rapido

Per eseguire WinRUtil, apri una sessione di **PowerShell con privilegi di Amministratore** ed esegui il seguente comando:

```powershell
irm https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil.ps1 | iex
```

> Se PowerShell non è elevato, WinRUtil tenterà automaticamente di riavviarsi come Amministratore.

## Funzionalità

- **Installa** — installa e aggiorna applicazioni tramite WinGet o Chocolatey.
- **Ottimizza** — ottimizzazioni per privacy, prestazioni e qualità d'uso, con preset e annullamento con un clic.
- **Configura** — abilita/disabilita le funzionalità di Windows.
- **Aggiornamenti** — gestisci i criteri di Windows Update (predefinito / solo sicurezza / disabilitato).
- **Stampanti** — rileva le stampanti installate (driver, porta, stato, lavori in coda), installa/aggiorna i driver da un pacchetto INF, rimuovi i driver, riavvia lo spooler e svuota la coda di stampa.
- **Crea Win11** — crea un'immagine di Windows 11 personalizzata.

## Interfaccia

Tema dark glassmorphism (sfondo OLED, pannelli smerigliati, accento verde menta neon), navigazione laterale e barra del titolo personalizzata. Realizzata con il design system `ui-ux-pro-max` — vedi [`docs/DESIGN-SYSTEM.md`](docs/DESIGN-SYSTEM.md).

## Compilazione dai sorgenti

```powershell
git clone https://github.com/rtecnocopy89/WinRUtil
cd WinRUtil
.\Compile.ps1          # produce winrutil.ps1
.\Compile.ps1 -Run     # compila e avvia
```

## Crediti e Licenza

WinRUtil è basato su [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) ed è distribuito sotto **Licenza MIT**. L'avviso di copyright originale è mantenuto in [`LICENSE`](LICENSE). La gestione delle stampanti e l'interfaccia glassmorphism sono aggiunte di questo progetto.
