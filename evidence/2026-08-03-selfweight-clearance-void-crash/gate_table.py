import json,sys,os
def rows(path):
    r=json.load(open(path))
    out=[]
    for kind in ('variants','rejected_variants'):
        for v in r.get(kind,[]):
            out.append((v['printed_fraction'], 'ACCEPTED' if v['accepted'] else 'REJECTED',
                        v['margin']['worst_case'], v['margin_effective'],
                        v['margin_required'], v['max_stress_mpa'],
                        v.get('rejection_reason','')))
    out.sort(key=lambda t:-t[0])
    return out
for label,d in zip(sys.argv[1::2], sys.argv[2::2]):
    p=os.path.join(d,'report.json')
    if not os.path.exists(p):
        print(f'{label:<34} (no report.json — the run REFUSED)'); continue
    print(label)
    print('    printed_fr   verdict     margin_worst_case    margin_effective   required   max_stress_mpa')
    for pf,acc,mw,me,mr,ms,rr in rows(p):
        print(f'    {pf:10.7f}   {acc}   {mw:17.10g}  {me:17.10g}  {mr:9g}   {ms:14.10g}  {rr}')
