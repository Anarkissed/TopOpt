# Evidence — 2026-07-28 Apple-silicon solver envelope

Handoff: [`docs/handoffs/2026-07-28-apple-silicon-envelope.md`](../../docs/handoffs/2026-07-28-apple-silicon-envelope.md)

Measurement-only. Nothing here is compiled into `libtopopt`; Accelerate and Metal
are system frameworks (bar B3). Build all four harnesses with `./build.sh`.

| file | what |
|---|---|
| `machine.txt` | B1 — exact machine (Mac mini M2 Pro, 6P+4E, 16 GiB, 200 GB/s peak) |
| `stream.cpp` / `stream_out.txt` | H1 — STREAM triad sustained bandwidth |
| `matvec_roofline.cpp` / `matvec_roofline_out.txt` | H2 — production matrix-free operator roofline (links core objs) |
| `accel_amx.cpp` / `accel_amx_out.txt` | H3 — Accelerate/AMX FP64 vs our hand kernel |
| `metal_matvec.mm` / `metal_matvec_out.txt` | H4 — Metal FP32 element-apply prototype (operator only) |
| `amg_recost.md` | H5 — AMG re-cost under unified memory (16 GiB), bandwidth judgement |
| `build.sh` | reproduces all four binaries |

Headline numbers (all vs 200 GB/s theoretical peak):

- **H1** sustained triad **151 GB/s = 76% of peak**; 1 thread already 43%, 2 saturate ~73%.
- **H2** matrix-free operator on 6 P-cores FP64 **~54 GB/s = 27% of peak / ~90 GFLOP/s**; gather-bound, 6 threads beat 8/10.
- **H3** AMX FP64 peak ~637 GFLOP/s; per-element BLAS is a 6× regression, batched is a 2.3× compute ceiling the gather makes unreachable — nothing on the table.
- **H4** Metal FP32 apply **62–69% of peak / 373–412 GFLOP/s (~4× the CPU FP64 apply)**, but 6.9e-8 FP32 floor confines it to preconditioner duty; system ceiling still ~1.2×.
- **H5** fat AMG hierarchy at 128³ = 16.6 GB still OOMs on 16 GiB; lean variant = 1.7 GB fits; bandwidth is not the setup wall — regime/iteration economics is.
