#!/usr/bin/env bash
# fm-handover.sh - supervisor-to-supervisor handover record for one home.
#
# A supervisor session that winds down for another session (often on another
# provider) leaves exactly ONE durable record, state/handover.json, generated
# from the records recovery already reads, plus a human-readable summary under
# data/handover/. The incoming session's digest prints a HANDOVER PENDING
# section while that record exists (bin/fm-session-start.sh), so the handover is
# found where recovery looks instead of in free documents.
# The procedure for both sides is owned by the session-handover skill; this
# header owns the record and the commands.
#
# Usage:
#   fm-handover.sh prepare
#   fm-handover.sh write [--goal-file <path>] [--notes-file <path>]
#                        [--next <task>=<text>]... [--hold <task>]... [--replace]
#   fm-handover.sh release
#   fm-handover.sh status [--digest]
#   fm-handover.sh resume-plan
#   fm-handover.sh mark <task> hold|running
#   fm-handover.sh accept
#
# prepare   A read-only CHECK. It prints one `GAP <kind> <task>: ...; fix: ...`
#           line per gap and exits 1, or prints `prepare: ready ...` and exits
#           0. It never fixes anything; each line names the command that does.
#           Gaps: a live worker (state/<task>.meta, any kind but secondmate)
#           with no backlog item; a worker whose bin/fm-crew-state.sh line reads
#           `unknown`; and an open needs-decision (the bin/fm-classify-lib.sh
#           fold) that no captain hold covers. A decision is covered when
#           `bin/fm-captain-hold.sh open` answers 0 for the worker's own task,
#           the decision key, or `<task>-decision-<key>`.
#           Worker facts come from one bin/fm-fleet-snapshot.sh --json read, and
#           the backlog check uses the same row probe bin/fm-spawn.sh uses.
# write     Runs the same check and refuses on any gap, then writes
#           state/handover.json (schema fm-handover.v1) and
#           data/handover/<utc-stamp>.md, plus one relaunch note per worker
#           under data/handover/<utc-stamp>/. Per worker it records the task
#           id, kind, harness, model, effort, local copy, branch, head, dirty
#           and unpushed flags read from git, PR URL, the fm-crew-state.sh line,
#           spawn_gen, open decisions, intent (`resume` unless --hold names it),
#           and the next step: an explicit --next, else an excerpt of the
#           worker's own HANDOFF.md (data/<task>/HANDOFF.md, then the local
#           copy's HANDOFF.md). It also records the backlog's in-flight and held
#           items, every registered second mate's home with that home's active
#           workers, and the outgoing supervisor's --goal-file and --notes-file
#           text verbatim. It never writes a worker status line. A pending
#           record is refused unless --replace.
# release   Refuses unless a record exists, and refuses while away or quiet
#           supervision is active (state/.afk). Releases this session's lock
#           (bin/fm-lock.sh release) and then stops this home's watcher through
#           its home-scoped owner (bin/fm-watch-arm.sh --stop), in that order so
#           a Stop-hook re-arm cannot start a successor for a session that no
#           longer owns the lock. Records released_at in the record.
# status    Prints whether a handover is pending and its summary. --digest is
#           the bounded rendering bin/fm-session-start.sh prints. Exit 0.
# resume-plan
#           Prints, per worker, the exact bin/fm-control.sh relaunch command
#           with its recorded note file. When the recorded harness differs from
#           this session's harness (bin/fm-harness.sh) the command carries
#           `--harness <harness> --model <model>` placeholders to fill per the
#           dispatch rules. Hold rows, relaunched rows, and second mates' own
#           workers are listed without a command. Read-only.
# mark      `hold` switches a worker's intent to hold; `running` records that a
#           resume worker is already running and needs no relaunch.
# accept    The incoming session consumes the record: it moves
#           state/handover.json to state/handover.accepted.<utc-stamp>.json. It
#           refuses while any resume worker is neither relaunched (its
#           state/<task>.meta spawn_gen differs from the recorded one, which
#           every fm-spawn.sh launch and fm-control.sh relaunch rewrites) nor
#           marked. A worker whose metadata is gone was cleaned up and counts as
#           resolved.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORD="$STATE/handover.json"
SUMMARY_DIR="$DATA/handover"
SCHEMA=fm-handover.v1
PARKED_LINE='the fleet is parked on purpose; run bin/fm-handover.sh resume-plan and relaunch the resume rows; a quiet queue is NOT progress'
DIGEST_ROWS=${FM_HANDOVER_DIGEST_ROWS:-20}
case "$DIGEST_ROWS" in ''|*[!0-9]*|0) DIGEST_ROWS=20 ;; esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die() { printf 'fm-handover: %s\n' "$*" >&2; exit 1; }
usage() {
  sed -n '/^# Usage:/,/^# prepare/p' "$SCRIPT_DIR/fm-handover.sh" | sed '$d; s/^# \{0,1\}//'
}

command -v jq >/dev/null 2>&1 || die "jq is required"

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }

# Shell-quote one argument for a printed command line.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Replace the record atomically with the jq filter's output. Callers pass jq
# programs in single quotes on purpose: the $names are jq variables.
record_update() {  # <jq-args...>
  local tmp
  tmp=$(mktemp "$STATE/.handover.json.XXXXXX") || die "cannot write $RECORD"
  if jq "$@" "$RECORD" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$RECORD" || { rm -f "$tmp"; die "cannot replace $RECORD"; }
  else
    rm -f "$tmp"
    die "cannot update $RECORD"
  fi
}

require_record() {
  [ -f "$RECORD" ] || die "no handover is pending in this home ($RECORD absent); the outgoing session runs bin/fm-handover.sh write first"
  jq -e --arg s "$SCHEMA" '.schema == $s' "$RECORD" >/dev/null 2>&1 \
    || die "$RECORD is not a readable $SCHEMA record"
}

# --- inputs shared by prepare and write -------------------------------------

SNAPSHOT=
read_snapshot() {
  SNAPSHOT=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null) \
    || die "bin/fm-fleet-snapshot.sh --json failed; run it directly to see why"
  printf '%s' "$SNAPSHOT" | jq -e '.tasks | type == "array"' >/dev/null 2>&1 \
    || die "bin/fm-fleet-snapshot.sh --json returned no task list"
  # The snapshot leaves a remote second mate's state unknown by design, so its
  # current-state line comes from bin/fm-crew-state.sh itself, bounded.
  local id raw
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    raw=$(FM_HOME="$FM_HOME" fm_run_timed 30 "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | head -1) || true
    SNAPSHOT=$(printf '%s' "$SNAPSHOT" | jq -c --arg id "$id" --arg raw "$raw" '
      .tasks |= map(if .id == $id then .current_state = {
        raw:$raw,
        state:(($raw | capture("^state: (?<s>[^ ]+)")? | .s) // "unknown"),
        source:(($raw | capture(" · source: (?<s>[^ ]+)")? | .s) // "none")} else . end)')
  done <<EOF
$(printf '%s' "$SNAPSHOT" | jq -r '.tasks[] | select(.remote != null) | .id')
EOF
}

HOLD_IDS=' '
is_hold() { case "$HOLD_IDS" in *" $1 "*) return 0 ;; esac; return 1; }

# Backlog presence for one worker, by the same row probe bin/fm-spawn.sh uses.
# Prints a gap line and returns 1 when the item is missing or unreadable.
check_backlog() {  # <id> <kind>
  local id=$1 kind=$2 rc
  fm_backlog_transition_applies "$CONFIG" "$DATA" "$kind"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    if fm_backlog_row_probe "$DATA" "$id"; then
      return 0
    elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      printf 'GAP backlog %s: live worker with no backlog item; fix: bin/fm-tasks-axi.sh add %s %s --kind %s && bin/fm-tasks-axi.sh start %s\n' \
        "$id" "$id" "$(shq "<title>")" "$kind" "$id"
      return 1
    fi
    printf 'GAP backlog %s: backlog item unreadable (%s); fix: bin/fm-tasks-axi.sh show %s\n' \
      "$id" "${FM_BACKLOG_ROW_ERROR:-unknown error}" "$id"
    return 1
  elif [ "$rc" -eq 2 ]; then
    printf 'GAP backlog %s: backlog unreadable (%s); fix: bin/fm-tasks-axi.sh list\n' \
      "$id" "${FM_BACKLOG_TRANSITION_ERROR:-unknown error}"
    return 1
  fi
  # Manual editing or no backlog file: the snapshot's markdown parse decides.
  if printf '%s' "$SNAPSHOT" | jq -e --arg id "$id" '
      .backlog.present == true
      and any(.backlog.records[]?;
        (.id == $id) or ((.raw // "") | test("(^|[^A-Za-z0-9._-])" + ($id | gsub("[.]"; "[.]")) + "([^A-Za-z0-9._-]|$)")))' >/dev/null 2>&1; then
    return 0
  fi
  printf 'GAP backlog %s: live worker with no backlog item (%s); fix: add an In flight item for %s to data/backlog.md\n' \
    "$id" "${FM_BACKLOG_TRANSITION_SKIP:-no backlog file}" "$id"
  return 1
}

# The whole prepare check. Prints one line per gap and sets GAP_COUNT.
GAP_COUNT=0
run_checks() {
  local row id kind state raw key verb summary covered n=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id')
    kind=$(printf '%s' "$row" | jq -r '.kind // ""')
    state=$(printf '%s' "$row" | jq -r '.current_state.state // "unknown"')
    raw=$(printf '%s' "$row" | jq -r '.current_state.raw // ""')
    if [ "$kind" != secondmate ]; then
      check_backlog "$id" "$kind" || n=$((n + 1))
    fi
    if [ "$state" = unknown ] || [ -z "$raw" ]; then
      printf 'GAP state %s: bin/fm-crew-state.sh reads "%s"; fix: a live worker declares its state after bin/fm-send.sh %s %s, a gone endpoint is recovered first (stuck-crewmate-recovery: bin/fm-control.sh %s relaunch --note %s)\n' \
        "$id" "${raw:-nothing}" "$id" \
        "$(shq 'Append one status line with your current state (working, paused, blocked, needs-decision, or done) and the next step.')" \
        "$id" "$(shq '<what happened>')"
      n=$((n + 1))
    fi
    while IFS=$'\t' read -r key verb summary; do
      [ "$verb" = needs-decision ] || continue
      covered=0
      "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1 && covered=1
      if [ "$covered" -eq 0 ] && [ "$key" != default ]; then
        "$SCRIPT_DIR/fm-captain-hold.sh" open "$key" >/dev/null 2>&1 && covered=1
        [ "$covered" -eq 1 ] || { "$SCRIPT_DIR/fm-captain-hold.sh" open "$id-decision-$key" >/dev/null 2>&1 && covered=1; }
      fi
      if [ "$covered" -eq 0 ]; then
        printf 'GAP decision %s [key=%s]: open decision with no captain hold; fix: bin/fm-captain-hold.sh hold %s --reason %s\n' \
          "$id" "$key" "$id" "$(shq "$summary")"
        n=$((n + 1))
      fi
    done <<EOF
$(printf '%s' "$row" | jq -r '.hints.open_decisions[]? | [.key, .verb, .summary] | @tsv')
EOF
  done <<EOF
$(printf '%s' "$SNAPSHOT" | jq -c '.tasks[]')
EOF
  GAP_COUNT=$n
}

# --- write helpers -------------------------------------------------------------

# Bounded excerpt of a HANDOFF.md: the lines under its first heading that names
# a next step, else its first prose lines.
handoff_excerpt() {  # <path>
  awk '
    /^#/ { if (grab) exit; if (tolower($0) ~ /next/) { grab = 1; seen = 1 } ; next }
    NF == 0 { next }
    grab && n < 3 { out = out (out == "" ? "" : " ") $0; n++ }
    !seen && m < 3 { first = first (first == "" ? "" : " ") $0; m++ }
    END { s = (out != "") ? out : first; print substr(s, 1, 400) }
  ' "$1" 2>/dev/null
}

declare -a NEXT_IDS=() NEXT_TEXTS=()
next_for() {  # <id>
  local i
  [ "${#NEXT_IDS[@]}" -gt 0 ] || return 1
  for i in "${!NEXT_IDS[@]}"; do
    [ "${NEXT_IDS[$i]}" = "$1" ] && { printf '%s' "${NEXT_TEXTS[$i]}"; return 0; }
  done
  return 1
}

worker_json() {  # <snapshot-task-row> <stamp-dir>
  local row=$1 notes_dir=$2 id kind meta worktree model effort head='' dirty=null unpushed=null remote=null
  local intent=resume next='' next_source=none handoff note_file remote_host
  id=$(printf '%s' "$row" | jq -r '.id')
  kind=$(printf '%s' "$row" | jq -r '.kind // ""')
  meta="$STATE/$id.meta"
  model=$(fm_meta_get "$meta" model)
  effort=$(fm_meta_get "$meta" effort)
  remote_host=$(fm_meta_get "$meta" remote_host)
  worktree=$(printf '%s' "$row" | jq -r '.paths.worktree.path // ""')
  if [ -z "$remote_host" ] && [ -n "$worktree" ] && [ -d "$worktree" ]; then
    head=$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$head" ]; then
      if [ -n "$(git -C "$worktree" status --porcelain 2>/dev/null | head -1)" ]; then dirty=true; else dirty=false; fi
      if [ -n "$(git -C "$worktree" remote 2>/dev/null | head -1)" ]; then
        remote=true
        unpushed=$(git -C "$worktree" rev-list --count HEAD --not --remotes 2>/dev/null || printf 'null')
      else
        remote=false
      fi
    fi
  fi
  is_hold "$id" && intent=hold
  if next=$(next_for "$id"); then
    next_source=explicit
  else
    next=
    for handoff in "$DATA/$id/HANDOFF.md" "${worktree:+$worktree/HANDOFF.md}"; do
      [ -n "$handoff" ] && [ -f "$handoff" ] || continue
      next=$(handoff_excerpt "$handoff")
      next_source=$handoff
      break
    done
  fi
  note_file="$notes_dir/$id.note"
  if [ "$kind" != secondmate ]; then
    {
      printf 'Supervisor handover: the supervisor session that dispatched this task handed the fleet to a new session.\n'
      printf 'Recorded state at handover: %s\n' "$(printf '%s' "$row" | jq -r '.current_state.raw // "unknown"')"
      [ -z "$head" ] || printf 'Local copy: %s on %s at %s.\n' "$worktree" "$(printf '%s' "$row" | jq -r '.branch // "?"')" "$head"
      if [ -n "$next" ]; then printf 'Next step: %s\n' "$next"; else printf 'Next step: continue the task as briefed.\n'; fi
      printf 'Report through your status file as before.\n'
    } > "$note_file" || die "cannot write $note_file"
  else
    note_file=
  fi
  printf '%s' "$row" | jq -c \
    --arg model "$model" --arg effort "$effort" --arg head "$head" \
    --argjson dirty "$dirty" --argjson unpushed "${unpushed:-null}" --argjson remote "$remote" \
    --arg intent "$intent" --arg next "$next" --arg next_source "$next_source" \
    --arg note_file "$note_file" '
    {
      id, kind, harness,
      model:($model | if . == "" then null else . end),
      effort:($effort | if . == "" then null else . end),
      backend, project,
      home:(.paths.home.path // null),
      local_copy:(.paths.worktree.path // null),
      branch, head:($head | if . == "" then null else . end),
      dirty:$dirty, has_remote:$remote, unpushed_commits:$unpushed,
      pr:(.pr.url // null),
      current_state:(.current_state.raw // null),
      state:(.current_state.state // "unknown"),
      spawn_gen,
      open_decisions:(.hints.open_decisions // []),
      intent:$intent,
      next:($next | if . == "" then null else . end),
      next_source:$next_source,
      note_file:($note_file | if . == "" then null else . end),
      mark:null
    }'
}

file_text_json() {  # <path-or-empty> <label>
  if [ -z "$1" ]; then printf 'null'; return 0; fi
  [ -f "$1" ] || die "$2 $1 does not exist"
  jq -Rs . < "$1"
}

# --- rendering -----------------------------------------------------------------

# Per-worker progress since the record was written, from live metadata only.
progress_json() {
  local id gen out='{}'
  while IFS=$'\t' read -r id gen; do
    [ -n "$id" ] || continue
    if [ ! -f "$STATE/$id.meta" ]; then
      out=$(printf '%s' "$out" | jq -c --arg id "$id" '. + {($id): "cleaned-up"}')
    elif [ "$(fm_meta_get "$STATE/$id.meta" spawn_gen)" != "$gen" ]; then
      out=$(printf '%s' "$out" | jq -c --arg id "$id" '. + {($id): "relaunched"}')
    fi
  done <<EOF
$(jq -r '.workers[] | [.id, (.spawn_gen // "")] | @tsv' "$RECORD")
EOF
  printf '%s' "$out"
}

render_status() {  # <digest: 0|1>
  local digest=$1 progress
  progress=$(progress_json)
  jq -r --argjson progress "$progress" --argjson digest "$digest" \
    --argjson rows "$DIGEST_ROWS" --arg parked "$PARKED_LINE" '
    def cut($n): if . == null then "" elif length > $n then .[:$n] + "..." else . end;
    def flat: sub("^\\s+"; "") | sub("\\s+$"; "") | gsub("\n+"; " / ");
    def prog($w): ($progress[$w.id] // (if $w.mark then "marked " + $w.mark else "" end));
    (.workers | length) as $total
    | "handover pending: written \(.written_at) by a \(.from_harness) session"
      + (if .released_at then ", released \(.released_at)" else ", NOT yet released (the outgoing session still holds the lock)" end),
      ("goal: " + ((.goal // "(none recorded)") | flat | if $digest == 1 then cut(600) else . end)),
      (if .notes and $digest == 0 then "notes: " + (.notes | flat) else empty end),
      "workers (intent  task  harness/model  state at handover  local branch  progress):",
      (.workers[: (if $digest == 1 then $rows else $total end)][] as $w
        | "  \($w.intent)  \($w.id)  \($w.harness // "?")/\($w.model // "default")  \(($w.current_state // "unknown") | cut(90))  \($w.branch // "-")@\(($w.head // "-")[:12])"
          + (if $w.dirty == true then " dirty" else "" end)
          + (if ($w.unpushed_commits // 0) > 0 then " unpushed=\($w.unpushed_commits)" else "" end)
          + (if $w.pr then " pr=\($w.pr)" else "" end)
          + (if $w.kind == "secondmate" then " home=\($w.home // "?")" else "" end)
          + (if prog($w) != "" then "  [" + prog($w) + "]" else "" end)),
      (if $digest == 1 and $total > $rows then "  (\($total - $rows) more worker(s): bin/fm-handover.sh status)" else empty end),
      (.secondmate_homes[]? | select((.workers | length) > 0)
        | "  under second mate \(.id) (home \(.home // "?")): " + (.workers | join(", ")) + " - that home relaunches them"),
      (if (.decisions | length) > 0 then "open decisions held for the captain: " + (.decisions | map("\(.task) [key=\(.key)]") | join(", ")) else empty end),
      "summary: \(.summary_path)",
      $parked,
      "load the session-handover skill; bin/fm-handover.sh accept consumes this record after the resume rows are relaunched"
  ' "$RECORD"
}

# --- subcommands ---------------------------------------------------------------

cmd_prepare() {
  [ "$#" -eq 0 ] || die "prepare: unknown argument: $1"
  read_snapshot
  run_checks
  if [ "$GAP_COUNT" -gt 0 ]; then
    printf 'prepare: %s gap(s); fix each with the named command and re-run bin/fm-handover.sh prepare\n' "$GAP_COUNT"
    exit 1
  fi
  printf 'prepare: ready - %s worker(s) have a backlog item and a readable state, and every open decision is held for the captain\n' \
    "$(printf '%s' "$SNAPSHOT" | jq '.tasks | length')"
}

cmd_write() {
  local goal_file='' notes_file='' replace=0 arg stamp now notes_dir summary gaps workers='' row
  local goal_json notes_json backlog_json homes_json from_harness tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --goal-file) [ "$#" -ge 2 ] || die "--goal-file needs a path"; goal_file=$2; shift 2 ;;
      --notes-file) [ "$#" -ge 2 ] || die "--notes-file needs a path"; notes_file=$2; shift 2 ;;
      --next)
        [ "$#" -ge 2 ] || die "--next needs <task>=<text>"
        arg=$2
        case "$arg" in *=*) ;; *) die "--next needs <task>=<text>, got: $arg" ;; esac
        NEXT_IDS+=("${arg%%=*}"); NEXT_TEXTS+=("${arg#*=}")
        shift 2 ;;
      --hold) [ "$#" -ge 2 ] || die "--hold needs a task"; HOLD_IDS="$HOLD_IDS$2 "; shift 2 ;;
      --replace) replace=1; shift ;;
      *) die "write: unknown argument: $1" ;;
    esac
  done
  if [ -f "$RECORD" ] && [ "$replace" -ne 1 ]; then
    die "a handover is already pending ($RECORD); inspect it with bin/fm-handover.sh status, or pass --replace to rewrite it"
  fi
  goal_json=$(file_text_json "$goal_file" "--goal-file") || exit 1
  notes_json=$(file_text_json "$notes_file" "--notes-file") || exit 1

  read_snapshot
  for arg in ${NEXT_IDS[@]+"${NEXT_IDS[@]}"} $(printf '%s' "$HOLD_IDS"); do
    printf '%s' "$SNAPSHOT" | jq -e --arg id "$arg" 'any(.tasks[]; .id == $id)' >/dev/null \
      || die "no live worker named $arg in this home (state/$arg.meta)"
  done
  gaps=$(run_checks)
  if [ -n "$gaps" ]; then
    printf '%s\n' "$gaps"
    die "refusing to write a handover over open gaps; fix them (bin/fm-handover.sh prepare) and re-run"
  fi

  stamp=$(utc_stamp)
  now=$(utc_now)
  notes_dir="$SUMMARY_DIR/$stamp"
  mkdir -p "$notes_dir" || die "cannot create $notes_dir"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    workers="$workers$(worker_json "$row" "$notes_dir")
"
  done <<EOF
$(printf '%s' "$SNAPSHOT" | jq -c '.tasks[]')
EOF
  [ -n "$workers" ] || workers=''
  backlog_json=$(printf '%s' "$SNAPSHOT" | jq -c '[.backlog.records[]?
      | select(.state == "in_flight" or ((.hold_kind // null) != null and .state != "done"))
      | {id, state, title, kind, hold_kind, hold_reason, hold_until}]')
  homes_json=$(printf '%s' "$SNAPSHOT" | jq -c '[.secondmate_current.records[]?
      | {id, home, workers:[.active_children[]?.id], decisions:[.decisions_open[]?.id]}]')
  from_harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
  summary="$SUMMARY_DIR/$stamp.md"

  tmp=$(mktemp "$STATE/.handover.json.XXXXXX") || die "cannot write $RECORD"
  if ! printf '%s' "$workers" | jq -s \
      --arg schema "$SCHEMA" --arg written_at "$now" --arg stamp "$stamp" \
      --arg fm_home "$FM_HOME" --arg from_harness "$from_harness" --arg summary "$summary" \
      --argjson goal "$goal_json" --argjson notes "$notes_json" \
      --argjson backlog "$backlog_json" --argjson homes "$homes_json" '
      {
        schema:$schema, written_at:$written_at, stamp:$stamp, fm_home:$fm_home,
        from_harness:$from_harness, released_at:null, summary_path:$summary,
        goal:$goal, notes:$notes,
        workers:.,
        decisions:[.[] as $w | $w.open_decisions[] | {task:$w.id, key, verb, summary}],
        backlog:$backlog,
        secondmate_homes:$homes
      }' > "$tmp"; then
    rm -f "$tmp"
    die "cannot assemble $RECORD"
  fi
  mv -f "$tmp" "$RECORD" || { rm -f "$tmp"; die "cannot publish $RECORD"; }

  jq -r '
    "# Supervisor handover \(.stamp)",
    "",
    "Written \(.written_at) by a \(.from_harness) session for home \(.fm_home).",
    "The authoritative record is state/handover.json; this file is its readable copy.",
    "",
    "## Goal",
    "",
    ((.goal // "(none recorded)") | sub("\\s+$"; "")),
    "",
    "## Notes",
    "",
    ((.notes // "(none recorded)") | sub("\\s+$"; "")),
    "",
    "## Workers",
    "",
    "| intent | task | kind | harness / model | state at handover | local copy | branch @ head | flags | PR | next step |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.workers[] | "| \(.intent) | \(.id) | \(.kind) | \(.harness // "?") / \(.model // "default") | \((.current_state // "unknown") | gsub("\\|"; "/")) | \(.local_copy // "-") | \(.branch // "-") @ \((.head // "-")[:12]) | "
      + ([ (if .dirty == true then "dirty" else empty end), (if (.unpushed_commits // 0) > 0 then "unpushed=\(.unpushed_commits)" else empty end), (if .has_remote == false then "no-remote" else empty end) ] | join(" "))
      + " | \(.pr // "-") | \((.next // "-") | gsub("\\|"; "/")) |"),
    "",
    "## Second mate homes",
    "",
    (if (.secondmate_homes | length) == 0 then "(none)" else (.secondmate_homes[] | "- \(.id): home \(.home // "?"); workers: \(if (.workers | length) == 0 then "none" else (.workers | join(", ")) end)") end),
    "",
    "## Open decisions",
    "",
    (if (.decisions | length) == 0 then "(none)" else (.decisions[] | "- \(.task) [key=\(.key)] \(.verb): \(.summary)") end),
    "",
    "## Backlog in flight and held",
    "",
    (if (.backlog | length) == 0 then "(none)" else (.backlog[] | "- \(.id) (\(.state)\(if .hold_kind then ", held: \(.hold_kind)" else "" end)): \(.title // "")") end),
    "",
    "## Incoming session",
    "",
    "Run bin/fm-handover.sh resume-plan, relaunch every resume row, then bin/fm-handover.sh accept."
  ' "$RECORD" > "$summary" || die "cannot write $summary"

  printf 'handover written: %s (%s worker(s)); summary %s\n' "$RECORD" "$(jq '.workers | length' "$RECORD")" "$summary"
  printf 'next: bin/fm-handover.sh release, then end this session\n'
}

cmd_release() {
  local out
  require_record
  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-contract" ]; then
    die "away or quiet supervision is active ($STATE/.afk); end it through the away-quiet-supervision procedure before releasing, or its daemon re-arms the watcher"
  fi
  out=$("$SCRIPT_DIR/fm-lock.sh" release 2>&1) || die "the session lock was not released: $out"
  printf '%s\n' "$out"
  out=$("$SCRIPT_DIR/fm-watch-arm.sh" --stop 2>&1) || die "the lock is released but this home's watcher did not stop: $out"
  printf '%s\n' "$out"
  # shellcheck disable=SC2016 # jq, not the shell, expands these names.
  record_update --arg at "$(utc_now)" '.released_at = $at'
  printf 'released: the next session to start in %s takes the lock and sees HANDOVER PENDING in its digest\n' "$FM_HOME"
}

cmd_status() {
  local digest=0
  [ "${1:-}" = --digest ] && digest=1
  if [ ! -f "$RECORD" ]; then
    printf 'handover: none pending\n'
    return 0
  fi
  if ! jq -e --arg s "$SCHEMA" '.schema == $s' "$RECORD" >/dev/null 2>&1; then
    printf 'handover: %s exists but is not a readable %s record; inspect it by hand\n' "$RECORD" "$SCHEMA"
    return 0
  fi
  render_status "$digest"
}

cmd_resume_plan() {
  local here progress
  require_record
  here=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
  progress=$(progress_json)
  printf 'resume plan (this session runs harness %s; run each command, one at a time):\n' "$here"
  jq -r --arg here "$here" --argjson progress "$progress" '
    .workers[] as $w
    | ($progress[$w.id] // null) as $p
    | if $p != null then "\($p)  \($w.id): nothing to do"
      elif $w.mark == "running" then "running  \($w.id): marked already running; nothing to do"
      elif $w.intent == "hold" then "hold  \($w.id): leave it parked; it stays recorded for a later decision"
      else
        "resume  \($w.id): bin/fm-control.sh \($w.id) relaunch"
        + (if ($w.harness // "") != $here then " --harness <harness> --model <model>" else "" end)
        + (if $w.note_file then " --note-file \($w.note_file)" else "" end)
        + (if ($w.harness // "") != $here then "\n    recorded on \($w.harness // "unknown")/\($w.model // "default"); this session runs \($here): choose the replacement per the dispatch rules, or drop the placeholders to keep the recorded adapter" else "" end)
      end,
    (.secondmate_homes[]? | select((.workers | length) > 0)
      | "home  \(.id): \(.workers | join(", ")) run under \(.home // "?"); that second mate relaunches them after its own relaunch")
  ' "$RECORD"
}

cmd_mark() {
  local id=${1:-} what=${2:-}
  require_record
  [ -n "$id" ] || die "usage: fm-handover.sh mark <task> hold|running"
  case "$what" in
    hold|running) ;;
    *) die "usage: fm-handover.sh mark <task> hold|running" ;;
  esac
  jq -e --arg id "$id" 'any(.workers[]; .id == $id)' "$RECORD" >/dev/null \
    || die "the pending handover records no worker named $id"
  if [ "$what" = hold ]; then
    # shellcheck disable=SC2016 # jq, not the shell, expands these names.
    record_update --arg id "$id" --arg at "$(utc_now)" \
      '.workers |= map(if .id == $id then .intent = "hold" | .mark = "hold" | .marked_at = $at else . end)'
  else
    # shellcheck disable=SC2016 # jq, not the shell, expands these names.
    record_update --arg id "$id" --arg at "$(utc_now)" \
      '.workers |= map(if .id == $id then .mark = "running" | .marked_at = $at else . end)'
  fi
  printf 'marked %s %s\n' "$id" "$what"
}

cmd_accept() {
  local progress pending stamp dest
  require_record
  progress=$(progress_json)
  pending=$(jq -r --argjson progress "$progress" '
    .workers[] | select(.intent == "resume" and .mark == null and ($progress[.id] // null) == null) | .id
  ' "$RECORD")
  if [ -n "$pending" ]; then
    printf 'fm-handover: refusing to accept: these resume workers are neither relaunched nor marked:\n' >&2
    printf '%s\n' "$pending" | sed 's/^/  /' >&2
    printf 'relaunch them (bin/fm-handover.sh resume-plan), or record a different outcome with bin/fm-handover.sh mark <task> hold|running\n' >&2
    exit 1
  fi
  stamp=$(utc_stamp)
  dest="$STATE/handover.accepted.$stamp.json"
  # shellcheck disable=SC2016 # jq, not the shell, expands these names.
  record_update --arg at "$(utc_now)" --argjson progress "$progress" \
    '.accepted_at = $at | .workers |= map(. + {outcome: ($progress[.id] // .mark // .intent)})'
  mv -f "$RECORD" "$dest" || die "cannot move $RECORD to $dest"
  printf 'handover accepted: %s\n' "$dest"
}

case "${1:-}" in
  prepare) shift; cmd_prepare "$@" ;;
  write) shift; cmd_write "$@" ;;
  release) shift; cmd_release "$@" ;;
  status) shift; cmd_status "$@" ;;
  resume-plan) shift; cmd_resume_plan "$@" ;;
  mark) shift; cmd_mark "$@" ;;
  accept) shift; cmd_accept "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
