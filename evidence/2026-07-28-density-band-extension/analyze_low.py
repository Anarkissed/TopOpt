#!/usr/bin/env python3
# Post-process low_end.csv: remove rho-landing noise from the resolution-drift
# metric by comparing each coarse-vpc (rho, E) point against the vpc128 TRUTH CURVE
# interpolated to that point's OWN measured rho. The per-vpc calibration lands on
# slightly different rho (voxel quantization of a thin strut), so a raw E-vs-Eref
# drift conflates resolution error with the rho gap; interpolating the reference to
# the coarse point's rho isolates the pure resolution error.
import csv, sys
from bisect import bisect_left

rows = list(csv.DictReader(open('/tmp/bx_evidence/low_end.csv')))
for r in rows:
    for k in ('target_vf','vpc','rho_measured','vox_per_strut','E100_MPa','zener','drift_vs_ref_pct'):
        r[k] = float(r[k])
    r['vpc'] = int(r['vpc'])

# Build the vpc128 truth curve E(rho) from all vpc128 rows across the sweep.
ref = sorted([(r['rho_measured'], r['E100_MPa']) for r in rows if r['vpc']==128])
rr = [x for x,_ in ref]; ee = [y for _,y in ref]
def E128(rho):
    if rho<=rr[0]:
        # linear extrapolation from first two
        return ee[0] + (ee[1]-ee[0])*(rho-rr[0])/(rr[1]-rr[0])
    if rho>=rr[-1]:
        return ee[-2] + (ee[-1]-ee[-2])*(rho-rr[-2])/(rr[-1]-rr[-2])
    i = bisect_left(rr, rho)
    t = (rho-rr[i-1])/(rr[i]-rr[i-1])
    return ee[i-1] + t*(ee[i]-ee[i-1])

print(f"{'tvf':>6} {'vpc':>4} {'rho':>7} {'vox/str':>7} {'E100':>7} {'E128@rho':>8} {'clean_drift%':>12} {'raw_drift%':>10}")
byvf={}
for r in rows:
    e_ref = E128(r['rho_measured'])
    clean = 100.0*(r['E100_MPa']-e_ref)/e_ref
    r['clean']=clean
    byvf.setdefault(r['target_vf'],[]).append(r)
    print(f"{r['target_vf']:>6.3f} {r['vpc']:>4d} {r['rho_measured']:>7.4f} {r['vox_per_strut']:>7.2f} "
          f"{r['E100_MPa']:>7.1f} {e_ref:>8.1f} {clean:>+12.2f} {r['drift_vs_ref_pct']:>+10.2f}")

print("\n--- floor determination: smallest vpc with |clean_drift|<2.4% AND vox/strut>=6 ---")
for tvf in sorted(byvf):
    cand=[r for r in byvf[tvf] if r['vpc']!=128 and abs(r['clean'])<2.4 and r['vox_per_strut']>=6.0]
    cand.sort(key=lambda r:r['vpc'])
    if cand:
        r=cand[0]
        print(f"  target {tvf:.3f}: CONVERGED at vpc{r['vpc']} (rho {r['rho_measured']:.4f}, "
              f"{r['vox_per_strut']:.1f} vox/str, clean drift {r['clean']:+.2f}%) -> certifiable")
    else:
        # also check vpc128 vs the curve trend / vpc96 clean
        best=min((r for r in byvf[tvf] if r['vpc']!=128), key=lambda r:abs(r['clean']), default=None)
        msg = f"best non-ref |clean|={abs(best['clean']):.2f}% at vpc{best['vpc']} ({best['vox_per_strut']:.1f} v/s)" if best else "n/a"
        print(f"  target {tvf:.3f}: NOT converged (<2.4% & >=6 v/s) in ladder — {msg}")
