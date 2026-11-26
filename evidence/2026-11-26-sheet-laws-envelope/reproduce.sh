#!/usr/bin/env zsh
# Reproduce the sheet law on the OFF-GRIP ENVELOPE (the reviewer's ruling of 2026-11-26, item 3): the cut sweep
# (a), the bending at 3 / 4 / 6 cells at a finer pitch (c), batch B when the floor is still 2 (d), the fit, the
# floor and core's table. On notes28's fixtures (../2026-11-25-sheet-laws-thin-members: its reproduce.sh makes
# them). Machine of record: Apple M2 Pro (6P + 4E cores, 16 GB), Apple clang; library Release, probes -O3/-O2.
# Deterministic: every law solve single-threaded, fixed-seed states.
#
# Every job is one line of jobs_*.txt (in this folder):
#   w    <type> <rho> <N> <vpc> <cuts>      lattice_dehomog_probe widths (one block width, one pitch)
#   bend <type> <vf> <vpc> <ncs> <threads>  tpms_probe bend (C2b guided cantilever, matrix-free)
# The jobs are independent; the record ran them side by side under HEAVY.lock, each behind a memory gate.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-11-26-sheet-laws-envelope

cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt -j3
c++ -std=c++17 -O3 -DNDEBUG -I core/include -I /opt/homebrew/include/eigen3 \
    core/tests/harness/lattice_dehomog_probe.cpp core/build/libtopopt.a \
    -framework Accelerate -o core/build/lattice_dehomog_probe
(cd core && c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/tpms_probe.cpp build/libtopopt.a -framework Accelerate -o build/tpms_probe)

job() {
  local kind=$1; shift
  case $kind in
    w)
      local t=$1 rho=$2 n=$3 vpc=$4 cuts=$5 tag="r$2_N$3_v$4_c${5//,/-}"
      mkdir -p $EV/$t/parts $EV/$t/logs
      TOPOPT_DEHOMOG_TYPE=$t TOPOPT_DEHOMOG_W_RHOS=$rho TOPOPT_DEHOMOG_W_NS=$n \
      TOPOPT_DEHOMOG_W_CUTS=$cuts TOPOPT_DEHOMOG_W_VPC=$vpc TOPOPT_DEHOMOG_W_TAG=$tag \
      TOPOPT_DEHOMOG_MATFREE=1 \
        ./core/build/lattice_dehomog_probe widths $EV/$t/parts > $EV/$t/logs/w_$tag.log 2>&1 ;;
    bend)
      local d=$EV/bend/$1_vf$2_vpc$3_nc${4//,/-}
      mkdir -p $d
      TOPOPT_LATTICE_CSV_DIR=$d TOPOPT_TP_BEND_VF=$2 TOPOPT_TP_BEND_VPC=$3 TOPOPT_TP_BEND_NC=$4 \
      TOPOPT_BEND_MATFREE=1 TOPOPT_TP_THREADS=$5 ./core/build/tpms_probe bend $1 > $d/$1_bend.txt 2>&1 ;;
  esac
}
run() { grep -v '^#' $EV/$1 | grep -v '^ *$' | while read -r line; do job ${=line}; done }

gather() {
  for t in gyroid schwarz_d; do
    for k in states exact cells; do
      first=1
      for p in $EV/$t/parts/k_${k}_w_*.csv(N); do
        [[ -s $p ]] || continue
        if (( first )); then cat $p; first=0; else tail -n +2 $p; fi
      done > $EV/$t/k_${k}_w_all.csv
    done
    gzip -nf $EV/$t/k_cells_w_all.csv
  done
  python3 -I $EV/envelope.py $EV > $EV/envelope.txt
  python3 -I $EV/steady_env.py $EV > $EV/steady_env.txt
}

# (a) the sweep: the screen (every new voxel layer from half a cell up, N = 2, 3, 4), then the wide widths
# (N = 5, 6, 8) at the screen's worst new layers, chosen from the screen's own parts.
python3 -I $EV/make_jobs.py screen $EV
run jobs_1_screen.txt
python3 -I $EV/make_jobs.py wide $EV
run jobs_2_wide.txt
# (c) bending at 2, 3, 4 and 6 cells, finer pitch
run jobs_3_bend.txt
gather
# (d) batch B only if the floor is still 2 for both sheets
if grep -q "NOT steady" $EV/steady_env.txt; then
  echo "the floor moved off 2: batch B is not run (the ruling's (d))"
else
  run jobs_4_B.txt
  gather
fi
python3 -I $EV/bending_table.py $EV > $EV/bending_346.txt
python3 -I $EV/gen_tables.py $EV core/src/fea/sheet_width_law_tables.inc
