#!/usr/bin/env bash
# fm-shared-prefs.sh - read, acknowledge, and report the exact generation of the
# shared captain preferences (data/captain-shared.md) a secondmate home holds.
#
# Usage:
#   fm-shared-prefs.sh show                    (in a secondmate home)
#   fm-shared-prefs.sh ack <generation> <sha256> (in a secondmate home)
#   fm-shared-prefs.sh status                  (in the primary home; read-only)
#
# show   prints the complete current data/captain-shared.md between delimiters
#        (or ABSENT), then its applied generation and, only when the copy on disk
#        still matches that generation, the exact ack command for it.
# ack    records this agent's acknowledgement of exactly that generation. It
#        refuses, changing nothing, when either value is not the CURRENT applied
#        generation (a stale, replayed, future, or mistyped acknowledgement), when
#        the copy on disk no longer hashes to it, or outside a secondmate home.
#        Re-acknowledging the current generation is an idempotent no-op.
# status lists every live secondmate direct report of this home with the
#        primary content, applied, delivered, and acknowledged generations, and
#        one state: acknowledged, acknowledgement-pending, delivery-pending,
#        generation-not-recorded, not-applied, none, or, for a remote home,
#        remote-not-observable. It writes nothing and sends nothing.
#
# bin/fm-shared-prefs-lib.sh owns the records, what an acknowledgement attests
# and does not, and why a pending acknowledgement gates no other work.
# bin/fm-config-push.sh and the bootstrap secondmate sweep apply and deliver.
#
# Exit: 0 success; 1 refused or failed; 2 usage.
set -u

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-shared-prefs-lib.sh
. "$SCRIPT_DIR/fm-shared-prefs-lib.sh"

die() { printf 'fm-shared-prefs: %s\n' "$*" >&2; exit 1; }

require_secondmate_home() {
  [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
    || die "$FM_HOME is not a secondmate home (no .fm-secondmate-home marker); shared-preference acknowledgement belongs to a secondmate"
}

cmd_show() {
  local lock tmp rc=0
  require_secondmate_home
  mkdir -p "$FM_HOME/state" 2>/dev/null || die "cannot create state directory"
  lock=$(fm_config_inherit_lock_path "$FM_HOME") || die "cannot resolve the inheritance lock"
  # Under the inheritance lock the printed bytes, their hash, and the applied
  # record are one consistent snapshot even if the primary is converging.
  fm_lock_acquire_wait "$lock" || die "cannot acquire the inheritance lock"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-shared-prefs-show.XXXXXX" 2>/dev/null) || { fm_lock_release "$lock"; die "cannot stage output"; }
  cmd_show_locked > "$tmp" || rc=$?
  fm_lock_release "$lock" || true
  cat "$tmp"
  rm -f "$tmp"
  return "$rc"
}

cmd_show_locked() {
  local record current generation sha file="$FM_HOME/data/captain-shared.md"
  record="$FM_HOME/$FM_SHARED_PREFS_GENERATION_REL"
  current=$(fm_shared_prefs_content_id "$FM_HOME/data") || { printf 'fm-shared-prefs: data/captain-shared.md is not an ordinary file\n' >&2; return 1; }
  printf '%s\n' '-----BEGIN data/captain-shared.md-----'
  if [ "$current" = absent ]; then
    printf 'ABSENT\n'
  else
    cat "$file" || { printf 'fm-shared-prefs: cannot read data/captain-shared.md\n' >&2; return 1; }
    [ -z "$(tail -c 1 "$file")" ] || printf '\n'
  fi
  printf '%s\n' '-----END data/captain-shared.md-----'
  generation=$(fm_shared_prefs_record_get "$record" generation 2>/dev/null) || generation=
  sha=$(fm_shared_prefs_record_get "$record" sha256 2>/dev/null) || sha=
  if [ -z "$generation" ]; then
    printf 'No applied generation is recorded for this home, so there is nothing to acknowledge.\n'
    return 0
  fi
  if [ "$sha" != "$current" ]; then
    printf 'Applied generation %s does not match the copy on disk; do not acknowledge. Report the mismatch to the main firstmate.\n' "$generation"
    return 1
  fi
  if [ "$current" = absent ]; then
    printf 'Generation %s: the shared preferences were removed; stop applying their earlier contents.\n' "$generation"
  else
    printf 'Generation %s: the complete current shared preferences are printed above.\n' "$generation"
  fi
  printf 'After reading them, acknowledge exactly this generation:\n  %s ack %s %s\n' "$SCRIPT_DIR/fm-shared-prefs.sh" "$generation" "$sha"
}

cmd_ack() {
  local want_generation=$1 want_sha=$2 lock record generation sha current acked acked_sha rc=0
  require_secondmate_home
  case "$want_generation" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
  case "$want_sha" in absent) ;; *[!a-f0-9]*|'') die "sha256 must be 64 lowercase hex characters or absent" ;; esac
  [ "$want_sha" = absent ] || [ "${#want_sha}" -eq 64 ] || die "sha256 must be 64 lowercase hex characters or absent"
  mkdir -p "$FM_HOME/state" 2>/dev/null || die "cannot create state directory"
  lock=$(fm_config_inherit_lock_path "$FM_HOME") || die "cannot resolve the inheritance lock"
  fm_lock_acquire_wait "$lock" || die "cannot acquire the inheritance lock"
  record="$FM_HOME/$FM_SHARED_PREFS_GENERATION_REL"
  generation=$(fm_shared_prefs_record_get "$record" generation 2>/dev/null) || generation=
  sha=$(fm_shared_prefs_record_get "$record" sha256 2>/dev/null) || sha=
  current=$(fm_shared_prefs_content_id "$FM_HOME/data" 2>/dev/null) || current=unreadable
  acked=$(fm_shared_prefs_record_get "$FM_HOME/$FM_SHARED_PREFS_ACK_REL" generation 2>/dev/null) || acked=
  acked_sha=$(fm_shared_prefs_record_get "$FM_HOME/$FM_SHARED_PREFS_ACK_REL" sha256 2>/dev/null) || acked_sha=
  if [ -z "$generation" ]; then
    printf 'fm-shared-prefs: refused: no applied generation is recorded for this home\n' >&2; rc=1
  elif [ "$want_generation" != "$generation" ]; then
    if [ "$want_generation" -lt "$generation" ] 2>/dev/null; then
      printf 'fm-shared-prefs: refused: generation %s is stale; the current applied generation is %s - run show and read it\n' "$want_generation" "$generation" >&2
    else
      printf 'fm-shared-prefs: refused: generation %s is not applied here; the current applied generation is %s\n' "$want_generation" "$generation" >&2
    fi
    rc=1
  elif [ "$want_sha" != "$sha" ]; then
    printf 'fm-shared-prefs: refused: sha256 does not name generation %s - run show and use the command it prints\n' "$generation" >&2; rc=1
  elif [ "$current" != "$sha" ]; then
    printf 'fm-shared-prefs: refused: the copy on disk no longer matches generation %s; report the mismatch to the main firstmate\n' "$generation" >&2; rc=1
  elif [ "$acked" = "$generation" ] && [ "$acked_sha" = "$sha" ]; then
    printf 'acknowledged: generation %s (already recorded)\n' "$generation"
  elif fm_shared_prefs_record_write "$FM_HOME/$FM_SHARED_PREFS_ACK_REL" "$generation" "$sha" acknowledged_at; then
    printf 'acknowledged: generation %s\n' "$generation"
  else
    printf 'fm-shared-prefs: could not write the acknowledgement record\n' >&2; rc=1
  fi
  fm_lock_release "$lock" || true
  return "$rc"
}

cmd_status() {
  local records id home _window meta remote_host
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-ff-lib.sh
  . "$SCRIPT_DIR/fm-ff-lib.sh"
  records=$(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
  if [ -z "$records" ]; then
    printf 'shared-prefs: no live secondmate homes found\n'
    return 0
  fi
  while IFS='|' read -r id home _window meta; do
    [ -n "$id" ] || continue
    remote_host=$(fm_meta_get "$meta" remote_host 2>/dev/null || true)
    if [ -n "$remote_host" ]; then
      printf '%s: remote home on %s; state=remote-not-observable (its acknowledgement record lives on that host)\n' "$id" "$remote_host"
      continue
    fi
    if [ -z "$home" ] || ! validate_secondmate_home "$id" "$home"; then
      printf '%s: state=unknown (no validated home: %s)\n' "$id" "${VALIDATION_ERROR:-no home= recorded}"
      continue
    fi
    fm_shared_prefs_status "$id" "$VALIDATED_HOME" "$DATA"
  done <<EOF
$records
EOF
}

case "${1:-}" in
  show) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_show ;;
  ack) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; cmd_ack "$2" "$3" ;;
  status) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_status ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
