#!/usr/bin/env zsh
# Reproduce the sheet laws per member width (sheets spec 2026-11-25 rev 3, section 3.2; builder D):
# the gyroid's and Schwarz-D's strength law and bending error for members N = 2..8 cells across,
# by the 11-09 method (evidence/2026-11-09-lattice-type-strut-laws/reproduce.sh: bulk, finite
# blocks, boundary populations, envelope, aliasing guard and its finer-pitch re-measure).
# Machine of record: Apple M2 Pro (6P + 4E cores, 16 GB), Apple clang; library Release, probes -O3/-O2.
# Deterministic: every law solve is single-threaded (fea_set_matfree_threads(1)), fixed-seed states.
#
# Every job is one line of jobs_*.txt (in this folder): its kind, then its arguments.
#   w    <type> <rho> <N> <vpc> <cuts>      lattice_dehomog_probe widths (one block width, one pitch)
#   sb   <type>                             lattice_dehomog_probe selfcheck (S1-S6) + bulk
#   bend <type> <vf> <vpc> <ncs> <threads>  tpms_probe bend (C2b guided cantilever, matrix-free)
# The jobs are independent; the record ran them side by side (6 at a time) under HEAVY.lock.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-11-25-sheet-laws-thin-members

cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt -j8
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
    sb)
      mkdir -p $EV/$1
      TOPOPT_DEHOMOG_TYPE=$1 ./core/build/lattice_dehomog_probe selfcheck $EV/$1 > $EV/$1/selfcheck.log 2>&1
      TOPOPT_DEHOMOG_TYPE=$1 ./core/build/lattice_dehomog_probe bulk $EV/$1 > $EV/$1/bulk.log 2>&1 ;;
    bend)
      local d=$EV/bend/$1_vf$2_vpc$3_nc${4//,/-}
      mkdir -p $d
      TOPOPT_LATTICE_CSV_DIR=$d TOPOPT_TP_BEND_VF=$2 TOPOPT_TP_BEND_VPC=$3 TOPOPT_TP_BEND_NC=$4 \
      TOPOPT_BEND_MATFREE=1 TOPOPT_TP_THREADS=$5 ./core/build/tpms_probe bend $1 > $d/$1_bend.txt 2>&1 ;;
  esac
}
for f in $EV/jobs_*.txt; do
  grep -v '^#' $f | grep -v '^ *$' | while read -r line; do job ${=line}; done
done

# Gather each type's parts and fit the law per width (kfit_widths.csv). The wide row is 11-09's
# law (valid from 10 / 9 cells across): no narrower row may credit more than it.
for t in gyroid schwarz_d; do
  for k in states exact cells; do
    first=1
    for p in $EV/$t/parts/k_${k}_w_*.csv; do
      if (( first )); then cat $p; first=0; else tail -n +2 $p; fi
    done > $EV/$t/k_${k}_w_all.csv
  done
  TOPOPT_DEHOMOG_TYPE=$t TOPOPT_DEHOMOG_W_FILES=k_exact_w_all.csv \
  TOPOPT_DEHOMOG_WIDE_KFIT=evidence/2026-11-09-lattice-type-strut-laws/$t/kfit.csv \
    ./core/build/lattice_dehomog_probe fitw $EV/$t > $EV/$t/fitw.log 2>&1
done
