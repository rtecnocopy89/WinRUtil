# WinRUtil — Design System (Dark Glassmorphism)

Generato con ui-ux-pro-max. Identità: OLED dark + vetro smerigliato + accento neon. Distinto da WinUtil (blu/CTT) e da MAS.

## Token

| Token | Valore | Utilizzo |
|---|---|---|
| bg-deep | `#07090F` | base del gradiente della finestra |
| bg-base | `#0B0E16` | parte centrale del gradiente della finestra |
| bg-elevated | `#121724` | pannelli solidi, menu a tendina |
| glass-surface | `#59161B26` | riempimento smerigliato di card/pannelli (~35% α) |
| glass-surface-hover | `#26FFFFFF` | riempimento al passaggio del mouse (bianco ~15%) |
| glass-border | `#1AFFFFFF` | bordo sottile (bianco 10%) |
| foreground | `#F8FAFC` | testo primario |
| foreground-muted | `#8A93A6` | testo secondario |
| accent (neon) | `#3DF5A0` | toggle attivi, CTA, navigazione attiva, bagliore di focus |
| accent-strong | `#2BD389` | accento premuto |
| accent-glow | `#663DF5A0` | alone di bagliore dietro gli elementi attivi |
| ambient-indigo | `#5E6AD2` | macchia atmosferica di sfondo |
| destructive | `#EF4444` | azioni pericolose |

## Effetti
- Finestra: gradiente radiale/lineare `#0B0E16 → #07090F` + DWM Acrylic (Win11) per una vera sfocatura dello sfondo.
- Macchie ambientali: 2 gradienti radiali (indaco + verde), opacità bassa (~0.10), dietro al contenuto.
- Card/pannelli: raggio 14, riempimento vetro, bordo sottile da 1px, leggera luce interna superiore.
- Movimento: 150–250ms, easing cubic-bezier(0.16,1,0.3,1); scala 0.97→1.0 alla pressione; bagliore d'accento al passaggio del mouse/attivazione.

## Tipografia
- Font: **Inter** (fallback Segoe UI Variable, Segoe UI). Titoli 600–700, corpo 400, etichette 500.

## Accessibilità
- Il testo (foreground) su vetro ha contrasto ≥ 4.5:1 (verificato rispetto a bg-base). L'accento `#3DF5A0` è usato per riempimenti/indicatori, sempre accompagnato da testo/icona — mai solo come colore.
