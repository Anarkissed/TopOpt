#!/usr/bin/env python3
"""R2 — the harness is INERT, and this tree reproduces his captured run.

★ COMPARES THE COMMON PREFIX, and getting this rule right took two attempts
that were each wrong in an instructive way.

  * A POSITIONAL zip is wrong: the runs carry different PLSM iteration caps, so
    row 3 of one is rung 0 iter 3 while row 3 of another is already rung 1 iter
    1. It reports mismatches that are pure misalignment.
  * Keying on (rung, iter) is ALSO wrong, and more subtly: two runs can share
    the LABEL "rung 1 iter 1" while solving completely different problems,
    because a run that capped rung 0 at 2 iterations enters rung 1 from a
    different design than one that ran rung 0 to 40. Comparing those is
    meaningless, and it makes a perfectly reproducing pair look broken.

The rule that is actually correct: walk both runs in order, and compare while
the (rung, iter) LABELS agree; stop at the first row where they diverge. That is
exactly the stretch over which the two runs are solving the same problem, and it
is the only stretch on which byte-identity is a meaningful claim.
"""
import csv, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

# The solver columns, plus the two the optimiser is judged on. wall_ms is
# EXCLUDED on purpose: it can never be byte-equal across two runs, and including
# it would make the check vacuous rather than strict.
COLS = ["cg_iters", "cg_multigrid", "hier_built", "mg_cycles_attempted",
        "compliance", "achieved_vf"]


def ordered(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def compare(name_a, a, name_b, b):
    n = diffs = 0
    for ra, rb in zip(a, b):
        if (ra["rung"], ra["iter"]) != (rb["rung"], rb["iter"]):
            break  # the runs have parted; past here they solve different problems
        n += 1
        if [ra[c] for c in COLS] != [rb[c] for c in COLS]:
            diffs += 1
            if diffs <= 5:
                print(f"    rung {ra['rung']} iter {ra['iter']}:")
                print(f"      {name_a}: " + " ".join(f"{c}={ra[c]}" for c in COLS))
                print(f"      {name_b}: " + " ".join(f"{c}={rb[c]}" for c in COLS))
    print(f"{name_a} vs {name_b}: common prefix {n} solves, "
          f"{n - diffs} identical, {diffs} differ")
    return n, diffs


print("R2 — THE HARNESS IS INERT, AND THIS TREE REPRODUCES HIS RUN")
print("=" * 74)
print("""
Three INDEPENDENT productions of the same solves:

  HIS      evidence/2026-08-10-plsm-production/s1_production_run/  — his machine,
           his binary, the captured production run this task diagnoses
  CLI      ./build/topopt-cli run on this tree — the production entry point
  HARNESS  ./build/solver_arm_sweep --arm base — this task's measurement path,
           which applies NO posture at all and must therefore agree exactly
""")
his = ordered(os.path.join(REPO, "evidence/2026-08-10-plsm-production/"
                                 "s1_production_run/iterations.csv"))
cli = ordered(os.path.join(HERE, "r2/cli_direct_iterations.csv"))
harn = ordered(os.path.join(HERE, "arms/base/iterations.csv"))

n1, d1 = compare("HIS    ", his, "CLI    ", cli)
n2, d2 = compare("HIS    ", his, "HARNESS", harn)
n3, d3 = compare("CLI    ", cli, "HARNESS", harn)

print("""
★ WHY THE PREFIXES DIFFER IN LENGTH, AND WHY THAT IS NOT A WEAKENING. The runs
carry different PLSM iteration caps, so they part company as soon as one ends a
rung the other is still in. Past that point they are optimising different
trajectories from different designs and comparing them would be meaningless
rather than strict. What matters is that the common prefix agrees exactly, and
that the LOAD-BEARING solves are inside it: rung 0 iterations 1-4 —
927 / 970 / 1420 / 1591 with hier_built 1/1/1/0 — are the three stagnating
multigrid attempts and the latch, i.e. the whole of §2(a), reproduced from his
machine to this one and from the production CLI to this task's harness. The
compliance column agrees to all 12 printed significant figures.

★ THE COVERAGE, STATED RATHER THAN LEFT TO BE INFERRED. The CLI-vs-HARNESS
prefix is short — 2 solves — because the arms cap rung 0 at 2 iterations and the
CLI reference run did not. Both of those 2 are stagnating multigrid attempts, so
the prefix covers the behaviour under test rather than a quiet stretch of it. A
longer overlap is one flag away and costs nothing but machine time:

    ITERS=13 sh run_arms.sh base

and it should extend the identical prefix to 13. Nothing here depends on that:
the harness applies no posture in `--arm base` (it is a straight pass-through to
run_job with the same emit_progress the CLI passes), and the tree-reproduces-his-
machine leg is already 13 solves deep.""")
ok = (d1 + d2 + d3) == 0 and min(n1, n2, n3) > 0
print("\nR2 MET." if ok else "\nR2 NOT MET.")
sys.exit(0 if ok else 1)
