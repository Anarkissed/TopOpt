#!/usr/bin/env python3
"""Full gate table, HEAD vs NEW, with the 1e-9 negative-control floor.

    gate_diff.py <head_root> <new_root> <label>:<dir> [<label>:<dir> ...]

For each job it prints every rung both binaries evaluated — printed fraction,
VERDICT, worst-case margin, effective margin, required margin, max stress — and
then compares them rung by rung.

THE FLOOR. Two margins are called identical when their relative difference is
<= 1e-9. That threshold is only meaningful if it can actually FAIL, so the
script ends with a NEGATIVE CONTROL: the same comparison run between two jobs
that are genuinely different must report a difference. A comparator that says
"identical" for everything proves nothing.

A VERDICT FLIP (ACCEPTED <-> REJECTED, or a rung appearing/disappearing) is
reported separately and loudly: it is a blocked-stop for this task, not a
tolerance question.
"""
import json
import os
import sys

FLOOR = 1e-9


def rows(path):
    r = json.load(open(path))
    out = []
    for kind in ('variants', 'rejected_variants'):
        for v in r.get(kind, []):
            out.append((v['printed_fraction'],
                        'ACCEPTED' if v['accepted'] else 'REJECTED',
                        v['margin']['worst_case'], v['margin_effective'],
                        v['margin_required'], v['max_stress_mpa'],
                        v.get('rejection_reason', '')))
    out.sort(key=lambda t: -t[0])
    return out


def load(root, d):
    p = os.path.join(root, d, 'report.json')
    return rows(p) if os.path.exists(p) else None


def show(label, table):
    if table is None:
        print(f'    {label:<6} (no report.json — the run REFUSED)')
        return
    print(f'    {label:<6} printed_fr   verdict     margin_worst_case  '
          'margin_effective   required   max_stress_mpa')
    for pf, acc, mw, me, mr, ms, rr in table:
        print(f'    {"":<6} {pf:10.7f}   {acc}   {mw:17.10g}  {me:17.10g}  '
              f'{mr:9g}   {ms:14.10g}  {rr}')


def compare(a, b):
    """-> (verdict_flips, worst_relative_margin_delta, note)"""
    if a is None and b is None:
        return 0, 0.0, 'both REFUSED — no verdict either way'
    if a is None:
        # -1 is the sentinel for "one side refused" — not a delta of zero, which
        # would print as IDENTICAL and read as "nothing changed".
        return 0, -1.0, f'HEAD REFUSED, NEW produced {len(b)} rung(s) — THE FIX'
    if b is None:
        return len(a), float('inf'), 'NEW REFUSED where HEAD ran — REGRESSION'
    if len(a) != len(b):
        return abs(len(a) - len(b)), float('inf'), \
            f'rung COUNT changed {len(a)} -> {len(b)}'
    flips, worst = 0, 0.0
    for ra, rb in zip(a, b):
        if ra[1] != rb[1]:
            flips += 1
        for ia, ib in ((2, 2), (3, 3)):        # worst_case, effective
            va, vb = ra[ia], rb[ib]
            den = abs(va) if abs(va) > 0 else 1.0
            worst = max(worst, abs(va - vb) / den)
    return flips, worst, 'rung-for-rung'


def main():
    head_root, new_root = sys.argv[1], sys.argv[2]
    jobs = [s.split(':', 1) for s in sys.argv[3:]]
    print('=' * 78)
    print(' FULL GATE TABLE — HEAD vs NEW   (floor: relative delta <= %g)' % FLOOR)
    print('=' * 78)
    summary = []
    for label, d in jobs:
        a, b = load(head_root, d), load(new_root, d)
        print(f'\n{label}')
        show('HEAD', a)
        show('NEW', b)
        flips, worst, note = compare(a, b)
        verdict = ('VERDICT FLIP' if flips else
                   'FIXED' if worst < 0 else
                   'IDENTICAL' if worst <= FLOOR else 'MARGIN MOVED')
        wd = 'n/a' if worst < 0 else f'{worst:.3g}'
        print(f'    -> {verdict:<12} flips={flips} worst_rel_delta={wd}  ({note})')
        summary.append((label, verdict, flips, worst, note))

    print('\n' + '=' * 78)
    print(' SUMMARY')
    print('=' * 78)
    for label, verdict, flips, worst, note in summary:
        print(f'  {verdict:<12} {label:<44} {note}')
    total_flips = sum(s[2] for s in summary)
    print(f'\n  TOTAL VERDICT FLIPS: {total_flips}')

    # ── NEGATIVE CONTROL ────────────────────────────────────────────────────
    # The 1e-9 floor above is worth nothing unless it can fail. Compare two jobs
    # that are genuinely different and require the comparator to say so.
    print('\n' + '=' * 78)
    print(' NEGATIVE CONTROL — the comparison must be able to FAIL')
    print('=' * 78)
    ctrl = None
    for i in range(len(jobs)):
        for j in range(len(jobs)):
            if i == j:
                continue
            a, b = load(new_root, jobs[i][1]), load(new_root, jobs[j][1])
            if a is None or b is None:
                continue
            flips, worst, note = compare(a, b)
            if worst > FLOOR or flips:   # worst < 0 cannot occur: both loaded
                ctrl = (jobs[i][0], jobs[j][0], flips, worst, note)
                break
        if ctrl:
            break
    if ctrl:
        print(f'  comparing two DIFFERENT jobs -- {ctrl[0]}  vs  {ctrl[1]}')
        print(f'  -> flips={ctrl[2]} worst_rel_delta={ctrl[3]:.6g}  ({ctrl[4]})')
        print('  the comparator DOES detect a difference at this floor: the '
              'IDENTICAL verdicts above are real.')
    else:
        print('  *** NEGATIVE CONTROL FAILED: the comparator could not tell any '
              'two jobs apart. Every "IDENTICAL" above is untrustworthy. ***')
        return 2
    return 1 if total_flips else 0


if __name__ == '__main__':
    sys.exit(main())
