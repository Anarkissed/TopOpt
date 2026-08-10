#!/bin/sh
# Regenerates every measurement in
# docs/handoffs/2026-08-10-parametric-level-set.md.
#
# Everything is IN THIS REPOSITORY. Nothing is cloned and nothing is downloaded.
#
# ★ THREE THREADS THROUGHOUT, and every wall clock that is compared against
# another was measured with nothing else running. The measurements that are NOT
# wall clocks — every roughness, every margin, every residual — are deterministic
# and unaffected by what else was on the machine.
#
# ★ THE FIELDS ARE BIG AND THEY ARE NOT COMMITTED. An F=3 analytic field is
# 384 x 93 x 354 float64 = 101 MB, and this script writes about forty of them.
# They are regenerated here into $HERE/fields, $HERE/traj, $HERE/ror, $HERE/f3
# and $HERE/band; what the repository keeps is the MEASUREMENTS (every .csv and
# .txt below) plus the voxel-lattice fields the certifications read, gzipped.
# `--emit-factor 1` fields are 3.7 MB each and gzip to ~200 KB.
#
# Cost on the machine of record (10 cores, 3 threads to the solver):
#   ~4 min   build
#   ~4 min   the two byte-identity controls for the header moves (S0)
#   ~5 min   the fits (S1, S4, S5, S8) — no FEA, no optimisation
#   ~50 min  the surface measurements (S2, S6, S9)
#   ~45 min  the certifications (S3, S7)
#   ~85 min  ARM 2 (S10) — five parametric optimisation arms, run serially
#   ~35 min  ARM 2's certifications and surface measurements (S11)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
ALPHA="$REPO/evidence/2026-08-10-levelset-alpha-and-stopping-rule"
cd "$REPO"

STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j6 --target plsm_probe levelset_probe \
    external_field_surface_probe design_rung_dump

# ── THE SUBJECTS ────────────────────────────────────────────────────────────
# ARM 1 measures a REPRESENTATION on designs we ALREADY HAVE. R5: nothing is
# re-optimised. The two the task names:
#   C2it25  PR 325's alpha-max perimeter C=2 arm at iteration 25 — cut roughness
#           7.2908 deg, the best CONVERGED arm we own
#   ROR     PR 323's run of record (alpha 2.4, converged at iteration 76) — cut
#           roughness 13.0156 deg, the WORST surface we own
# plus iterations 5/10/15/20 of the same C=2 arm, for the margin CURVE (R3).
mkdir -p "$HERE/sources/simp"
for it in 0005 0010 0015 0020 0025; do
  gunzip -c "$ALPHA/s6_max_C2/snap/it$it.f64.gz" > "$HERE/sources/C2it$it.f64"
  cp "$ALPHA/s6_max_C2/snap/it$it.meta" "$HERE/sources/C2it$it.meta"
done
cp "$HERE/sources/C2it0025.f64" "$HERE/sources/C2it25.f64"
cp "$HERE/sources/C2it0025.meta" "$HERE/sources/C2it25.meta"
gunzip -c "$ALPHA/s2_alpha_min/rho.f64.gz" > "$HERE/sources/ROR.f64"
cp "$ALPHA/s2_alpha_min/rho.meta" "$HERE/sources/ROR.meta"
# HIS SIMP rung as a field on the same lattice, so SIMP can be re-extracted at
# every refinement factor beside everything else. `design_rung_dump` is INVOKED.
./build/design_rung_dump "$REF" "$HERE/sources/simp"

# ── S0: THE TWO HEADER MOVES ARE NO-OPS, AND THIS PROVES IT ─────────────────
# `levelset_kernel.hpp` and `plsm_basis.hpp` are MOVES of code that used to live
# in levelset_probe.cpp and plsm_probe.cpp. Each is verified by running before
# and after; `s0_kernel_move/verdict.txt` and `s0_basis_move/verdict.txt` hold
# the diffs, which are empty on every computed column. Re-running them requires
# checking out the parent commit, so the verdicts are kept as artefacts rather
# than regenerated here — but the AFTER halves are reproduced, and they are what
# the current tree must still produce:
mkdir -p "$HERE/s0_kernel_move" "$HERE/s0_basis_move"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s0_kernel_move/after" \
    --rung 0.68 --iters 3 --threads 3 --gridap-auto min \
    > "$HERE/s0_kernel_move/after.log" 2>&1
./build/plsm_probe "$HERE/sources/C2it25" "$HERE/s0_basis_move/after" \
    --threads 3 --emit-factor 1 \
    --fit W4:wendland:4,4,4:2 --fit G2:gaussian:2,2,2:2 > /dev/null 2>&1

# ★ S0c — AND THE ARMS THAT ALREADY SHIPPED MUST STILL REPRODUCE. The header
# move is not the only thing this task did to `levelset_probe.cpp`: ARM 2 added
# `--plsm`, and with it a generalisation of the volume offset from `phi + offset`
# to `phi + offset * off_shape[v]`, where `off_shape` is all ones unless --plsm
# is armed. That is a no-op BY CONSTRUCTION and this is the measurement of it.
# `s0_shipped_arms/verdict.txt` compares this run against the pre-task trajectory
# in `s0_kernel_move/before` — every computed column must be identical and
# `rho.f64` byte-identical, or a voxel arm has silently changed.
mkdir -p "$HERE/s0_shipped_arms"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s0_shipped_arms/after" \
    --rung 0.68 --iters 3 --threads 3 --gridap-auto min \
    > "$HERE/s0_shipped_arms/after.log" 2>&1
for f in "$HERE/s0_kernel_move/before" "$HERE/s0_shipped_arms/after"; do
  cut -d, -f1-12,15-22 "$f/iterations.csv" > "$f.cols"
done
{
  echo "== THE SHIPPED VOXEL ARMS STILL REPRODUCE, AFTER EVERYTHING ARM 2 ADDED =="
  echo
  echo "levelset_probe, 3 iterations, --gridap-auto min, 3 threads."
  echo "BEFORE: the pre-task binary (s0_kernel_move/before)."
  echo "AFTER : this tree, with --plsm, --respect-frozen, --plsm-export and the"
  echo "        off_shape generalisation of the volume offset all present."
  echo
  echo "-- every COMPUTED column of iterations.csv (all but the three wall clocks)"
  diff "$HERE/s0_kernel_move/before.cols" "$HERE/s0_shipped_arms/after.cols" \
    && echo "   IDENTICAL (the diff above is empty)"
  echo
  echo "-- the final ersatz occupancy, 468224 float64"
  cmp "$HERE/s0_kernel_move/before/rho.f64" "$HERE/s0_shipped_arms/after/rho.f64" \
    && echo "   rho.f64 BYTE-IDENTICAL"
} > "$HERE/s0_shipped_arms/verdict.txt" 2>&1
rm -f "$HERE/s0_kernel_move/before.cols" "$HERE/s0_shipped_arms/after.cols"
cat "$HERE/s0_shipped_arms/verdict.txt"

# ── S1: THE FIT SWEEP ───────────────────────────────────────────────────────
# ★ R4 — PER AXIS, NOT MINIMUM. `--fit L:basis:dx,dy,dz:support` takes THREE
# spacings. `--knots-min` adds the SLAB TRAP arm on purpose: one spacing derived
# from min(nx,ny,nz) = 31, the mistake that cost PR 324 a day, so its cost is
# measured instead of asserted away. A424 is the honest per-axis point.
#
# `--emit-source` writes the source occupancy tricubically resampled to every
# factor (the RESOLUTION control) AND the source's own phi re-banded at the fits'
# eta (the BAND control, S9's subject and the one that decides the question).
mkdir -p "$HERE/fields"
./build/plsm_probe "$HERE/sources/C2it25" "$HERE/fields" --threads 3 \
    --emit-factor 1 --emit-factor 2 --emit-source \
    --emit-extra "$HERE/sources/simp/rung_0.68=SIMP" \
    --fit W2:wendland:2,2,2:2   --fit W4:wendland:4,4,4:2 \
    --fit W6:wendland:6,6,6:2   --fit W8:wendland:8,8,8:2 \
    --fit W4s3:wendland:4,4,4:3 --fit W4s15:wendland:4,4,4:1.5 \
    --fit G2:gaussian:2,2,2:2   --fit G4:gaussian:4,4,4:2 \
    --fit A424:wendland:4,2,4:2 --knots-min \
    > "$HERE/s1_fit_C2it25.txt" 2>&1

# ── S2: THE SURFACE, ON OUR INSTRUMENT, INVOKED NOT RETYPED (R2) ────────────
# `external_field_surface_probe` carries its own four SIMP rows from the
# reference design.bin, so no row is compared against a remembered number.
#
# ★ THE POSITIVE CONTROL THIS RUN CARRIES FOR FREE: `SIMPf2` is HIS rung 0.68
# put through plsm_probe's emission at factor 2 and extracted with `factor 1`.
# That is the same operation as the probe's OWN built-in SIMP row, so the two
# must agree to every printed digit. They do (8.407493 / 7.552074 / 440550.9),
# which is what certifies the lattice/origin/resample convention this whole task
# rests on. If they ever diverge, nothing below means anything.
mkdir -p "$HERE/s2_surface"
set -- "$REF" "$STEP" "$HERE/s2_surface"
for L in SRC SIMP; do for F in 1 2; do
  set -- "$@" "${L}f${F}=$HERE/fields/${L}_f${F}"; done; done
for L in W2 W4 W6 W8 W4s3 W4s15 G2 G4 A424 TRAP-min; do for F in 1 2; do
  set -- "$@" "${L}-vm-f${F}=$HERE/fields/${L}_vm_f${F}"; done; done
for L in W4 W8; do for F in 1 2; do
  set -- "$@" "${L}-af-f${F}=$HERE/fields/${L}_af_f${F}"; done; done
./build/external_field_surface_probe "$@" > "$HERE/s2_surface.txt" 2>&1
mv "$HERE/s2_surface/s2_reference_impl_vs_simp.csv" "$HERE/s2_curves.csv"

# ── S3: DOES THE CERTIFICATE READ THE FITTED PHI? ───────────────────────────
# `analyze_fixed_design` at the PRODUCTION penalty, isolated exactly as
# production isolates a re-certification. One process certifies the whole curve.
#
# ★ THIS PASS IS RUN WITHOUT `--respect-frozen` AND IT IS NOT A MISTAKE. It is
# the honest answer to "does the certificate read it": it does, and it REJECTS
# every fit, on the LOAD PATH and not on the margin. S7 then restores the mask
# the production ersatz applies anyway, and the pair is the attribution.
mkdir -p "$HERE/s3_margin"
set -- "$STEP" "$MATS" "$REF" "$HERE/s3_margin" --threads 3
for L in W2 W4 W6 W8 W4s3 W4s15 G2 G4 A424 TRAP-min; do
  set -- "$@" --certify-field "$HERE/fields/${L}_vm_f1"; done
for it in 0005 0010 0015 0020 0025; do for C in G2 A424; do
  set -- "$@" --certify-field "$HERE/traj/${C}i${it}_vm_f1"; done; done
for it in 0005 0010 0015 0020; do
  set -- "$@" --certify-field "$HERE/sources/C2it$it"; done
set -- "$@" --certify-field "$HERE/sources/C2it25" \
            --certify-field "$HERE/sources/simp/rung_0.68"
# S4 must run before S3 can certify the trajectory fits; ordering below.
:

# ── S4: THE TRAJECTORY, so the margin is a CURVE and never a point (R3) ─────
# The SAME two fit configurations applied to iterations 5/10/15/20/25 of the C=2
# arm. PR 325 measured that arm's margin swinging 2028 -> 2574 -> 2655 -> 3172 ->
# 2015 at constant volume fraction; this puts the fit's curve beside it.
mkdir -p "$HERE/traj"
for it in 0005 0010 0015 0020 0025; do
  ./build/plsm_probe "$HERE/sources/C2it$it" "$HERE/traj" --threads 3 \
      --emit-factor 1 --emit-factor 2 \
      --fit "G2i${it}:gaussian:2,2,2:2" --fit "A424i${it}:wendland:4,2,4:2" \
      > "$HERE/traj/fit_it$it.txt" 2>&1
done
./build/levelset_probe "$@" > "$HERE/s3_margin.log" 2>&1

# ── S5: SUBJECT 2 — the RUN OF RECORD, the worst surface we own ─────────────
mkdir -p "$HERE/ror"
./build/plsm_probe "$HERE/sources/ROR" "$HERE/ror" --threads 3 \
    --emit-factor 1 --emit-factor 2 --emit-source \
    --fit W2:wendland:2,2,2:2 --fit W4:wendland:4,4,4:2 \
    --fit G2:gaussian:2,2,2:2 --fit A424:wendland:4,2,4:2 \
    > "$HERE/s4_fit_ROR.txt" 2>&1

# ── S6: A THIRD REFINEMENT FACTOR — the RESOLUTION control ──────────────────
# ★ WITHOUT THIS THE TABLE CANNOT BE READ. `dihedral_rms_deg` falls with the
# extraction lattice on ANY field, analytic or not, because a smooth surface cut
# into smaller triangles has smaller angles between them. Comparing an analytic
# row at F=3 against SIMP's shipped F=2 row would measure the lattice. Every
# comparison in the handoff is WITHIN a column of constant F, and these rows are
# what make the columns exist.
mkdir -p "$HERE/f3"
./build/plsm_probe "$HERE/sources/C2it25" "$HERE/f3" --threads 3 \
    --emit-factor 3 --emit-source \
    --emit-extra "$HERE/sources/simp/rung_0.68=SIMP" \
    --fit G2:gaussian:2,2,2:2 --fit A424:wendland:4,2,4:2 \
    --fit W4:wendland:4,4,4:2 > "$HERE/s5_f3.txt" 2>&1

mkdir -p "$HERE/s6_surface2"
set -- "$REF" "$STEP" "$HERE/s6_surface2"
for F in 1 2; do set -- "$@" "RORsrc-f${F}=$HERE/ror/SRC_f${F}"; done
for L in W2 W4 G2 A424; do for F in 1 2; do
  set -- "$@" "ROR-${L}-f${F}=$HERE/ror/${L}_vm_f${F}"; done; done
for it in 0005 0010 0015 0020 0025; do for C in G2 A424; do
  set -- "$@" "T${C}i${it}=$HERE/traj/${C}i${it}_vm_f2"; done; done
for A in SRC_f3 SIMP_f3 G2_vm_f3 A424_vm_f3 W4_vm_f3; do
  set -- "$@" "F3-${A}=$HERE/f3/${A}"; done
./build/external_field_surface_probe "$@" > "$HERE/s6_surface2.txt" 2>&1
mv "$HERE/s6_surface2/s2_reference_impl_vs_simp.csv" "$HERE/s6_curves.csv"

# ── S6b: ★ THE ROW THAT IS CONVENTION-IDENTICAL TO SIMP'S AND TO GRIDAP'S ───
# The bake-off's table puts `dihedral_cut_deg` — a FACTOR-2 TRICUBIC extraction —
# and `midpoint_share` — a statistic of the field on the DESIGN LATTICE — on the
# SAME row: SIMP 7.5521 / 85.28%, GridapTopOpt 4.0156 / 7.19%. Every ARM 1 row so
# far is a field extracted at `factor 1`, on the design lattice or a refined one,
# so none of them is that convention and none can sit beside Gridap uncaveated.
#
# ★ THIS IS THAT CONVENTION, AND IT IS DELIBERATELY THE UNFLATTERING ROUTE. The
# fitted phi is sampled at VOXEL CENTRES and extracted at factor 2 tricubic —
# which is exactly what the task brief calls "the single easiest way to get a
# false negative", because it puts the quantisation under test back into the
# measurement. That is the point: it is the WORST the representation can look,
# measured the way everything it is compared against was measured. The
# `factor 1` rows above are the other bracket: what the representation actually
# gives you when it is allowed to be a function.
mkdir -p "$HERE/shipped" "$HERE/s10_shipped"
for spec in "fields/W2_vm_f1 W2" "fields/W4_vm_f1 W4" "fields/W6_vm_f1 W6" \
            "fields/W8_vm_f1 W8" "fields/W4s3_vm_f1 W4s3" \
            "fields/W4s15_vm_f1 W4s15" "fields/G2_vm_f1 G2" \
            "fields/G4_vm_f1 G4" "fields/A424_vm_f1 A424" \
            "fields/TRAP-min_vm_f1 TRAP-min" "fields/SRC_f1 SRC" \
            "fields/SIMP_f1 SIMP" "band/SRCPHI_f1 SRCPHI"; do
  set -- $spec
  # rm FIRST: `cp -f a b` fails outright when b is a HARD LINK to a, which is
  # how these were first made, and `set -e` then kills the whole run.
  rm -f "$HERE/shipped/$2.f64"
  cp "$HERE/$1.f64" "$HERE/shipped/$2.f64"
  sed -e 's/^factor .*/factor 2/' -e 's/^interp .*/interp tricubic/' \
      "$HERE/$1.meta" > "$HERE/shipped/$2.meta"
  printf '# SHIPPED CONVENTION: design lattice, factor 2 tricubic\n' \
      >> "$HERE/shipped/$2.meta"
done
set -- "$REF" "$STEP" "$HERE/s10_shipped"
for L in SIMP SRC SRCPHI W2 W4 W6 W8 W4s3 W4s15 G2 G4 A424 TRAP-min; do
  set -- "$@" "SH-$L=$HERE/shipped/$L"
done
./build/external_field_surface_probe "$@" > "$HERE/s10_shipped.txt" 2>&1
mv "$HERE/s10_shipped/s2_reference_impl_vs_simp.csv" "$HERE/s10_curves.csv"

# ── S7: THE SAME CERTIFICATIONS WITH THE FROZEN SET RESTORED ────────────────
# `--respect-frozen` stamps FrozenSolid back to 1 and FrozenVoid to 0 before
# certifying — which is what `build_fields` in levelset_probe does on every
# iteration of every level-set arm ever run, so this is the production posture
# and S3 was the one running without it.
mkdir -p "$HERE/s7_margin_frozen"
set -- "$STEP" "$MATS" "$REF" "$HERE/s7_margin_frozen" --threads 3 --respect-frozen
for L in W2 W4 W6 W8 W4s3 W4s15 G2 G4 A424 TRAP-min; do
  set -- "$@" --certify-field "$HERE/fields/${L}_vm_f1"; done
for it in 0005 0010 0015 0020 0025; do for C in G2 A424; do
  set -- "$@" --certify-field "$HERE/traj/${C}i${it}_vm_f1"; done; done
for it in 0005 0010 0015 0020; do
  set -- "$@" --certify-field "$HERE/sources/C2it$it"; done
set -- "$@" --certify-field "$HERE/sources/C2it25" \
            --certify-field "$HERE/sources/simp/rung_0.68"
./build/levelset_probe "$@" > "$HERE/s7_margin_frozen.log" 2>&1

# ── S8 + S9: ★★ THE BAND CONTROL, WHICH DECIDES THE QUESTION ───────────────
# The source occupancy is NOT the 2-voxel band its run's summary claims: 29961
# sign-changing lattice edges against 19250 cells with 0 < rho < 1 is an
# EFFECTIVE half-width of 0.32 VOXELS. Its phi is ~6x steeper than a distance
# function at the interface. The fitted phi is not, so the SAME eta gives it
# 4.6x more gray cells.
#
# That is not cosmetic. Marching cubes places a vertex by LINEAR interpolation
# between two sampled values; when both are saturated at 0 and 1 the sample
# carries no sub-voxel information and the vertex lands at the cell midpoint —
# a staircase — wherever the true surface is. So "the analytic surface is
# smoother" could have been nothing but "the analytic field has a wider band".
#
# `SRCPHI` is the SOURCE's OWN phi, still one number per voxel, still extracted
# by tricubic resample, put through the SAME ersatz at the SAME eta as the fits.
# Everything but the representation is now held fixed.
mkdir -p "$HERE/band" "$HERE/s9_band"
./build/plsm_probe "$HERE/sources/C2it25" "$HERE/band" --threads 3 \
    --emit-factor 1 --emit-factor 2 --emit-factor 3 --emit-source \
    --fit BW:wendland:2,2,2:2 > "$HERE/s8_band_control.txt" 2>&1
set -- "$REF" "$STEP" "$HERE/s9_band"
for F in 1 2 3; do for L in SRC SRCPHI BW_vm; do
  set -- "$@" "BAND-${L}-f${F}=$HERE/band/${L}_f${F}"; done; done
./build/external_field_surface_probe "$@" > "$HERE/s9_band.txt" 2>&1
mv "$HERE/s9_band/s2_reference_impl_vs_simp.csv" "$HERE/s9_curves.csv"

# ── S10: ARM 2 — THE PARAMETRIC LEVEL SET ITSELF ────────────────────────────
sh "$HERE/run_arm2.sh"
sh "$HERE/run_arm2b.sh"

# ── S11: ARM 2 measured and certified on the same instruments ───────────────
sh "$HERE/measure_arm2.sh"

# ══ THE SECOND PASS ═════════════════════════════════════════════════════════
#
# Everything below was added AFTER the first pass, because reading the first
# pass's own numbers raised questions it could not answer. Each block says which.

# ── S14/S15/S16: ★ SIMP AS THE SUBJECT, NOT ONLY AS THE BASELINE ────────────
# The first pass fitted designs made by a DISCARDED voxel level set. That was the
# right controlled experiment — same design, two representations — but it tells
# the story about a process that is no longer run. Here the subject is HIS OWN
# SIMP RUNG 0.68, so baseline and subject are the same method and the discarded
# one appears nowhere.
sh "$HERE/run_arm1_simp_subject.sh"

# ── S17: ★ THE SPEED PROBES. 99.5% of an iteration is the state solve (25.412 s
# of 25.526; the whole parametric machinery is 0.114 s), so speed work has to
# attack the solve. Three ideas, measured: inexact early solves, warm starting,
# and L-BFGS on the coefficients. None of them touches production.
sh "$HERE/run_speed_probes.sh"

# ── S18-S22: ★ THE FROZEN SET, WHICH UNDERCUT THE FIRST PASS'S HEADLINE ──────
# The first pass measured roughness on fields with NO frozen mask — which is
# exactly why the certificate rejected them. `--dump-mask` writes the mask as a
# field; `plsm_probe --frozen-mask` then combines it with the fit as a SMOOTH
# BOOLEAN (min/max on the level sets) instead of stamping 40,216 voxels to hard
# 0/1. Both are measured, because the difference between them IS the finding.
sh "$HERE/run_frozen_boolean.sh"

# ── S23-S25: ★ ARM 3 — CAN IT REPLACE SIMP RATHER THAN SIT ON TOP OF IT? ─────
# Every arm so far was seeded from a converged SIMP rung, so its cost was
# additive. That was an inherited assumption, not a requirement: the parametric
# form is specifically claimed to nucleate holes and so not to depend on its
# initial design. B1 tests it from a plain hole array; B2 then tests whether a
# COARSER basis controls the carved-surface explosion B1 produced.
sh "$HERE/run_arm3_scratch.sh"

# ── the bars ────────────────────────────────────────────────────────────────
# R6: the shipped path is untouched. This must print 0.
git diff main -- core/src core/include app/ | tee /dev/stderr | wc -l
# R7: no assertion was weakened or deleted anywhere in the diff.
sh "$HERE/assertion_census.sh" > "$HERE/r7_assertion_census.txt" 2>&1
cmake --build build -j6 && ctest --test-dir build --output-on-failure \
    > "$HERE/ctest.txt" 2>&1
echo "REPRODUCE_DONE"
