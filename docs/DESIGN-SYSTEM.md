# WinRUtil — Design System

Generato con ui-ux-pro-max. Identità: vetro smerigliato + accento verde. Distinto da WinUtil (blu/CTT) e da MAS.

Due temi con la stessa identità, selezionabili dal pulsante in alto a destra (*Auto* segue la modalità app di Windows):

- **Scuro** — sfondo OLED, pannelli smerigliati, accento verde menta neon.
- **Chiaro** — superfici chiare, card bianche, accento verde smeraldo.

## Regole

- Tutti i colori sono token definiti in [`config/themes.json`](../config/themes.json) e usati nell'XAML come `{DynamicResource NomeToken}`: nessun colore scritto fisso nell'interfaccia, così il cambio tema aggiorna tutto senza riavviare.
- Ogni token colore è disponibile anche come `Color` con prefisso `C` (es. `CAccentColor`), per gradienti ed effetti.
- I colori impostati da PowerShell usano `SetResourceReference` con il nome del token, non pennelli creati da codice.

## Token principali

| Token | Scuro | Chiaro | Utilizzo |
|---|---|---|---|
| `WindowBackgroundStartColor` → `WindowBackgroundEndColor` | `#0B0E16` → `#07090F` | `#F8FAFC` → `#EEF2F6` | gradiente della finestra |
| `SidebarBackgroundColor` | `#26000000` | `#0A0F172A` | barra laterale |
| `GroupBorderBackgroundColor` | `#59161B26` | `#FFFFFF` | card e pannelli |
| `MainBackgroundColor` | `#E60B0E16` | `#FFFFFF` | pannelli, popup, campi di testo |
| `MainForegroundColor` | `#F8FAFC` | `#0F172A` | testo primario |
| `MutedForegroundColor` | `#8A93A6` | `#556275` | testo secondario ed etichette |
| `AccentColor` | `#3DF5A0` | `#047857` | icone, barre, valori evidenziati |
| `ToggleButtonOnColor` | `#3DF5A0` | `#059669` | interruttori attivi, voce di menu attiva |
| `ButtonBackgroundSelectedColor` | `#403DF5A0` | `#D1FAE5` | elementi selezionati (menu, righe) |
| `BorderColor` | `#3DF5A0` | `#D6DCE4` | bordi di finestra e card |
| `SuccessColor` / `WarningColor` / `DangerColor` | `#3DF5A0` / `#F5A623` / `#EF4444` | `#047857` / `#B45309` / `#DC2626` | stati e azioni pericolose |

## Effetti
- Finestra: gradiente lineare tra i due token di sfondo, angoli arrotondati (raggio 14) e bordo da 1px.
- Card/pannelli: raggio 12–16, riempimento `GroupBorderBackgroundColor`, bordo sottile da 1px.
- Voce di navigazione attiva: barra d'accento a sinistra e bagliore `AccentGlowColor` (opacità `AccentGlowOpacity`).

## Tipografia
- Font: **Inter** (fallback Segoe UI Variable, Segoe UI). Titoli 600–700, corpo 400, etichette 500.

## Accessibilità
- Testo primario, secondario e d'accento con contrasto ≥ 4.5:1 sulle superfici di entrambi i temi.
- L'accento è usato per riempimenti e indicatori sempre accompagnati da testo o icona, mai come unico segnale.
