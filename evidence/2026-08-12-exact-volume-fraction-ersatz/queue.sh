#!/bin/sh
# The remaining work, STRICTLY SERIAL at 3 threads. He needs his machine.
#
# Ordered by what the handoff cannot be written without: the two arms first,
# then their measurements, then the probes that need no optimiser and can be
# re-run at any time.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
sh "$HERE/run_arms.sh"
sh "$HERE/measure.sh"
sh "$HERE/run_probes.sh"
sh "$HERE/run_fd.sh"
echo QUEUE_DONE
