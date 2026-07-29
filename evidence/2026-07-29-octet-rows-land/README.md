# Landing PR 237's octet rows into the production tensor table

PR 237 measured and validated the extended octet homogenized library
(`evidence/2026-07-28-density-band-extension/proposed_octet_rows.txt`) but changed
**evidence only** — it left the new rows on disk and did not touch production. This
change transcribes those rows into the live `kOctet` table in
[`core/src/fea/lattice.cpp`](../../core/src/fea/lattice.cpp), widening the certifiable
octet band from `0.14764–0.59093` to `0.05047–0.89988`.

The array grew `std::array<Row, 8>` → `std::array<Row, 19>` (the old single
under-resolved `0.10308` row is dropped — it was `resolved=false`, excluded from every
fit, and is superseded by the genuinely-resolved vpc128 low rows). All 19 rows are
marked `resolved=true` per PR 237's verdict, so `resolved_span()` spans the full band.

Nothing downstream changed: `lattice_rho_min/max` derive the band from the resolved
span, and `grading.cpp` reads those functions — so the wider band propagates with **no
edit to grading.cpp**.

## Bars

| Bar | Claim | Evidence |
|-----|-------|----------|
| T1 | Every new row matches PR 237's evidence exactly | `row_diff.txt` — mechanical diff of normalized rows, empty (identical) |
| T2 | Resolved flags correct; span derives the band | `verify_output.txt` §T2/T3 + all 19 rows `resolved=true` |
| T3 | `lattice_rho_min/max` ≈ 0.05 / 0.90 | `verify_output.txt` → 0.05047 / 0.89988 |
| T4 | Old band's MID rows bit-identical | `verify_output.txt` §T4 — all 7 rows C11/C12/C44 bit-for-bit |
| T5 | Grading law picks up the wider band, grading.cpp unchanged | `test_grading.txt` (23360 checks, 0 failures) + `verify_output.txt` §T5 clamp bounds |
| T6 | Byte-identical for non-lattice jobs | `test_lattice_certification.txt` §4 "no posture => byte-identical path" + call-site inspection (below) |
| T7 | Interpolation behaves at the new extremes | `verify_output.txt` §T7 — exact endpoints, clamp flags, interior means |

## How to reproduce

Numerical driver (links the REAL `lattice.cpp`, exercises the shipped table):

```
c++ -std=c++17 -I core/include evidence/2026-07-29-octet-rows-land/verify.cpp \
    core/src/fea/lattice.cpp -o /tmp/verify && /tmp/verify
```

Real `grading` unit test (proves T5 end-to-end — the law reads the band from core and
its L2 "every emitted density inside [rho_lo,rho_hi]" assertion holds with the wider
band). `-Wl,-undefined,dynamic_lookup` lets `voxelize.cpp`'s unreferenced mesh externs
stay unresolved; they are never called on this path:

```
c++ -std=c++17 -I core/include \
  core/tests/unit/test_grading.cpp core/src/simp/grading.cpp \
  core/src/fea/lattice.cpp core/src/voxel/voxelize.cpp \
  -Wl,-undefined,dynamic_lookup -o /tmp/test_grading && /tmp/test_grading
```

Real `test_lattice_certification` validation test (Eigen from Homebrew; the compute-side
closure, OCCT/lib3mf IO excluded):

```
c++ -std=c++17 -O1 -I core/include -I /opt/homebrew/include/eigen3 \
  core/tests/validation/test_lattice_certification.cpp \
  core/src/fea/{assembly,hex_element,multigrid,recycle,matfree,lattice}.cpp \
  core/src/simp/{analyze,simp,minimize_plastic,observability,production,warm_start,grading}.cpp \
  core/src/voxel/{voxelize,clearance}.cpp core/src/materials/materials.cpp core/src/mesh/mesh.cpp \
  core/src/orient/orient.cpp core/src/settings/{settings,report}.cpp \
  -Wl,-undefined,dynamic_lookup -o /tmp/test_latcert && /tmp/test_latcert
```

(The canonical CI build is `cmake -S core -B build` with the vcpkg toolchain, which
installs OCCT/Eigen/lib3mf and runs `ctest`. The standalone recipes above avoid the
heavy OCCT install for this evidence.)

## T6 — non-lattice byte-identical, by call-site inspection

The only production consumers of the changed table symbols are:

- `lattice_cubic_tensor(...)` — called from `analyze.cpp:115` **only inside
  `if (has_lattice)`**, and from harness/tests.
- `lattice_rho_min/max(...)` — read by `grading.cpp` and reported by `analyze.cpp`
  (`out.lattice_rho_* = lattice_voxels ? ... : 0.0`).
- `grade_lattice(...)` — called from `run_job.cpp:797` on the lattice path only.

A job with no lattice posture never reaches any of them, and the change is data-only
within `kOctet` plus the array size (no control-flow change on the solid path). The
certification test's `"no posture => lattice fields default (byte-identical path)"` case
confirms this directly.
