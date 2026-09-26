#!/bin/bash
# Run the plugin standalone on a headless output, without touching the shell
# or the user's screen. Creates the output if needed, then:
#   tests/harness.sh            start (logs to ~/.cache/mission-control-harness/log)
#   tests/harness.sh stop
#   tests/harness.sh ipc open '{"mode":"app"}'   | hide | state | toggle app
#   tests/harness.sh ipc panel 'panel.stripExpanded = true'
#   grim -o HEADLESS-1 shot.png
# The harness needs qs.Commons/Ui/services from the shell, so it symlinks them
# next to a copy of harness.qml under ~/.cache.
set -euo pipefail
plugin=$(cd "$(dirname "$0")/.." && pwd)
dir=${XDG_CACHE_HOME:-$HOME/.cache}/mission-control-harness
screen=${MISSION_CONTROL_TEST_SCREEN:-HEADLESS-1}
case ${1:-start} in
  start)
    mkdir -p "$dir"
    for d in Commons Ui services; do ln -sfn "/usr/share/omarchy/shell/$d" "$dir/$d"; done
    cp "$plugin/tests/harness.qml" "$dir/shell.qml"
    hyprctl monitors -j | grep -q "\"name\": \"$screen\"" || hyprctl output create headless "$screen" >/dev/null
    MC_PLUGIN=$plugin MISSION_CONTROL_TEST_SCREEN=$screen setsid quickshell -p "$dir/shell.qml" >"$dir/log" 2>&1 &
    echo $! >"$dir/pid"
    echo "started on $screen (pid $!), log: $dir/log"
    ;;
  stop)
    [[ -f $dir/pid ]] && kill "$(cat "$dir/pid")" 2>/dev/null || true
    rm -f "$dir/pid"
    ;;
  ipc)
    shift
    qs -p "$dir/shell.qml" ipc call mc "$@"
    ;;
  *) echo "usage: $0 [start|stop|ipc <call> ...]" >&2; exit 2 ;;
esac
