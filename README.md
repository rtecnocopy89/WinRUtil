<div align="center">

# WinRUtil

**Un toolkit moderno per Windows — installa app, applica ottimizzazioni, gestisci gli aggiornamenti, crea un'immagine di Windows 11 e gestisci i driver delle stampanti, da un'unica interfaccia glassmorphism.**

</div>

## Distribuzione e Avvio Rapido

Per eseguire WinRUtil, apri una sessione di **PowerShell con privilegi di Amministratore** ed esegui il seguente comando:

```powershell
irm bit.ly/WinRUtil | iex
```

In alternativa, puoi usare il link diretto a GitHub:

```powershell
irm https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil.ps1 | iex
```

> Se PowerShell non è elevato, WinRUtil tenterà automaticamente di riavviarsi come Amministratore.

## Funzionalità

- **Sistema** — panoramica di Windows e attivazione, hardware (con Secure Boot, TPM e BitLocker), processore e memoria aggiornati in tempo reale, dischi (con stato di salute), grafica, rete, batteria e cronologia degli aggiornamenti di Windows con l'esito di ognuno (anche quelli non riusciti, con il codice di errore), con esportazione del report in HTML (pronto da stampare o salvare in PDF) o in testo.
- **Installa** — installa e aggiorna applicazioni tramite WinGet o Chocolatey.
- **Ottimizza** — ottimizzazioni per privacy, prestazioni e qualità d'uso, con preset e annullamento con un clic.
- **Configura** — abilita/disabilita le funzionalità di Windows.
- **Aggiornamenti** — gestisci i criteri di Windows Update (predefinito / solo sicurezza / disabilitato).
- **Stampanti** — rileva le stampanti installate (driver, porta, stato, lavori in coda), installa/aggiorna i driver da un pacchetto INF, rimuovi i driver, riavvia lo spooler e svuota la coda di stampa.
- **Wi-Fi** — elenca le reti Wi-Fi salvate con la relativa password (nascosta finché non la mostri), copiale negli appunti oppure esportale in un file .zip e importale su un altro PC.
- **Crea Win11** — crea un'immagine di Windows 11 personalizzata.

## Interfaccia

Tema scuro glassmorphism (sfondo OLED, pannelli smerigliati, accento verde menta neon) e tema chiaro abbinato, selezionabili dal pulsante in alto a destra: *Auto* segue la modalità app di Windows. Navigazione laterale e barra del titolo personalizzata. Realizzata con il design system `ui-ux-pro-max` — vedi [`docs/DESIGN-SYSTEM.md`](docs/DESIGN-SYSTEM.md).

### Scorciatoie da tastiera

| Tasti | Azione |
|---|---|
| `Alt+S` / `Alt+I` / `Alt+T` / `Alt+C` | Sistema / Installa / Ottimizza / Configura |
| `Alt+U` / `Alt+P` / `Alt+F` / `Alt+W` | Aggiornamenti / Stampanti / Wi-Fi / Crea Win11 |
| `Ctrl+F` / `Esc` | Cerca nell'elenco / azzera la ricerca |
| `Ctrl+Q` | Chiudi WinRUtil |

## Compilazione dai sorgenti

```powershell
git clone https://github.com/rtecnocopy89/WinRUtil
cd WinRUtil
.\Compile.ps1          # produce winrutil.ps1
.\Compile.ps1 -Run     # compila e avvia
```

Il file `winrutil.ps1` generato è ASCII puro, così funziona sia con `irm | iex` sia come file locale in Windows PowerShell 5.1 e PowerShell 7. I caratteri accentati in XAML e JSON vengono convertiti automaticamente; nel codice PowerShell vanno scritti con `[char]` (es. `"Modalit$([char]0x00E0)"`). La compilazione si interrompe se trova caratteri non ASCII.

## Crediti e Licenza

WinRUtil è basato su [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) ed è distribuito sotto **Licenza MIT**. L'avviso di copyright originale è mantenuto in [`LICENSE`](LICENSE). La gestione delle stampanti e l'interfaccia glassmorphism sono aggiunte di questo progetto.
