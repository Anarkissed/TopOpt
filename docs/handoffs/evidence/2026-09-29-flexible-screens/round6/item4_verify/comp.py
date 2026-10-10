import sys, numpy as np
from PIL import Image
d=sys.argv[1]
for base in sys.argv[2:]:
    ui=np.asarray(Image.open(f"{d}/{base}_ui.png").convert('RGB')).astype(np.int16)
    mt=np.asarray(Image.open(f"{d}/{base}_metal.png").convert('RGB')).astype(np.int16)
    if ui.shape!=mt.shape:
        mt=np.asarray(Image.open(f"{d}/{base}_metal.png").convert('RGB').resize((ui.shape[1],ui.shape[0]))).astype(np.int16)
    bg=np.array([6,6,8])
    mask=(np.abs(ui-bg).sum(axis=2)<=6)
    out=ui.copy(); out[mask]=mt[mask]
    Image.fromarray(out.astype(np.uint8)).save(f"{d}/{base}_COMPOSITE.png")
    print(base, mask.mean())
