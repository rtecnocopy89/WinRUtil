<div align="center">

# WinRUtil

**Un toolkit moderno per Windows — installa app, applica ottimizzazioni, gestisci aggiornamenti, stampanti e reti Wi-Fi e consegna al cliente il rapporto dell'intervento, da un'unica interfaccia glassmorphism.**

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
- **Installa** — installa e aggiorna applicazioni tramite WinGet o Chocolatey. "Aggiorna applicazioni" elenca gli aggiornamenti disponibili per tutti i programmi installati: scegli quali installare e segui l'esito di ognuno.
- **Ottimizza** — ottimizzazioni per privacy, prestazioni e qualità d'uso, con preset e annullamento con un clic, tutte descritte in italiano.
- **Configura** — attiva le funzionalità di Windows ed esegui le riparazioni (Windows Update, rete, controllo del sistema con CHKDSK, SFC e DISM, WinGet).
- **Aggiornamenti** — gestisci i criteri di Windows Update (predefinito / solo sicurezza / disabilitato).
- **Stampanti** — rileva le stampanti installate (driver, porta, stato, lavori in coda), installa/aggiorna i driver da un pacchetto INF, rimuovi i driver, riavvia lo spooler e svuota la coda di stampa.
- **Wi-Fi** — elenca le reti Wi-Fi salvate con la relativa password (nascosta finché non la mostri), copiale negli appunti, esportale in un file .zip e importale su un altro PC, oppure mostra il QR code di una rete: il telefono lo inquadra e si collega senza digitare la password. Il QR code si può salvare come immagine PNG da stampare, con il nome della rete e la password.
- **Rapporto** — prepara il rapporto di intervento da consegnare al cliente: intestazione della tua azienda, cliente, tecnico, dati del PC, elenco delle operazioni eseguite con WinRUtil nella sessione (app installate, ottimizzazioni, riparazioni, stampanti, Wi-Fi) con il loro esito, note e spazio per le firme. Il rapporto è una pagina HTML pronta da stampare o salvare in PDF; il tecnico e l'intestazione vengono ricordati per i rapporti successivi.

## Interfaccia

Tema scuro glassmorphism (sfondo OLED, pannelli smerigliati, accento verde menta neon) e tema chiaro abbinato, selezionabili dal pulsante in alto a destra: *Auto* segue la modalità app di Windows. Navigazione laterale e barra del titolo personalizzata. Realizzata con il design system `ui-ux-pro-max` — vedi [`docs/DESIGN-SYSTEM.md`](docs/DESIGN-SYSTEM.md).

### Scorciatoie da tastiera

| Tasti | Azione |
|---|---|
| `Alt+S` / `Alt+I` / `Alt+T` / `Alt+C` | Sistema / Installa / Ottimizza / Configura |
| `Alt+U` / `Alt+P` / `Alt+F` / `Alt+R` | Aggiornamenti / Stampanti / Wi-Fi / Rapporto |
| `Ctrl+F` / `Esc` | Cerca nell'elenco / azzera la ricerca e chiude il QR code |
| `Ctrl+Q` | Chiudi WinRUtil |

### Dati salvati

WinRUtil salva i suoi dati in `%LOCALAPPDATA%\WinRUtil`: le preferenze (`preferences.ini`), il registro di ogni avvio (`logs`) e il tecnico e l'intestazione del rapporto (`rapporto.json`). Al primo avvio le preferenze salvate dalle versioni precedenti in `%LOCALAPPDATA%\winutil` vengono copiate nella nuova cartella.

## Compilazione dai sorgenti

```powershell
git clone https://github.com/rtecnocopy89/WinRUtil
cd WinRUtil
.\Compile.ps1          # produce winrutil.ps1
.\Compile.ps1 -Run     # compila e avvia
```

Il file `winrutil.ps1` generato è ASCII puro, così funziona sia con `irm | iex` sia come file locale in Windows PowerShell 5.1 e PowerShell 7. I caratteri accentati in XAML e JSON vengono convertiti automaticamente; nel codice PowerShell vanno scritti con `[char]` (es. `"Modalit$([char]0x00E0)"`). La compilazione si interrompe se trova caratteri non ASCII.

## Crediti e Licenza

WinRUtil è basato su [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) ed è distribuito sotto **Licenza MIT**. L'avviso di copyright originale è mantenuto in [`LICENSE`](LICENSE). La scheda Sistema, la gestione delle stampanti e delle reti Wi-Fi, il rapporto di intervento e l'interfaccia glassmorphism sono aggiunte di questo progetto.
