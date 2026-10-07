#!/usr/bin/env bash
# tests/fm-crew-state-stopped.test.sh - the `stopped` current state of
# bin/fm-crew-state.sh against a REAL tmux server on a private socket.
#
# A worker whose agent process exited leaves its endpoint as a live shell. For an
# adapter with no verified semantic busy source (Codex) the busy classifier can
# only answer unknown, which made every stopped worker unreadable. The backend's
# recovery-grade classifier (fm_backend_agent_state) separately proves the agent
# is absent, so the reader reports stopped - agent not running, nothing more -
# and keeps every other endpoint verdict as it was.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-crew-stopped-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-stopped.XXXXXX")
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$LAB"; }
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

mkdir -p "$LAB/shim" "$LAB/state" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"

# A live agent stand-in (a long-running foreground program) and a bare shell.
tmux new-session -d -s lab -n running "sleep 300" || fail "session"
tmux new-window -t lab -n shelled "bash --norc --noprofile -i" || fail "shell window"
sleep 1

write_meta() {  # <id> <window> <harness> <kind>
  cat > "$LAB/state/$1.meta" <<EOM
window=$2
worktree=$LAB/wt
project=$LAB/wt
harness=$3
kind=$4
mode=no-mistakes
EOM
}
read_state() {  # <id>
  FM_STATE_OVERRIDE="$LAB/state" FM_HOME="$LAB" "$ROOT/bin/fm-crew-state.sh" "$1" 2>&1
}
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

write_meta codex-stopped lab:shelled codex scout
out=$(read_state codex-stopped)
contains "$out" "state: stopped · source: endpoint" || fail "a Codex worker whose agent exited must read stopped: $out"
contains "$out" "agent process absent, endpoint shell retained" || fail "the stopped reading must name what is absent: $out"
contains "$out" "codex-unverified" || fail "the stopped reading must keep the unverified busy source visible: $out"
pass "a Codex endpoint holding only a shell reads stopped, not unknown"

write_meta codex-running lab:running codex scout
out=$(read_state codex-running)
contains "$out" "state: unknown · source: pane" || fail "a Codex endpoint with a live foreground program must stay unknown: $out"
contains "$out" "codex-unverified" || fail "an unverified running worker keeps its unverified reason: $out"
contains "$out" "stopped" && fail "a running endpoint must never read stopped: $out"
pass "a Codex endpoint with a live foreground program stays unknown"

write_meta codex-gone lab:nothere codex scout
out=$(read_state codex-gone)
contains "$out" "state: stopped" && fail "a missing window is not a stopped agent: $out"
contains "$out" "state: unknown" || fail "a missing window stays unknown: $out"
pass "a missing window never reads stopped"

write_meta claude-shelled lab:shelled claude scout
printf 'paused: waiting on primary\n' > "$LAB/state/claude-shelled.status"
out=$(read_state claude-shelled)
contains "$out" "state: stopped · source: endpoint" || fail "an unarmed Claude worker (busy source missing) with only a shell reads stopped: $out"
contains "$out" "busy source: unknown missing" || fail "the missing busy source stays in the detail: $out"
pass "a harness whose busy source is missing also reads stopped on positive absence evidence"

tmux kill-server
out=$(read_state codex-stopped)
contains "$out" "state: stopped" && fail "an unreachable server proves nothing and must not read stopped: $out"
contains "$out" "state: unknown" || fail "an unreachable server stays unknown: $out"
pass "an unreachable server stays unknown, never stopped"
