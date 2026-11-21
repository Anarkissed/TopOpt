#!/bin/zsh
# opt_run.sh <arm> : the stand's optimize job through the SAME binary that made standvar (core aecef72c)
d=/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad/agentwork/band101/opt_$1
cd $d && /usr/bin/time -p nice -n 19 /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad/cli-presync/topopt-cli run opt.json --out run --materials /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/lattice-stage-frontend-37bee1/core/src/materials/materials.json --rules /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/lattice-stage-frontend-37bee1/core/src/settings/rules.json > run.log 2>&1
echo "exit $?" > $d/DONE
