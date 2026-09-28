# 05 — Coupon testing: the rig, the test pieces, the data format

**Plain language:** the published data comes from one lab, one filament and one printer. To make the app's numbers trustworthy on *your* printer, you squash small test pucks on your own rig and feed the curves back into the app as "calibrated" data. This file says what to print, how to squash it, and what the file of results must look like so the app can read it.

---

## 1. The rig (as specified in chat, 2026-09-26)

- **Frame:** base plate, two posts (2040/4040 aluminium extrusion), top plate. Two linear rails (HGR15 preferred, MGN12 acceptable). The moving crossbar rides both rails.
- **Drive:** SFU1204 ball screw kit (BK10 fixed support, DSG12H nut housing), **hung from the top plate** so the screw stays out of the work zone. The sample sits directly under the screw axis. The BF10 isn't needed in this layout.
- **Motor:** geared NEMA17 (1.68 A, 48 mm).
  - 5.18:1 is enough for TPU up to ~1.5 kN.
  - 14:1 is needed if the rig will also crush PLA blocks (~4 kN). At that point the gearbox's own rating (~3 N·m) is the limit; check the listing.
- **Driver:** TMC2209 in **SpreadCycle** (not StealthChop), 1.2–1.4 A RMS, **IHOLD = IRUN** so it can't slip while paused under load (ball screws don't self-lock). Heatsink and fan.
- **Power:** enclosed 24 V ≥ 4.5 A (e.g. Mean Well LRS-100-24). Microcontroller powered over USB; common ground.
- **Force:** S-type load cell + HX711, **swappable by range**: ~50 kg for soft TPU, 200 kg for firm TPU, 5 kN for PLA. Recalibrate with known masses after every swap.
- **Machine compliance:** press once on a steel block and subtract that curve from every test. It matters for firm coupons.
- **Safety:** firmware force limit (1500 N for TPU sets) and a travel limit switch.

## 2. What to print

The authoritative list is `data/coupon_sets.json`. In brief:

| Set | Question | Pieces |
|---|---|---|
| **A** | Does TopOpt's generated 1-bead gyroid squish like slicer-infill gyroid at equal density? | TPU 95A, Ø29 × 12.5 mm, 15 / 25 / 35 %, two arms × 3 = **18** |
| **B** | Does your printer reproduce Iacob's table? | varioShore gyroid 20 %, 190 / 220 / 240 °C × 3 = **9** |
| **S** | Does a 2-bead wall behave like a 1-bead wall at the same density (scale test)? | TPU 95A, Ø58 × 25 mm (everything ×2), 15 / 25 % × 3 = **6** |
| **SW** | Does gyroid squash the same sideways (across the layers) as along them? Unlocks side faces from 'estimated'. | TPU 95A, 29 mm cubes, 15 / 25 / 35 %, sideways + vertical control × 3 = **18** |
| C | Strut lattices in FDM TPU | **deferred** (needs Kelvin / FCC / BCC generators) |
| D | PLA TPMS knockdown for Structural | **deferred** (needs 14:1 + 5 kN cell) |

Geometry matches Iacob (ISO 7743 cylinder) so results line up with the only tabulated dataset. At 15 % the 1-bead gyroid has only ~3.4 cells across 29 mm and ~1.3 cells through the core height. Record cells-across, and expect some size effect at the low-density end.

## 3. How to squash (matches Iacob so the numbers are comparable)

1. Condition the pieces: 24 h at room temperature after printing, dried filament, same lot for a whole set.
2. Measure each piece's mass, diameter and height before testing.
3. **Lubricate both platens** (Iacob did; ISO 7743 recommends it). Then run at **10 mm/min**, **4 load/unload cycles to 25 % nominal strain**. Record every cycle, loading and unloading, and log continuously.
4. Report **secant modulus at 10 % and 20 %** strain from the **4th loading cycle**, with the toe removed (extrapolate the linear part of the 4th-cycle start back to zero force and measure strain from there).
5. Optional: one extra cycle to 50 % strain, within the force limit, recorded separately. This is the first look at the plateau and densification the literature doesn't give.
6. Three pieces per condition. Report mean and relative SD.

## 4. Raw data file format (one CSV per piece)

```
# piece_id, set, arm, material_id, lot, nozzle_temp_c, flow_pct, nozzle_mm, topology, geometry_source,
# beads_per_wall, bead_width_mm, relative_density_target, relative_density_measured, cell_mm,
# diameter_mm, height_mm, skin_total_mm, mass_g, load_cell, printed_date, tested_date
time_s,crosshead_mm,force_n,cycle,direction
0.000,0.0000,0.00,1,load
...
```

The `#` header lines are key = value metadata; the columns are raw. `crosshead_mm` is already corrected for machine compliance, and the file says so in a `# compliance_corrected = true` line.

## 5. From raw data to the app

A processing step (C4 on the roadmap) converts each condition's three pieces into one `curve_table.schema.json` entry:
- tier `calibrated`;
- full loading curve points, e.g. every 1 % strain from the 4th cycle;
- the unloading curve;
- `strain_max_measured`;
- replicates and rel_sd.

These entries sit next to the literature ones, and the app prefers calibrated over literature for the same condition. The raw CSVs are kept as evidence and never edited.

**Maintainer-seeded rule:** calibrated tables are maintainer data, like `materials.json`. Agents can write the converter, but the committed tables are his.
