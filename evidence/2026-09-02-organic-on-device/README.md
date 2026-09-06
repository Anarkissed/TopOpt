# Organic on the real part (M2 verticalStand, Ready project) — the bytes, 2026-09-02/03

For the core agent reproducing the two traced-path refusals. These are the exact job
documents the app wrote on the simulator (captured while `lattice_job.json` existed), not
descriptions.

| file | what |
|---|---|
| `run2_job.json` | run 2 (21:31): organic, `intent: aesthetic`, NO shape fit, the octet's inherited `swept 5.5–6` window. On device: refused at the PRINTABILITY gate (17 raster cells, 0.627 mm³ into open air; 7343 legs, 607 cuts). |
| `run3_job_shape_fit.json` | run 3 (21:49): same + `organic_shape_fit: true`. On device: passed the printability gate, refused at the EXPORT guard (5 of 237,996 vertices outside the shell, worst 0.0318 mm, "interior strut"). |
| `run2_replay_gate_off.json` | run 2's bytes with `lattice.require_no_midair_start: false` — the Mac replay that reached the receipt. |
| `run2_replay_gate_off_run_info.json` | its receipt: 1240 spans, 783.28 mm, `unsupported_cells_remaining 17`. |
| `run2_grown_replay_run_info.json` | run 2's bytes + `organic_growth: true` (report only): `growth_ran` reads false although the grown branch ran. |

**The shell guard did NOT fire on run-2 bytes without shape fit** — neither on device
(the printability gate came first) nor on the gate-off Mac replay (exported clean, 1240
spans). It fired only on run 3, with `organic_shape_fit: true`. The core agent sees it
fire without shape fit on its own job; that difference matters.

## The exact replay command (Release core, `build/topopt-cli`, worktree at commit e40b5512 for core/)

```bash
# model.step is the project's model (M2 verticalStand, 229,557 B); the job names it by
# last path component, so it must sit beside the job file.
cd <dir containing model.step> && cp <this dir>/run2_replay_gate_off.json job.json
/path/to/build/topopt-cli lattice-variant job.json --out out
# receipt: out/run_info.json  (grading.organic.*)   spans: out/variant_024_lattice_SPANS.txt
```

No `--threads`, `--materials` or `--rules` flags were passed; `run` refuses mode
`lattice_part` ("unsupported mode"), `lattice-variant` is the subcommand. Wall ≈ 5 min.
