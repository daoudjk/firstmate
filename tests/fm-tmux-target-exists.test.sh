#!/usr/bin/env bash
# tests/fm-tmux-target-exists.test.sh - fm_backend_target_exists on tmux against
# a REAL tmux server on a private socket. A missing target must read absent even
# while other panes live (display-message would answer with the current pane).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-target-exists-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-target-exists.XXXXXX")
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$LAB"; }
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

mkdir -p "$LAB/shim"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
. "$ROOT/bin/fm-backend.sh"

tmux new-session -d -s lab -n alpha "sleep 300" || fail "session"
tmux new-window -t lab -n beta "sleep 300"
PANE=$(tmux list-panes -t lab:beta -F '#{pane_id}' | head -n1)

check() {  # <want-rc> <target> <label>
  local want=$1 target=$2 label=$3 rc
  fm_backend_target_exists tmux "$target"; rc=$?
  [ "$rc" -eq "$want" ] || fail "$label: want rc $want got $rc ($target)"
  pass "$label"
}
check 0 lab:alpha "window by name"
check 0 lab:beta "second window by name"
check 0 lab:0 "window by index"
check 0 lab:beta.0 "window.pane"
check 0 "=lab:beta" "exact session prefix"
check 0 "$PANE" "pane id"
check 1 lab:gamma "missing window while other panes live"
check 1 lab:alph "window-name prefix is not a match"
check 1 lab:beta.7 "missing pane index"
check 1 ghost:alpha "missing session"
check 1 %9999 "missing pane id"
check 2 "" "empty target"
check 2 alpha "no session separator"
check 2 lab: "empty window"
check 2 :alpha "empty session"
check 2 a:b:c "too many separators"
check 2 %abc "malformed pane id"

tmux kill-server
check 3 lab:alpha "unreachable server is unreadable, not absent"
check 3 %1 "unreachable server pane id"
