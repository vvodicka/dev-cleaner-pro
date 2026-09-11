# Design source

Exported from Claude Design, project `e7b7a0f4-f843-4efc-9822-875ea034376e`.

| File | What it is |
|---|---|
| `DevSweep.dc.html` | The canvas: 10 annotated frames (1a–1j) plus the component spec in 1j |
| `DevSweepWindow.dc.html` | Parametric main-window component — `theme` x `mode` x `state` x `module` x `banner`. The `<script type="text/x-dc">` block at the bottom holds working tri-state selection logic (`toggleCheck`, `roll`, `selection`, `flatten`) that the Swift implementation mirrors. |
| `_ds/` | The corporate design system the canvas was authored in — **canvas chrome only**, it never enters the app. Not published with this repository, so the two `.dc.html` files render unstyled chrome locally; the frames themselves are unaffected. |
| `support.js`, `_ds_bundle.js` | Canvas runtime, needed only to render the HTML locally |

The filenames keep the original `DevSweep` name on purpose: renaming them would break the
`<dc-import name="DevSweepWindow">` link between the two canvases.

## What is authoritative here

Appearance, metrics, states, copy, and interaction rules. Module *content* comes from
`docs/03-modules-spec.md`. See `docs/00-decisions.md` for the resolved conflicts between the two.

## Colours: read this before implementing anything

The design's own intro states: *"App chrome uses the macOS system stack (SF Pro / SF Mono); brand
red #C1000D stands in for the system accent color"*, and the component spec adds *"Nothing is
hard-coded except the four badge hues."*

So `#C1000D` and `#1C2835` in these mockups are **placeholders for `.controlAccentColor` and the
system window/sidebar backgrounds** — not target colours. Only the four risk badge hues are real,
and they live in the asset catalog with Light/Dark variants. The app icon is original artwork — a broom over a disk
platter — and carries no corporate mark.
