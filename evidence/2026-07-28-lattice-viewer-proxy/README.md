# Evidence — lattice viewer proxy (2026-07-28)

Handoff: `docs/handoffs/2026-07-28-lattice-viewer-proxy.md`.
All numbers are on the maintainer's own part
(`core/tests/fixtures/mesh/WallMount_ShelfBracket.stl`, 204.7 cm³ solid) on an
Apple M2 Pro — the same machine as handoff 134's committed `viewer_profile.txt`,
so they are directly comparable.

## Files

| file | what it is | bar |
|---|---|---|
| `profile_m2pro.txt` | proxy-vs-real triangle/GPU cost at 8/6/4 mm + busy-scene frame time (OFF vs ON) + sample-patch frame, 3 runs | V1, V2 |
| `proxy_graded_bracket.png` | bracket shaded by an illustrative graded demand field — deep indigo (dense) → pale (sparse). Rendered through the app's own `MeshRenderer`. | V5 |
| `proxy_uniform_bracket.png` | the workspace pre-run state: no field → uniform density, the honest flat preview | V4, V5 |
| `proxy_sample_patch.png` | the true-geometry octet 2³ sample patch (struts + node blobs), 8 940 tris | V5 |
| `swift_test_summary.txt` | the 23 headless tests (grading, faithfulness, cost, keep-out, patch) | V1, V3, V4 |

## Headline (V1)

| cell | REAL lattice | PROXY | cheaper |
|---|---:|---:|---:|
| 8 mm | 368 328 tris / 54.8 MB | 8 940 tris / 1.3 MB | 41× |
| 6 mm | 873 073 tris / 129.9 MB | 8 940 tris / 1.3 MB | 98× |
| 4 mm | 2 946 620 tris / 438.4 MB | 8 940 tris / 1.3 MB | 330× |

Proxy cost is **flat in cell size** (it is the sample patch; shading adds 0 tris,
0 new GPU buffers). Real grows as `(1/cell)³` toward PR-184's ~2.8 GB, where it
cannot be held in memory to draw — the case the proxy exists for.

## Frame time (V2)

Busy scene (part + stage + design box + keep-out box), M2 Pro, min of 40 frames.
Proxy OFF vs ON is within run-to-run noise (ON faster in 4 of 6 rows) → the
density shading is free. ~0.5 ms @1024² vs handoff 134's 0.436 ms body baseline;
the sample patch adds ~0.17 ms.

## Reproduce

```
cd app/TopOptKit
swift test --filter Lattice                                   # the 23 headless tests + profile print
TOPOPT_LATTICE_EVIDENCE_DIR=<dir> swift test --filter LatticeProxyEvidenceGen   # the PNGs
```

## Owed (per the 134 / PR-166 precedent)

Physical-iPad screenshot of the live `latticePreviewOverlay` + an Instruments
on-device frame capture. Nothing on the Mac stands in for on-device frame time;
the M2 Pro numbers here are the directly-comparable proxy, exactly as handoff 134
recorded its device numbers separately.
