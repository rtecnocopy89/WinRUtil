# WinRUtil — Design System (Dark Glassmorphism)

Generated with ui-ux-pro-max. Identity: OLED dark + frosted glass + neon accent. Distinct from WinUtil (blue/CTT) and MAS.

## Tokens

| Token | Value | Use |
|---|---|---|
| bg-deep | `#07090F` | window gradient bottom |
| bg-base | `#0B0E16` | window gradient mid |
| bg-elevated | `#121724` | solid panels, combos |
| glass-surface | `#59161B26` | frosted card/panel fill (~35% α) |
| glass-surface-hover | `#26FFFFFF` | hover fill (white ~15%) |
| glass-border | `#1AFFFFFF` | hairline border (white 10%) |
| foreground | `#F8FAFC` | primary text |
| foreground-muted | `#8A93A6` | secondary text |
| accent (neon) | `#3DF5A0` | toggles on, CTAs, active nav, focus glow |
| accent-strong | `#2BD389` | pressed accent |
| accent-glow | `#663DF5A0` | glow halo behind active elements |
| ambient-indigo | `#5E6AD2` | atmospheric background blob |
| destructive | `#EF4444` | danger actions |

## Effects
- Window: radial/linear gradient `#0B0E16 → #07090F` + DWM Acrylic (Win11) for real backdrop blur.
- Ambient blobs: 2 radial gradients (indigo + green), low opacity (~0.10), behind content.
- Cards/panels: radius 14, glass fill, 1px hairline border, subtle inner top highlight.
- Motion: 150–250ms, easing cubic-bezier(0.16,1,0.3,1); scale 0.97→1.0 on press; accent glow on hover/active.

## Type
- Font: **Inter** (fallback Segoe UI Variable, Segoe UI). Headings 600–700, body 400, labels 500.

## Accessibility
- foreground on glass ≥ 4.5:1 (verified against bg-base). accent `#3DF5A0` used for fills/indicators, paired with text/icon — never color-only.
