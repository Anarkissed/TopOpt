#!/bin/sh
# S1(e) — ★ VERIFY EACH CONSUMER RATHER THAN ASSUMING IT, WITH FILE AND LINE.
#
# The task names six things that "read a density per voxel": the ladder,
# `achieved_vf`, the frozen/protect masks, the clearances, the design box, and
# (S4) the lattice pass. A parametric rung produces a `SimpOptimizeResult` whose
# `physical_density` IS a density per voxel, so the claim is that none of them
# needed changing — and a claim like that is worth exactly as much as the lines
# it points at.
#
# This prints the LINES. It is a receipt, not a test: read them.
#
# ★ AND S1(c): "EVERY DESIGN IS CERTIFIED FROM ITS OWN FIELD, ALWAYS." The last
# section looks for the failure mode — a margin carried from one field to
# another — and shows the two places that could have done it and what they do
# instead.
set -eu
cd "$(dirname "$0")/../.." || exit 1

show() {
  printf '\n-- %s\n' "$1"
  shift
  grep -n "$@" || echo "   (no match — READ THIS: the audit's anchor moved)"
}

echo "=== S1(e) — WHAT EACH CONSUMER ACTUALLY READS ==="

show "THE LADDER: the field it certifies" \
  -e 'const std::vector<double>& rho = variant.optimization.physical_density' \
  core/src/simp/minimize_plastic.cpp

show "THE LADDER: the certification call that consumes it" \
  -A 3 -e 'FixedDesignAnalysis fda = analyze_fixed_design(' \
  core/src/simp/minimize_plastic.cpp

show "achieved_vf: the TWO bases, and which is which" \
  -e 'printed_fraction =' -e 'vr.volume_fraction =' -e 'vr.printed_fraction =' \
  core/src/simp/minimize_plastic.cpp

show "achieved_vf on the PARAMETRIC path: simp's own basis, Sum(occ)/n_active" \
  -B 2 -e 'r.volume_fraction =' core/src/simp/plsm.cpp

show "THE FROZEN / PROTECT MASKS: the parametric path calls the SAME function" \
  -e 'effective_design_mask' core/src/simp/plsm.cpp core/src/simp/simp.cpp

show "THE CLEARANCES: folded into the mask BEFORE the optimiser" \
  -B 2 -A 4 -e 'options.clearance_void\[idx\] == MaskValue::FrozenVoid' \
  core/src/simp/minimize_plastic.cpp

show "THE DESIGN BOX: one mask builder, shared" \
  -e 'design_domain_mask(domain, options)' core/src/simp/minimize_plastic.cpp

show "THE LATTICE PASS: the field it grades" \
  -e 'optimization.physical_density' core/src/cli/run_job.cpp

echo
echo "=== S1(c) — NOTHING REUSES A MARGIN COMPUTED ON A DIFFERENT FIELD ==="

show "the certification solve is NEVER warm-started (initial_guess = nullptr)" \
  -B 1 -A 2 -e 'initial_guess=\*/nullptr' core/src/simp/analyze.cpp

show "lattice_variant RE-CERTIFIES and REFUSES unless the recorded margin reproduces" \
  -e 'reproduction_within_band' -e 'does NOT reproduce the margin the' \
  core/src/cli/run_job.cpp

show "the analytic export says, IN THE FILE, that it is not certified" \
  -e 'NOT CERTIFIED' core/src/cli/run_job.cpp

show "the parametric path's own final compliance is a TIGHT solve on the SHIPPED field" \
  -B 4 -A 6 -e 'THE FINAL COMPLIANCE, TIGHT AND COLD' core/src/simp/plsm.cpp
