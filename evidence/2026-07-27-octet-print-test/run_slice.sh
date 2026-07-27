#!/bin/bash
# Slice the octet print-test blocks with BambuStudio's headless CLI
# (handoff 2026-07-27-octet-print-test). Reproduces the sliced results in files/.
#
# Slicer: BambuStudio 02.07.01.62 (installed at /Applications/BambuStudio.app).
# Profiles: Bambu Lab A1, 0.4 mm nozzle, Generic PLA, 0.20 mm layer — all stock
# system presets, EXCEPT the process override below.
#
# CRITICAL FINDING encoded here: the interpenetrating soup does NOT slice under
# BambuStudio's DEFAULT Arachne (variable-width) wall generator — it aborts with
# "Flow::spacing() produced negative spacing ... width 0.0429" because Arachne
# tries to fit sub-0.05 mm walls into the slivers where struts overlap. Switching
# to the CLASSIC wall generator (fixed-width offsets) is what makes it slice. That
# override is the whole reason this script writes a modified process JSON.
#
# NOTE: run headless the filament preset does not bind a filament_id, so
# result.json reports filament_usage_g = 0. The toolpaths are complete regardless
# (26 MB of G-code); only the mass/one-line summary is unreliable in CLI mode.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BS="/Applications/BambuStudio.app/Contents/MacOS/BambuStudio"
RES="/Applications/BambuStudio.app/Contents/Resources/profiles/BBL"
MACH="$RES/machine/Bambu Lab A1 0.4 nozzle.json"
SYSPROC="$RES/process/0.20mm Standard @BBL A1.json"
FIL="$RES/filament/Generic PLA @BBL A1.json"

WORK="${1:-/private/tmp/claude-501/octet-slice}"
mkdir -p "$WORK"

# Modified process: classic walls (see finding above), outer wall width pinned to
# 0.42 mm, thin-wall detect off. Everything else inherited from the stock preset.
PROC="$WORK/process_octet.json"
python3 - "$SYSPROC" "$PROC" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p['wall_generator'] = 'classic'
p['outer_wall_line_width'] = '0.42'
p['detect_thin_wall'] = '0'
p['name'] = 'octet-test 0.20 A1 (classic walls)'
json.dump(p, open(sys.argv[2], 'w'), indent=2)
PY

for B in uniform graded; do
  OUT="$WORK/${B}_final"; mkdir -p "$OUT"
  STL="$HERE/files/octet_${B}_40mm.stl"
  echo "=== slicing $B ==="
  /usr/bin/time -l "$BS" --debug 4 \
    --load-settings "$MACH;$PROC" --load-filaments "$FIL" \
    --slice 0 --outputdir "$OUT" --export-3mf ${B}_sliced.3mf \
    "$STL" > "$OUT/slice.log" 2>&1 || true
  echo "  return_code: $(python3 -c "import json;print(json.load(open('$OUT/result.json'))['return_code'])" 2>/dev/null || echo '?')"
  echo "  gcode: $(wc -c < "$OUT/plate_1.gcode" 2>/dev/null || echo 'MISSING') bytes"
done
echo "done -> $WORK"
