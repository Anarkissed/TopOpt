# ★ THE POSITIVE CONTROL FOR THE WHOLE SURFACE PIPELINE

Every arm's surface row travels a path SIMP's own rows do not:

    arm:   design.bin -> design_rung_dump -> rung_0.68.f64 -> "arm=" external field
    SIMP:  design.bin -> the probe's own internal read

If that extra hop moved a number, every comparison in Table 1 would carry a
pipeline artefact that looks exactly like a design difference — and nothing in
the table would say so.

So SIMP's OWN rung 0.68 was dumped and handed back in as an arm called
`check_r068`, in the same invocation as SIMP's internal rows:

| | CAD mm | carved deg | sub-voxel mm |
|---|---|---|---|
| SIMP 0.68 (internal) | 0.4293 | 7.5521 | 0.1297 |
| `check_r068` (round-tripped) | **0.4293** | **7.5521** | **0.1297** |
| difference | **+0.0** | **+0.0** | **−0** |

★ **THE ROUND TRIP IS EXACT.** Any difference an arm shows in Table 1 is the
DESIGN and not the road it travelled to be measured.

This is the check `comparison-bars-need-positive-controls` exists to force: three
columns agreeing to four decimals is only meaningful if a column CAN move.
