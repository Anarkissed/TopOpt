#!/bin/zsh
# run ONE forecast job: run1.sh <name>   (jobs/<name>.json -> runs/<name>/)
set -u
S=/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad
W=/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/lattice-stage-frontend-37bee1
H=$S/agentwork/band101
n=$1; d=$H/runs/$n
mkdir -p $d/out
cp $H/jobs/$n.json $d/job.json
ln -sf $S/standvar/model.step $d/model.step
ln -sf $S/standvar/run/design.bin $d/design.bin; ln -sf $H/opt_after/run/design.bin $d/design_after.bin
nice -n 19 $S/cli-postsync/topopt-cli lattice-variant $d/job.json --out $d/out \
  --materials $W/core/src/materials/materials.json --rules $W/core/src/settings/rules.json > $d/log.txt 2>&1
echo "$n exit $?" > $d/EXIT
