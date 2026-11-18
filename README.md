<div align="center">

# WinRUtil

**Il toolkit per i tecnici Windows: installa app, ottimizza, ripara, controlla la sicurezza del PC e consegna al cliente il rapporto dell'intervento, da un'unica finestra.**

</div>

## Avvio

In PowerShell come **Amministratore**:

```powershell
irm bit.ly/WinRUtil | iex
```

Il link corto punta a `https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil.ps1`. Se PowerShell non è elevato, WinRUtil si riavvia da solo come Amministratore.

## Schede

| Scheda | Cosa fa |
|---|---|
| **Sistema** | Windows e attivazione, hardware (Secure Boot, TPM, BitLocker), CPU e memoria in tempo reale, dischi con stato di salute, rete, batteria, cronologia degli aggiornamenti con i codici di errore. Esporta il report in HTML o testo. |
| **Installa** | Oltre 230 applicazioni tramite WinGet o Chocolatey, con filtri per categoria e ricerca. *Aggiorna applicazioni* elenca gli aggiornamenti di tutti i programmi installati e installa quelli scelti. |
| **Ottimizza** | Ottimizzazioni per privacy, prestazioni e uso quotidiano, con i preset Standard, Minima e Avanzata e annullamento con un clic. DNS anche sul più veloce misurato al momento, con DNS-over-HTTPS. |
| **App di Windows** | Rimuove le app preinstallate (Copilot, Xbox, Notizie, Meteo, Clipchamp...) per tutti gli utenti, anche futuri, o le reinstalla. |
| **Configura** | Funzionalità di Windows, pannelli classici e riparazioni: Windows Update, rete, CHKDSK, SFC e DISM con la spiegazione degli errori, WinGet. |
| **Aggiornamenti** | Criteri di Windows Update (predefinito, solo sicurezza, disabilitato) senza toccare gli altri criteri, ad esempio WSUS. |
| **Stampanti** | Stampanti installate con driver, porta, stato e coda; installa o rimuove driver INF, riavvia lo spooler, svuota la coda. |
| **Wi-Fi** | Reti salvate con la password, copia, esportazione e importazione su un altro PC, QR code per collegare un telefono (anche come immagine da stampare). |
| **Sicurezza** | Analisi in sola lettura dei PC usati per l'home banking: trova le cause delle frodi sui bonifici (IBAN sostituito, credenziali rubate). Vedi sotto. |
| **Rapporto** | Rapporto di intervento per il cliente: intestazione dell'azienda, cliente, tecnico, dati del PC, operazioni eseguite nella sessione con il loro esito, note e firme. Pagina HTML da stampare o salvare in PDF. |

## Sicurezza

Tre analisi:

- **Analisi completa** (3-10 minuti): estensioni dei browser e loro provenienza, codice iniettato nella memoria del browser (trojan come Ramnit con il kit drIBAN), programmi all'avvio e persistenza, comandi incollati in Esegui (ClickFix), controllo remoto con i log delle connessioni, proxy, file hosts, DNS, ARP, certificati, eventi di sicurezza, antivirus, impostazioni di sicurezza con punteggio da 0 a 100 e test degli appunti. *Analisi rapida* salta la scansione della memoria.
- **Test degli appunti** (30 secondi): copia un IBAN di prova e verifica che nessun programma lo cambi.
- **Monitor durante il bonifico** (10-60 minuti): avvisa subito se qualcosa modifica l'IBAN negli appunti, il proxy o il file hosts mentre il cliente esegue il bonifico.

Come problemi vengono segnalate solo cose certe:

| Esito | Significato |
|---|---|
| **CONFERMATO** | indicatore specifico di attacco o manomissione, che un software legittimo non produce |
| **DA CONTROLLARE** | fatto certo che può avere una spiegazione legittima (es. *AnyDesk è installato*) |
| **DA CORREGGERE** | impostazione di sicurezza sbagliata (firewall spento, Windows non supportato, macro abilitate...) |
| **DETTAGLIO** | tutto il resto, nascosto finché non lo chiedi |

Se meno dell'80% dei controlli riesce, il giudizio è *Analisi incompleta*: WinRUtil non dichiara mai "tutto a posto" senza aver controllato. Nessun dato lascia il PC (tranne il confronto dei DNS della banca con DNS pubblici, disattivabile). Ogni analisi produce un rapporto HTML, i CSV di dettaglio, `SHA256SUMS.txt` e uno ZIP da conservare come prova; il rapporto si apre in una finestra di Edge o Chrome con profilo temporaneo ed estensioni disattivate. Ripetendo l'analisi sullo stesso PC, ciò che è comparso dall'ultima volta è indicato come **NUOVO**.

Con *Banche ed elementi autorizzati* si modifica `config.json`: i domini della banca da sorvegliare (`BankDomains`) e gli elementi verificati che non vanno più segnalati (`AllowExtensionIds`, `AllowRemoteTools`, `AllowCertThumbprints`, `AllowPaths`).

Nessuno strumento automatico trova tutto: se il rapporto è pulito ma il problema continua, servono una scansione offline (Microsoft Defender Offline) e i log della banca.

## Scorciatoie da tastiera

| Tasti | Azione |
|---|---|
| `Alt+S` `Alt+I` `Alt+T` `Alt+A` `Alt+C` | Sistema, Installa, Ottimizza, App di Windows, Configura |
| `Alt+U` `Alt+P` `Alt+F` `Alt+B` `Alt+R` | Aggiornamenti, Stampanti, Wi-Fi, Sicurezza, Rapporto |
| `Ctrl+F` / `Esc` | Cerca nell'elenco / azzera la ricerca e chiude le finestre sovrapposte |
| `Ctrl++` `Ctrl+-` `Ctrl+0`, `Ctrl`+rotellina | Dimensione del testo |
| `Ctrl+Q` | Chiudi |

## Parametri

```powershell
& ([ScriptBlock]::Create((irm bit.ly/WinRUtil))) -Preset Standard -Run
```

| Parametro | Effetto |
|---|---|
| `-Preset Standard\|Minimal\|Advanced` | seleziona le ottimizzazioni del preset |
| `-Config <file>` | importa le selezioni esportate con *Impostazioni > Esporta* |
| `-Run` | applica preset e configurazione senza altri clic; con `-Sicurezza` avvia l'analisi completa |
| `-Sicurezza` | apre la scheda Sicurezza |
| `-Noui` | lavora in console senza finestra (con `-Sicurezza` esegue l'analisi completa in console) |
| `-Offline` | disattiva la scheda Installa |

## Dati salvati

Tutto resta in `%LOCALAPPDATA%\WinRUtil`: preferenze (`preferences.ini`), registro di ogni avvio (`logs`), tecnico e intestazione del rapporto (`rapporto.json`) e, in `Sicurezza`, `config.json` e i rapporti delle analisi (`Report`). La configurazione del vecchio CyberRSecurityCheck, se presente, viene ripresa al primo utilizzo.

## Sviluppo

```powershell
git clone https://github.com/rtecnocopy89/WinRUtil
cd WinRUtil
.\Compile.ps1                                  # crea winrutil.ps1 (con -Run lo avvia)
powershell -File .\tests\Test-Security.ps1     # test del motore di sicurezza e del file compilato
```

| Percorso | Contenuto |
|---|---|
| `scripts/` | avvio (parametri, elevazione) e creazione della finestra |
| `functions/` | funzioni delle schede |
| `config/` | catalogo app, ottimizzazioni, preset, temi |
| `xaml/inputXML.xaml` | interfaccia |
| `security/` | motore dell'analisi di sicurezza e configurazione predefinita, incorporati così come sono |
| `tests/` | test automatici |

`winrutil.ps1` è ASCII puro e funziona sia con `irm | iex` sia come file locale in Windows PowerShell 5.1 e PowerShell 7: nel codice PowerShell i caratteri accentati si scrivono con `[char]` (es. `"Modalit$([char]0x00E0)"`), in XAML e JSON vengono convertiti automaticamente. La compilazione si interrompe se trova caratteri non ASCII. Il design dell'interfaccia è descritto in [`docs/DESIGN-SYSTEM.md`](docs/DESIGN-SYSTEM.md).

## Crediti e licenza

Basato su [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil), distribuito sotto **licenza MIT** con l'avviso di copyright originale in [`LICENSE`](LICENSE). Le schede Sistema, Stampanti, Wi-Fi, Sicurezza e Rapporto e l'interfaccia sono aggiunte di questo progetto; le novità di winutil vengono riportate e tradotte in italiano.
