#!/usr/bin/env python3
# Turn a *_sweep.csv into a C++ Row table + summary.
# Landed band = the CONTIGUOUS block from first-validated to last-validated rho;
# every row in that block is an interpolation node (resolved=true) because E100(rho)
# is convex and dropping an interior node badly over-estimates across the gap. Rows
# outside the block are kept as provenance (resolved=false). Reports worst in-band drift.
import csv, sys, os

CPPNAME={'sc':'SimpleCubic','bcc':'Bcc','fcc':'Fcc','diamond':'Diamond',
         'kelvin':'Kelvin','rhombic':'Rhombic','octet':'FullOctet'}

def load(path):
    with open(path) as f: return list(csv.DictReader(f))

def block(rows):
    idx=[i for i,r in enumerate(rows) if r['validated']=='1' and r['cubic']=='1']
    if not idx: return None,None
    return idx[0], idx[-1]

def summarize(topo, rows):
    lo,hi=block(rows)
    zs=[float(r['zener']) for r in rows]
    ax=max(float(r['axial_aniso_pct']) for r in rows)
    sh=max(float(r['shear_aniso_pct']) for r in rows)
    cubic = ax<2.4 and sh<2.4
    if lo is None:
        band="none"; worst=0.0
    else:
        band=f"[{float(rows[lo]['rho_row']):.3f},{float(rows[hi]['rho_row']):.3f}]"
        worst=max(abs(float(rows[i]['drift_pct'])) for i in range(lo,hi+1))
    print(f"{topo:10s} band={band:16s} zener=[{min(zs):.3f},{max(zs):.3f}] "
          f"worstDrift={worst:.2f}% maxAxial={ax:.1f}% maxShear={sh:.1f}% "
          f"-> {'CUBIC' if cubic else 'TETRAGONAL'}")

def emit(topo, rows):
    lo,hi=block(rows)
    name=CPPNAME.get(topo,topo)
    print(f"\n// {topo}: measured 2026-07-29-tensor-library-nine (vpc48 row, vpc64 converged),")
    print(f"//   Es=3500 MPa. Band rho [{float(rows[lo]['rho_row']):.4f}, {float(rows[hi]['rho_row']):.4f}];"
          f" worst in-band drift {max(abs(float(rows[i]['drift_pct'])) for i in range(lo,hi+1)):.2f}%.")
    print(f"constexpr std::array<Row, {len(rows)}> k{name} = {{{{")
    for i,r in enumerate(rows):
        res='true' if lo<=i<=hi else 'false'
        print(f"    {{{float(r['rho_row']):.5f}, {float(r['C11']):.4f}, "
              f"{float(r['C12']):.4f}, {float(r['C44_xy']):.4f}, {res}}},")
    print("}};")

if __name__=='__main__':
    d='/tmp/tln_csv'; mode=sys.argv[1] if len(sys.argv)>1 else 'summary'
    order=['sc','bcc','fcc','diamond','kelvin','rhombic','octet','bccz','fccz','reentrant']
    for t in order:
        p=f'{d}/{t}_sweep.csv'
        if not os.path.exists(p): continue
        rows=load(p)
        if mode=='summary': summarize(t,rows)
        elif mode=='table' and (len(sys.argv)<3 or sys.argv[2]==t): emit(t,rows)
