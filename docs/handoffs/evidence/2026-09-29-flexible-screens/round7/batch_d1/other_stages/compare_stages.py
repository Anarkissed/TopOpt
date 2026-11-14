import sys, os
from PIL import Image, ImageChops
a, b = sys.argv[1], sys.argv[2]
names = sorted(f for f in os.listdir(a) if f.endswith('.png'))
tot = 0
for n in names:
    pa, pb = os.path.join(a, n), os.path.join(b, n)
    if not os.path.exists(pb): print(f'{n}: MISSING in {b}'); tot += 1; continue
    ia, ib = Image.open(pa).convert('RGBA'), Image.open(pb).convert('RGBA')
    if ia.size != ib.size: print(f'{n}: SIZE {ia.size} vs {ib.size}'); tot += 1; continue
    d = ImageChops.difference(ia, ib).convert('L')
    px = sum(1 for v in d.getdata() if v > 0)
    bbox = d.getbbox()
    print(f'{n}: {"IDENTICAL" if px == 0 else "DIFFERS"} ({px} px differ{", bbox " + str(bbox) if bbox else ""})')
    tot += px > 0
print(f'{len(names)} images, {tot} differ')
