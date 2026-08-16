# §0 — THE TOPOLOGY SCREEN, READ OFF THE SCREENSHOT

Screenshot: `topology_page.png` (iPad Pro 11-inch M5, 1668×2420 px = 834×1210 pt,
2× scale). Crops: `crop_top.png`, `crop_bottomright.png`.

Captured from the shipped build at base commit `247a6bbc` (PR 331 + PR 334
merged), project "Wall Bracket (round2)", stage = `.topology`.

★ THIS IS THE LIST. Every control this task adds or touches is checked against it,
one line each, in the handoff. A control that does not match is a DEFECT.

---

## THE RULES

Each rule names the token, its value, and the source line the value is read from —
so a check is a `grep`, not an opinion.

| # | rule | value | source |
|---|---|---|---|
| **S1** | Round icon button (back / undo / redo) is a **circle, 42 × 42** | `frame(width: 42, height: 42)` | `WorkspacePlaceholder.swift:1550`, `:1607` |
| **S2** | A top-bar **capsule** row (project name + material) is `Capsule()`, vertical padding **9**, horizontal padding **16** (`DS.Space.l`) | 9 / 16 | `WorkspacePlaceholder.swift:1575-1577` |
| **S3** | Top-bar surface fill is **`DS.Surface.bar`** = `rgba(28,28,34,0.60)`, hairline **`textPrimary.opacity(0.12)`, 1 pt** | — | `WorkspacePlaceholder.swift:1551-1552`, `:1576-1577` |
| **S4** | The top row starts at **top 22** (`DS.Space.xl3`), **leading 24** (`DS.Space.xl4`) | 22 / 24 | `WorkspacePlaceholder.swift:1590-1591` |
| **S5** | Inter-control gap in the top row is **12** (`DS.Space.m`) | 12 | `WorkspacePlaceholder.swift:1545` |
| **S6** | A **bottom-right settings chip** is a `Capsule`, vpad **9**, leading **16**, trailing **9**, `DS.Surface.bar` fill + the same 0.12 hairline | 9/16/9 | `WorkspacePlaceholder.swift:2827-2830` (`gravityChip`) |
| **S7** | Chip **icon tint is `DS.Color.accent` = `#0A84FF`** — the dark blue. This is the gravity icon §4(a) names | `#0A84FF` | `DesignSystem.swift:88`; used `WorkspacePlaceholder.swift:2802` |
| **S8** | The bottom-right stack is **trailing-anchored**, chips spaced **8** (`DS.Space.s`), inset **trailing 24**, **bottom 24 + 50 + 12** to clear Optimize | 8 / 24 | `WorkspacePlaceholder.swift:2491-2499` |
| **S9** | Chips are ordered **smallest measured width at the top → largest at the bottom** (`BottomChipOrder`) | — | `WorkspacePlaceholder.swift:2493` |
| **S10** | The **orientation gizmo is 210 pt square, absolute top-right, inset 8 on both edges**, and NEVER MOVES on any page | 210 / 8 | `PageChrome.swift:223-227` |
| **S11** | Any top-right chrome must stay **`gizmoClearance` = 210 + 2×8 = 226 pt** clear of the right edge | 226 | `PageChrome.swift:230` |
| **S12** | The **left modal is centre-left, vertically centred in the band below the identity rows, touching neither top nor bottom**; width **348** | 348 | `PageChrome.swift:212`, `PageLeftModal.swift`, `WorkspacePlaceholder.swift:4281`, `:4301` |
| **S13** | Panel / popover corner radius is **20** (`DS.Radius.panelSmall`); panel **22**; a chip/pill is **`Capsule`** (radius 999) | 20 / 22 / 999 | `DesignSystem.swift:156-166` |
| **S14** | Panel surface is **`DS.Surface.panel`** = `rgba(24,24,30,0.62)` + **`DS.Color.strokePanel`** = `rgba(255,255,255,0.11)` hairline, 1 pt | — | `WorkspacePlaceholder.swift:4282-4284` |
| **S15** | **A CHIP is a control** (Capsule, `fillSelected` when on, tinted stroke). **A READOUT is bare text** — no capsule, no stroke, `textSecondary`. The drawer enforces this: a row that is not `modifiable` gets no gesture and no control chrome | — | `WorkspacePlaceholder.swift:4682-4694`; rule stated `LatticeRegionDrawer.swift:22-25` |
| **S16** | Verdict colour vocabulary: **ok `#30D158`**, **warning `#FF9F0A`**, **danger `#FF453A`**, muted `textQuaternary` | — | `DesignSystem.swift:64-69`; mapped `WorkspacePlaceholder.swift:4933-4939` |
| **S17** | The primary action (**Optimize**) is bottom-right, **`DS.Color.accent` blue**, two-line (title + subtitle) | `#0A84FF` | bottom bar, `WorkspacePlaceholder.swift:5589+` |
| **S19** | ★ **NAVIGATION IS A DARKER BLUE THAN ACTION, AND IT IS A PAIR.** The three stage buttons — "Lattice", "Topology", "Settings" — wear **`DS.Color.accentDeep` `#004080`** with a 1.5 pt **`DS.Color.accentDeepEdge` `#3D8FD6`** hairline, never `accent`. Same hue as accent (210°), half its lightness (max channel 128 vs 255); the lighter rim stops the deep fill reading as a flat slab. An ACTION button runs something; a NAVIGATION button takes you somewhere. Measured on device: fill `rgb(2,65,130)` vs Optimize's `rgb(10,132,255)` | `#004080` + `#3D8FD6` | `DesignSystem.swift` `accentDeep` / `accentDeepEdge`; used `WorkspacePlaceholder.swift` `stageNavButton`, `latticeSettingsButtonOverlay` |
| **S20** | ★ **THE TOP-RIGHT SLOT HOLDS EXACTLY ONE BUTTON PER PAGE**, left of the gizmo by `gizmoClearance` (226) with its top edge on `gizmoInset` (8) — **never vertically centred on the gizmo**. TO page: "Lattice". Lattice page: "Settings" | 226 / 8 | `PageChrome.swift:227-230`; `StageNavPlacement` |
| **S21** | ★ **A BACK-TO-PREVIOUS-PAGE BUTTON SITS TOP-LEFT, UNDER THE PROJECT NAME**, on the identity row's own `DS.Space.xl4` leading inset, one `PageChrome.gap` below it, and **as thin as the name capsule** (`.padding(.vertical, 9)` around `bodyStrong`) | 24 / 12 / 9 | `StageNavPlacement`, `StageNavChrome` |
| **S22** | ★ **THE WIZARD IS TWO VIEWS, NOT A WIZARD.** "One cell" (Type, Thickness) and "In the part" (Cell size + its number, Density, Finish), switched by a segment at the BOTTOM of the one modal. Finish is a setting of the second view, never a third view | — | `LatticeWizardStage`, `LatticeSetupWizard.viewSwitcher` |
| **S23** | ★ **A CELL DIMENSION IS ASKED FOR ONCE**, by the Cell size row: Auto shows nothing, Fixed one field, Swept a range | — | `LatticeSetupWizard.settingControl(.cellSize)` |
| **S24** | ★ **A SETTINGS MODAL HUGS ITS CONTENT AND SITS FLUSH WITH THE PAGE'S PRIMARY ACTION.** No `ScrollView` (it would take all the offered height); bottom inset equals the leading inset, `PageChrome.edge` (24). Measured: modal bottom 1165.5 pt, Save & Exit bottom 1165.5 pt | 24 | `WizardModalPlacement` |
| **S25** | ★ **THE DEFAULT SELECTION LEADS ITS PICKER.** `LatticeType.family` starts with `octet` — the default — so the picker never opens showing six types the user did not choose | — | `LatticeType.family` |
| **S18** | Body text ramp: primary `#F2F2F5`, secondary 0.55, tertiary 0.45, quaternary 0.40, disabled 0.35 | — | `DesignSystem.swift:76-83` |

---

## WHAT THE SCREENSHOT ALREADY CONVICTS (§4, before any edit)

Read directly off `crop_top.png`:

* **The "Lattice" button is GREEN** — `DS.Color.accentGreen` `#30D158`
  (`WorkspacePlaceholder.swift:2426`). §4(a)/(c): not green.
* **It is 64 pt tall** (`.frame(height: 64)`, `:2424`) against the top-bar
  controls' **42** (S1). His words: "nowhere near that tall". A **1.52×**
  discrepancy, and it is the tallest thing on the top row.
* **It sits TOP-RIGHT**, padded `gizmoClearance` left of the gizmo (`:2437`).
  §4(b) puts the *Lattice* button in the **bottom-right stack** instead.
* **The lattice Settings button is PURPLE** —
  `LatticeDensityProxy.densityColor(fraction: 0.75)` (`:2454`), which is a point
  on the density ramp, not a chrome colour. §4(c): "The purple fucking colour
  should never happen again."

Read off `crop_bottomright.png`: the bottom-right stack is
`0 mm` · `Paint` · `Fast · 64³` · `Design Box` (+ drawer) · `Minimize plastic` ·
`Plate up +Y` · `Gravity set / Change`, every one a `DS.Surface.bar` capsule with
an accent-blue icon — **which is the shape and colour §4 asks the two stage
buttons to adopt.**
