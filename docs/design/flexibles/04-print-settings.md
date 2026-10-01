# 04 — Print settings (and the G-code question)

**Plain language:** for normal flexible filaments, the app recommends slicer settings. For foaming "Air" filaments, softness depends on nozzle temperature. The honest way to vary it within one print is **layer by layer**, and the flow has to change *together* with the temperature, which slicers don't do on their own. Generating G-code is currently forbidden by ARCHITECTURE §2 until Nadim decides (00-decisions Q5). Until then the app recommends settings plus a per-layer temperature/flow table.

The maintainer prints on a **Bambu Lab X1C** and uses **Bambu Studio only (not OrcaSlicer)**. Recommendations must be expressed in Bambu Studio terms.

---

## 1. Settings for a TopOpt-generated flexible lattice (any filament)

| Setting (Bambu Studio) | Value | Why |
|---|---|---|
| Wall generator | **Arachne** | Prints one-bead-wide mesh walls as a single variable-width bead instead of dropping them. |
| Wall loops | 1 for 1-bead lattices, 2 for 2-bead | The lattice walls ARE the walls. |
| Sparse infill density | 0 % | Nothing to infill. The lattice is geometry. |
| Top / bottom shell layers | = skin layers in the file (default 4) | Matches the generated skins. |
| Line width | = the bead width the lattice was generated with | Otherwise the walls stop being "one bead". |
| Layer height | as generated (default 0.2 mm) | Coupons and literature are at 0.2 mm. |
| Supports | Off inside the lattice | Internal supports are trapped forever. |
| Filament path | External spool for soft TPU/PEBA. Only specific hard TPUs (e.g. Bambu TPU for AMS, 68D) go through the AMS. | Bambu TPU printing guide. |

## 2. Foaming ("Air") filaments — what every manufacturer agrees on

- **Softness is set by nozzle temperature,** with a large flow cut to compensate for expansion: about 55–70 % flow when fully foamed.
- **Retraction off** (eSUN, Siraya PEBA Air). Expect stringing.
- **One uniform speed for everything** (eSUN). Disable first-layer and small-area slowdowns, because speed changes change the foaming.
- Direct drive or a short filament path. **No AMS for foaming TPU.**
- **Dry thoroughly:** eSUN 55 °C for over 4 h; Siraya 70–80 °C for 4–6 h in an oven.
- **Hotend temperature:** long runs above ~250 °C need an all-metal hotend (eSUN warns about PTFE-lined hotends). The X1C nozzle is rated to 300 °C. Confirm that before recommending 260–270 °C.
- **Nozzle size matters:** a 0.6 mm nozzle foams more easily than a 0.4 mm (Siraya publishes separate tables). Record the nozzle in every calibration row.
- **Temperature → softness is NOT guaranteed monotonic.** varioShore lattices were stiffest at 190 °C, softest at 220 °C, and stiffer again at 240 °C (Iacob 2024).

Per-filament numbers are in `data/foaming_temperature_tables.csv` and `data/flexible_materials.seed.json`. Several manufacturer values conflict with each other; both values are recorded and flagged.

## 3. Varying softness inside one print

- **Grade in Z (per layer) with temperature. Grade in X/Y with geometry** (cell size / density).
  - Changing temperature within a layer is impractical: the hotend takes time to change temperature. No published time constant was found; the reviewer expects several to tens of seconds per 10 °C, unmeasured.
  - Measure it on the X1C: command a 20 °C step, time how long the displayed nozzle temperature takes to settle, and repeat for up and down. That time is the minimum layer time for a temperature change. Layers printed during the change are a mix.
- **Flow must change with temperature.** Bambu Studio can insert custom G-code at a chosen layer (layer slider), but it doesn't link a temperature change to a flow change.
  - Whether the Bambu firmware honours `M221` (flow %) is **unverified**; don't depend on it.
  - The firmware-independent way is to **rescale extrusion (E) values per layer** in a post-processing step, handling relative and absolute E correctly.
- **Research precedent that in-print graded foaming works:**
  - TEM-foamable TPE: controlling nozzle temperature *and* flow together gave density ranges up to 0.86 g/cm³ within a single print, with linear, concave and convex gradients, by inverting a density → (temperature, flow) model. The density vs temperature curve fits a Gompertz (S-shaped) function.
  - arXiv 2607.25326 builds the target-Shore → temperature → flow-compensation pipeline for varioShore and compiles it into slicer projects.
  - arXiv 2505.08093 notes most prior work used discrete regions rather than continuous gradients.

## 4. The G-code decision (Q5)

ARCHITECTURE §2: *"Not a slicer. We recommend settings; we do not generate G-code."* The draft DECISIONS entry (00-decisions §4) offers two options:

- **(a) Amend §2 for this stage.** TopOpt post-processes the slicer's G-code: it inserts temperature changes at layer boundaries and rescales E per layer. TopOpt still never slices.
- **(b) No G-code in v1.** The app shows a per-layer table ("layers 1–20: 220 °C at 72 % flow; layers 21–40: 190 °C at 110 % flow…") that the user enters as custom G-code at those layers in Bambu Studio. Note that under (b), flow can't follow unless `M221` works on the X1C.

Until the maintainer chooses and commits the entry, **no agent writes a G-code emitter.**
