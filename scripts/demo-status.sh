#!/bin/sh
# Step a window of the hauntty session through the tab status dots: working,
# blocked, working, done, error and idle. It picks the first window that is
# not active, since done and idle only show on background tabs. Run it from
# any shell.
#
#   scripts/demo-status.sh          run the steps once
#   scripts/demo-status.sh --loop   repeat until stopped, then clear the dot
set -eu

tmux=$(command -v tmux)
window=$(env -u TMUX "$tmux" list-windows -t '=hauntty' -F '#{window_active} #{window_id}' |
  awk '$1 == 0 { print $2; exit }')
if [ -z "$window" ]; then
  echo "The hauntty session needs a second window." >&2
  exit 1
fi

status() {
  echo "$1"
  env -u TMUX "$tmux" set-option -w -t "$window" @hauntty-status "$1"
}

clear_status() {
  env -u TMUX "$tmux" set-option -w -u -t "$window" @hauntty-status 2>/dev/null || true
}

steps() {
  status working
  sleep 4
  status blocked
  sleep 4
  status working
  sleep 4
  status done
  sleep 4
  status error
  sleep 4
  status idle
  sleep 4
}

if [ "${1:-}" = "--loop" ]; then
  trap 'clear_status; exit 0' INT TERM
  while :; do steps; done
else
  steps
  echo "Clear it with: tmux set-option -w -u -t '$window' @hauntty-status"
fi
