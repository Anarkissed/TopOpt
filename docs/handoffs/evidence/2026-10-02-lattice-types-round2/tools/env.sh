# Shared paths for the round-2 evidence tools. Source it; override any variable before sourcing.
# Local evidence (his data, dumps, CLI copies) lives in the worktree's git-ignored scratch/, so a
# session restart cannot wipe it and nothing of his is ever committed.
REPO=${REPO:-$(cd "$(dirname "${(%):-%x}")/../../../../.." && pwd)}
EVID=${EVID:-$REPO/scratch/evidence}
# His simulator store — READ ONLY. Never write into the container.
STORE=${STORE:-"/Users/nadim/Library/Developer/CoreSimulator/Devices/A030C20C-D243-4CC4-A602-E2A90FB6CCDF/data/Containers/Data/Application/4808BBCC-CC1B-4C05-B405-004BFBA46A56/Library/Application Support/TopOpt/Projects"}
PROJECTS=(102117B9-DDD2-4597-9BDE-49DD47EBF393 68BF7B74-3C2A-4ED6-A46D-AC040A9CA649
          92A8016E-FCCD-421D-B19E-4A1EC81C98A5 570B38E2-3C6E-46E0-BCF6-26BE1595D204
          3418E167-8524-4831-A809-827B6B0742D0 AA4C7953-3152-4123-BCB5-EF5F8A08ABA3
          887AC498-5B5D-4475-B6CB-893DC69B5FD6)
mkdir -p "$EVID/snapshots" "$EVID/work" "$EVID/dumps" "$EVID/cli"
