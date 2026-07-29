#!/bin/sh
# Build the P2 RSS probe against the always-built libtopopt.a (no OCCT/Eigen/lib3mf
# needed — generator + streaming writers are pure mesh/std).
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
c++ -std=c++17 -O2 -I"$ROOT/core/include" \
  "$ROOT/evidence/2026-07-28-lattice-generation-production/rss_probe.cpp" \
  "$ROOT/core/build/libtopopt.a" \
  -o "$ROOT/evidence/2026-07-28-lattice-generation-production/rss_probe"
