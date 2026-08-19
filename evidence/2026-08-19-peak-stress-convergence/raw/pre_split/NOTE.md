# The first pass: the global peak only

These fourteen runs are the S1 sweep as first written — same probe, same design,
same two arms, same resolutions — **before** the four-population peak split
existed. They are kept because they are what forced the split, and because the
top-level `s1_sweep.csv` reproduces every number in them.

What they showed, and why one number was not enough:

* the global peak is not monotone in `h` at all — smooth arm 0.04524 (64),
  0.03600 (80), 0.03185 (96), **0.07300 (112)**, 0.02290 (128), 0.03598 (144),
  0.04971 (160) MPa;
* every rung's peak sat on a voxel whose effective mask is `FrozenSolid` — the
  anchor pad, the load pad or the face protection — and never on a cell the level
  set controls;
* the `staircase` arm tracked the `smooth` arm to within 1% at every rung
  (0.03169 vs 0.03185 at 96, 0.02307 vs 0.02290 at 128), which is exactly what
  must happen when the peak is in the frozen set: the two arms stamp the frozen
  set identically and differ ONLY on the ACTIVE cells.

So the global peak measures the load-pad tagging, which is re-derived from the
CAD at every resolution, and says nothing about the level-set boundary. The
probe was extended to report the peak over the ACTIVE, CUT and FROZEN
populations separately, and the sweep re-run.
