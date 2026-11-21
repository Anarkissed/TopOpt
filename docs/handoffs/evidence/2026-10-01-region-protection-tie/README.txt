band101 — region 101's unprotected slab on the stand, counted by CORE (topopt-cli lattice-variant, forecast_only)
outline_u.py        unexpanded facet outlines (inverse of the app's offsetRing; round-trip <=3.3e-9 mm)
make_jobs*.py       job generators (sets = lattice role regions; kind "region" = the protection mask)
run1.sh / run1a.sh  run one job: ./run1.sh <design>__<set>   (cli-postsync, forecast_only, ~2 s)
tabulate.py         region_voxels table; emptied = lattice_part count - variant count
opt_before_rerun/   standvar/opt.json re-run with cli-presync (aecef72c): design.bin byte-identical to standvar
opt_after/          same job, region 101 protection 20 -> 24.15 (cli-presync); ./opt_run.sh after (~285 s)
