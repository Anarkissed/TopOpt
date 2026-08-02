#!/bin/zsh
# SW3 byte-identity — stash-rebuild checksum, HEAD vs NEW.
#
#   $1  HEAD output root   $2  NEW output root   $3.. job dirs
#
# Every artefact of a run is hashed: report.json, the exported STLs, design.bin,
# fields.bin, the lattice receipts, loadcase.json, the analysis reports.
#
# WHAT IS NORMALIZED, AND NOTHING ELSE. Three artefacts carry wall clocks, which
# differ between any two runs of the same binary and say nothing about physics:
#
#   run_info.json          `created_wall_ms`, `warm_start_coarse_ms`, and inside
#                          `lattice_export` the `gen_seconds` / `gen_fraction`
#                          generator timings. NOTE: `fingerprint` is NOT excused
#                          and is NOT normalized — it reads 8325a451a319 on BOTH
#                          sides here, because the fix is uncommitted in the
#                          working tree, so the two binaries report the same
#                          HEAD. It is compared like any other field.
#   build_orientation.json `sweep_seconds`, `strut_axis_measure_seconds`
#   iterations.csv         the per-iteration millisecond columns, and the HOST
#                          MEMORY readings (rss_mb, peak_rss_mb, compressed_mb,
#                          available_mb, major_faults, swapins) — process/OS
#                          state that varies between any two runs on a live
#                          machine and is not a property of the design
#
# Every one of those is a duration or a host-memory reading. No physics number,
# no verdict, no margin, no vertex, no iteration count, no CG count is excused:
# if one moved, it shows up here. The
# normalization is applied identically to both sides, and `--raw` prints the
# un-normalized comparison beside it so the exclusions can be checked rather
# than trusted.
set -e
HEAD_ROOT="$1"; NEW_ROOT="$2"

norm_file() {
  python3 - "$1" <<'PYEOF'
import json, os, sys, csv
p = sys.argv[1]; base = os.path.basename(p)
if base == 'run_info.json':
    d = json.load(open(p))
    for k in ('created_wall_ms', 'warm_start_coarse_ms'):
        if k in d: d[k] = '<normalized>'
    le = d.get('lattice_export')
    if isinstance(le, dict):
        for k in ('gen_seconds', 'gen_fraction'):
            if k in le: le[k] = '<normalized>'
    print(json.dumps(d, sort_keys=True, indent=1))
elif base == 'build_orientation.json':
    s = open(p).read()
    import re
    s = re.sub(r'"(sweep_seconds|strut_axis_measure_seconds)":\s*[-0-9.eE+]+',
               r'"\1": <normalized>', s)
    print(s)
elif base == 'iterations.csv':
    r = list(csv.reader(open(p)))
    if r:
        hdr = r[0]
        HOST = ('rss_mb', 'peak_rss_mb', 'compressed_mb', 'available_mb',
                'major_faults', 'swapins')
        drop = {i for i, h in enumerate(hdr)
                if h.endswith('_ms') or h == 'wall_ms' or h.endswith('_seconds')
                or h in HOST}
        for row in r:
            print(','.join(v for i, v in enumerate(row) if i not in drop))
else:
    sys.stdout.write(open(p, 'rb').read().decode('latin-1'))
PYEOF
}

hash_dir() {
  local root="$1" job="$2" raw="$3"
  # A REFUSED run still leaves a partial --out dir (loadcase.json, run_info.json
  # are written before the solve), so "did it produce a result" is the presence
  # of a report, not of a directory.
  [ -f "$root/$job/report.json" ] || [ -f "$root/$job/analysis_report.json" ] \
    || [ -f "$root/$job/lattice_variant.json" ] || { echo "REFUSED"; return; }
  { for f in $(cd "$root/$job" && find . -type f | sort); do
      echo "$f"
      if [ -n "$raw" ]; then shasum -a 256 "$root/$job/$f" | cut -d' ' -f1
      else norm_file "$root/$job/$f" | shasum -a 256 | cut -d' ' -f1
      fi
    done } | shasum -a 256 | cut -d' ' -f1
}

printf '%-46s %-18s %-18s %-34s %s\n' JOB HEAD NEW VERDICT 'RAW (nothing normalized)'
for job in "${@:3}"; do
  h="$(hash_dir "$HEAD_ROOT" "$job")"; n="$(hash_dir "$NEW_ROOT" "$job")"
  rh="$(hash_dir "$HEAD_ROOT" "$job" raw)"; rn="$(hash_dir "$NEW_ROOT" "$job" raw)"
  if [ "$h" = "REFUSED" ] && [ "$n" != "REFUSED" ]; then v="HEAD REFUSED -> NEW RAN (THE FIX)"
  elif [ "$n" = "REFUSED" ] && [ "$h" != "REFUSED" ]; then v="*** NEW REFUSED — REGRESSION ***"
  elif [ "$h" = "REFUSED" ] && [ "$n" = "REFUSED" ]; then v="both REFUSED (unchanged)"
  elif [ "$h" = "$n" ]; then v="BYTE-IDENTICAL"
  else v="*** DIFFERS ***"
  fi
  if [ "$rh" = "$rn" ]; then rv="identical even raw"
  elif [ "$rh" = "REFUSED" ] || [ "$rn" = "REFUSED" ]; then rv="-"
  else rv="differs (wall clocks only)"
  fi
  printf '%-46s %-18s %-18s %-34s %s\n' "$job" "${h:0:16}" "${n:0:16}" "$v" "$rv"
done
