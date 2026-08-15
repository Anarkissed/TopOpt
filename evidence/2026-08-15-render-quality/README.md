# evidence · 2026-08-15-render-quality

Handoff: [`docs/handoffs/2026-08-15-render-quality.md`](../../docs/handoffs/2026-08-15-render-quality.md)

Everything here is produced by
`app/TopOptKit/Tests/TopOptFlowsTests/RenderQualityEvidenceGen.swift`:

```bash
cd app/TopOptKit && TOPOPT_RENDER_QUALITY_EVIDENCE=1 swift test --filter RenderQualityEvidenceGen
```

Console output of the run these files came from: `render_quality_run.txt`
(GPU: Apple M2 Pro).

## The pictures

Three parts, all his. Nine configurations each, at 1024², **same camera, same clear
colour** — only `MeshRenderer.quality` (and, for the MSAA rows, the sample count) differs.
Each configuration adds exactly one item to the one before it, so **any two adjacent
files are that item's before/after pair**.

| prefix | part |
|---|---|
| `lattice_*` | the wizard's lattice sample at **his 2 mm cell** — 118,920 triangles, exactly the count in the readout he quoted |
| `bracket_*` | `core/tests/fixtures/mesh/WallMount_ShelfBracket.stl` — his own bracket |
| `to_*` | a topology-optimised result on that bracket, from `topopt-cli run` (see `content/`) |

| suffix | what it adds |
|---|---|
| `00_before` | nothing — **the shipped renderer** |
| `01_ao_low` | §1 SSAO, 8 samples |
| `02_ao` | §1 SSAO, 16 samples (production) |
| `03_light` | §2 world-space key/fill/rim **alone**, without AO |
| `04_ao_light` | §1 + §2 |
| `05_msaa` | §3b 4× MSAA |
| `06_edges` | §3a silhouette + crease lines |
| `07_shadow` | §3c contact shadow |
| `08_all` | §3d depth fade — everything on |

**The pair to look at first is `lattice_00_before.png` → `lattice_08_all.png`.**

`states_00_before.png` / `states_01_after.png` are §4 / R7: every region state at once
(solid, anchor/fixed, protected, latticed·include, latticed·exclude, design box,
keep-out) before and after the desaturation.

## `content/`

The topology-optimised result, so the `to_*` column is reproducible rather than asserted:

| file | what |
|---|---|
| `to_job.json` | his own analyze job (`evidence/2026-08-05-smoothing-must-actually-smooth/job.json`) switched to `minimize_plastic` at resolution 64 |
| `to_result_bracket.stl` | the exported variant — 34,472 triangles |
| `to_report.json` | that run's report |

## What the run asserts

This is a test as well as a capture — a screenshot nobody measured is not evidence:

- the SSAO/edge, stage and footprint pipelines all **compiled** (they are built with
  `try?`, so a shader typo would otherwise disable a feature silently and every "after"
  would be an honest capture of nothing happening);
- AO moves **>40%** of the lattice's own pixels and **>10%** of each CAD part's;
- the world-lighting rig moves **>50%** of every part's pixels **without** the AO pass;
- switching the contact shadow on at least **doubles** the off-part (floor) difference;
- every difference is measured over the **part's own pixels**, from a mask the renderer
  renders itself — an earlier version averaged over the whole frame, 90% of which is
  backdrop AO cannot touch, and reported that AO had moved his bracket by 0.4 grey levels;
- the frame-time table carries its **own noise floor** (two independent interleaved
  sweeps), and the run fails if the harness cannot resolve half the headline cost;
- **R5**: the exported STL is byte-identical (FNV-1a `e43074dcdfd2c023`) before and after
  a full-quality render.
