#!/bin/sh
# THE HOST WAS NOT IDLE, AND THIS SAYS SO RATHER THAN LEAVING IT TO BE ASSUMED.
# Two other worktrees were running their own solver jobs for the whole of S2.
# Samples every 60 s: load average, and every process over 50% CPU.
while :; do
  printf '%s  load=%s\n' "$(date -u +%FT%TZ)" \
    "$(uptime | sed 's/.*load averages*: //')"
  ps -eo pcpu,comm -r | awk 'NR>1 && $1>50 {printf "    %6.1f%%  %s\n", $1, $2}' | head -6
  sleep 60
done
