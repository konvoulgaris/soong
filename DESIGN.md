# Design

Visual language for this repository, themed after Lt. Commander Data (Star
Trek: TNG). Terminal tools and docs should draw from this palette so output
reads as one system.

## Palette

Data's operations-gold uniform, pale android complexion, and the black of a
starship interior.

| Token       | Role                          | Hex       | 256-color | Basic ANSI |
| ----------- | ----------------------------- | --------- | --------- | ---------- |
| `gold`      | Primary accent, highlights    | `#C8A24B` | `179`     | `33` (yel) |
| `gold-dim`  | Secondary accent, borders     | `#9A7B34` | `136`     | `33`       |
| `skin`      | Body text, foreground         | `#E8D9C0` | `223`     | `37` (wht) |
| `hair`      | Muted text, metadata          | `#6B4E36` | `94`      | `90`       |
| `black`     | Backgrounds, deep fills       | `#0E0E10` | `232`     | `30`       |
| `positron`  | Success, safe-to-remove       | `#7FB77E` | `108`     | `32` (grn) |
| `alert`     | Danger, destructive actions   | `#B4432E` | `130`     | `31` (red) |
| `caution`   | Warnings, dirty/kept items    | `#C8A24B` | `179`     | `33`       |

## Terminal usage

Prefer 256-color SGR codes (`ESC[38;5;<n>m`); fall back to basic ANSI where a
terminal lacks 256-color support.

```
gold      ESC[38;5;179m
gold-dim  ESC[38;5;136m
skin      ESC[38;5;223m
hair      ESC[38;5;94m
positron  ESC[38;5;108m
alert     ESC[38;5;130m
```

- **gold** carries the brand: titles, active selection, progress bars, key figures.
- **skin** is the default readable foreground; never pure white.
- **hair** for paths, timestamps, and other secondary detail.
- **positron** only for safe/success states; **alert** only for destructive ones.
- Reserve inverse video (`ESC[7m`) for the focused row in interactive lists.

## Principles

- One accent (gold) does the heavy lifting; color is a signal, not decoration.
- Danger and safety colors are earned — they mean something, so stay rare.
- Match the surrounding output's density; don't over-paint.
