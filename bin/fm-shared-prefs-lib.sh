# shellcheck shell=bash
# fm-shared-prefs-lib.sh - exact-generation acknowledgement of the shared
# captain-preference file (data/captain-shared.md) in a live LOCAL secondmate
# home.
#
# Copying the file into a home (bin/fm-config-inherit-lib.sh owns that) proves
# only that the bytes are on disk. A running agent loaded its preferences when
# its session started, so a later copy changes nothing it has read. This file
# owns the three separate facts the primary records per home, each in that
# home's gitignored state/ directory, so none of them can stand in for another:
#
#   applied       state/.fm-shared-prefs.generation
#                 generation=<n> sha256=<64-hex|absent> applied_at=<UTC>
#                 Written by the primary when the home's copy matches the
#                 primary bytes (or both are absent) and that content differs
#                 from the last recorded generation. <n> only ever increases,
#                 so returning to earlier bytes is a NEW generation and an
#                 acknowledgement of the earlier one cannot settle it.
#   delivered     state/.fm-shared-prefs.delivered
#                 generation=<n> sha256=... delivered_at=<UTC>
#                 Written by the primary only after fm-send durably recorded the
#                 re-read request in that mate's steering inbox for exactly that
#                 generation. A failed send leaves it behind the applied record,
#                 which is the retry obligation: the next convergence resends.
#   acknowledged  state/.fm-shared-prefs.ack
#                 generation=<n> sha256=... acknowledged_at=<UTC>
#                 Written only by the mate's own agent through
#                 `fm-shared-prefs.sh ack <n> <sha256>`, which refuses unless
#                 both values name the CURRENT applied generation and the copy
#                 on disk still hashes to it. The sha256 is printed only by
#                 `fm-shared-prefs.sh show`, in the same output as the complete
#                 file, so the ordinary way to obtain it is to have read it.
#
# What an acknowledgement attests: the agent running in that home stated, after
# the complete bytes of that exact generation were printed into its context,
# that it re-read them and will apply them at future intake. What it does NOT
# attest: comprehension, future compliance, a fresh conversation or restart,
# removal of anything the agent loaded earlier, or anything about another home.
# Moving the inbox message into handled/ is message handling, not this
# attestation, and a file copy or a successful send is never reported as
# acknowledged.
#
# Acknowledgement is freshness and delivery state, not an authorization gate:
# nothing in Firstmate blocks dispatch, steering, or unrelated work on a pending
# acknowledgement, and the request itself tells the mate it resumes, unpauses,
# and reprioritizes nothing.
#
# Remote homes: their copy arrives through bin/fm-remote-inherit.sh and their
# re-read obligation through bin/fm-secondmate-nudge-lib.sh. This file writes no
# generation record there, and the primary cannot read a remote home's state, so
# a remote acknowledgement is reported as not observable from the primary rather
# than as pending or settled.
#
# Callers must already hold the per-home inheritance lock
# (fm_config_inherit_lock_path) around fm_shared_prefs_converge, exactly as they
# do around propagation, so a newer generation cannot be overtaken by an older
# delivery; `ack` takes the same lock.
#
# Source after bin/fm-config-inherit-lib.sh (fm_inherit_sha256, FM_SHARED_CAPTAIN_REL).

FM_SHARED_PREFS_GENERATION_REL="state/.fm-shared-prefs.generation"
FM_SHARED_PREFS_DELIVERED_REL="state/.fm-shared-prefs.delivered"
FM_SHARED_PREFS_ACK_REL="state/.fm-shared-prefs.ack"

fm_shared_prefs_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# fm_shared_prefs_content_id <data-dir>: the content identity of that dir's
# shared-preference file - its SHA-256, or "absent" when there is no file.
# Returns 1 for anything that is neither an ordinary file nor absent.
fm_shared_prefs_content_id() {
  local file="$1/captain-shared.md"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'absent\n'
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  fm_inherit_sha256 "$file"
}

# fm_shared_prefs_record_get <record-file> <key>: one field, or return 1 when
# the record is missing, unsafe, or lacks a well-formed value for <key>.
fm_shared_prefs_record_get() {
  local record=$1 key=$2 value
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  value=$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$record" 2>/dev/null) || return 1
  case "$key" in
    generation)
      case "$value" in ''|*[!0-9]*) return 1 ;; esac
      [ "${#value}" -le 18 ] || return 1
      ;;
    sha256)
      case "$value" in
        absent) ;;
        *) case "$value" in *[!a-f0-9]*) return 1 ;; esac; [ "${#value}" -eq 64 ] || return 1 ;;
      esac
      ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# fm_shared_prefs_record_write <record-file> <generation> <sha256> <time-key>:
# atomic, mode 0600, never through a symlink.
fm_shared_prefs_record_write() {
  local record=$1 generation=$2 sha=$3 time_key=$4 parent tmp
  parent=${record%/*}
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  [ ! -L "$record" ] || return 1
  tmp=$(umask 077; mktemp "$parent/.fm-shared-prefs.XXXXXX" 2>/dev/null) || return 1
  if ! printf 'generation=%s\nsha256=%s\n%s=%s\n' "$generation" "$sha" "$time_key" "$(fm_shared_prefs_now)" > "$tmp" \
    || ! chmod 0600 "$tmp" 2>/dev/null \
    || ! mv -f -- "$tmp" "$record" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# fm_shared_prefs_request_text <home> <generation>: the one-line re-read request.
fm_shared_prefs_request_text() {
  printf 'SHARED_PREFS_REREAD: the primary shared captain preferences for this home are now generation %s. Run %s/bin/fm-shared-prefs.sh show to print the complete current data/captain-shared.md, apply it at every future intake, then run the exact ack command it prints. This is a knowledge update only: it resumes, unpauses, reprioritizes, and authorizes nothing, and every paused, held, or in-flight item keeps its current state.\n' "$2" "$1"
}

# fm_shared_prefs_converge <id> <dest-home> <primary-data-dir>
# Primary side, under the per-home inheritance lock, after propagation. Records
# a new applied generation when the home's verified copy content changed, then
# delivers the re-read request for the applied generation when it has not been
# delivered yet. Prints one SHARED_PREFS: line per notable outcome. Returns 0
# when the home is current (delivered, or nothing to deliver), 1 when the copy
# is not applied or delivery failed (the obligation stays owed), and 2 when
# delivery is deferred because the home's tracked files do not yet carry the
# acknowledgement command.
fm_shared_prefs_converge() {
  local id=$1 dest_home=$2 src_data=$3 primary_id dest_id record delivered generation
  local recorded_sha delivered_generation delivered_sha send_bin out
  [ -n "$id" ] && [ -n "$dest_home" ] && [ -n "$src_data" ] || return 1
  primary_id=$(fm_shared_prefs_content_id "$src_data") || {
    printf 'SHARED_PREFS: secondmate %s: primary shared preferences are unreadable; nothing applied or delivered\n' "$id"
    return 1
  }
  dest_id=$(fm_shared_prefs_content_id "$dest_home/data") || dest_id=unreadable
  if [ "$dest_id" != "$primary_id" ]; then
    printf 'SHARED_PREFS: secondmate %s: home copy does not match the primary; not applied, nothing delivered\n' "$id"
    return 1
  fi
  record="$dest_home/$FM_SHARED_PREFS_GENERATION_REL"
  delivered="$dest_home/$FM_SHARED_PREFS_DELIVERED_REL"
  mkdir -p "$dest_home/state" 2>/dev/null || return 1
  generation=$(fm_shared_prefs_record_get "$record" generation 2>/dev/null) || generation=
  recorded_sha=$(fm_shared_prefs_record_get "$record" sha256 2>/dev/null) || recorded_sha=
  if [ -z "$generation" ] && [ "$primary_id" = absent ]; then
    # No shared preferences have ever been recorded here: nothing to re-read.
    return 0
  fi
  if [ -z "$generation" ] || [ "$recorded_sha" != "$primary_id" ]; then
    generation=$(( ${generation:-0} + 1 ))
    if ! fm_shared_prefs_record_write "$record" "$generation" "$primary_id" applied_at; then
      printf 'SHARED_PREFS: secondmate %s: could not record applied generation %s; nothing delivered\n' "$id" "$generation"
      return 1
    fi
  fi
  delivered_generation=$(fm_shared_prefs_record_get "$delivered" generation 2>/dev/null) || delivered_generation=
  delivered_sha=$(fm_shared_prefs_record_get "$delivered" sha256 2>/dev/null) || delivered_sha=
  if [ "$delivered_generation" = "$generation" ] && [ "$delivered_sha" = "$primary_id" ]; then
    return 0
  fi
  # An agent that already acknowledged this exact generation needs no request.
  if [ "$(fm_shared_prefs_record_get "$dest_home/$FM_SHARED_PREFS_ACK_REL" generation 2>/dev/null)" = "$generation" ] \
    && [ "$(fm_shared_prefs_record_get "$dest_home/$FM_SHARED_PREFS_ACK_REL" sha256 2>/dev/null)" = "$primary_id" ]; then
    return 0
  fi
  if [ ! -x "$dest_home/bin/fm-shared-prefs.sh" ]; then
    printf 'SHARED_PREFS: secondmate %s: generation %s applied; re-read request deferred until the home carries bin/fm-shared-prefs.sh\n' "$id" "$generation"
    return 2
  fi
  send_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-send.sh"
  if out=$(FM_HOME="${FM_HOME:-}" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" \
    FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-}" FM_SEND_SETTLE="${FM_SEND_SETTLE:-0}" \
    "$send_bin" "fm-$id" "$(fm_shared_prefs_request_text "$dest_home" "$generation")" 2>&1); then
    if fm_shared_prefs_record_write "$delivered" "$generation" "$primary_id" delivered_at; then
      printf 'SHARED_PREFS: secondmate %s: generation %s re-read request delivered; acknowledgement pending\n' "$id" "$generation"
      return 0
    fi
    printf 'SHARED_PREFS: secondmate %s: generation %s request sent but its delivery record failed; a duplicate request may follow\n' "$id" "$generation"
    return 1
  fi
  out=${out%%$'\n'*}
  printf 'SHARED_PREFS: secondmate %s: generation %s re-read request not delivered (%s); retry owed\n' "$id" "$generation" "${out:-fm-send failed}"
  return 1
}

# fm_shared_prefs_status <id> <dest-home> <primary-data-dir>: one read-only
# line naming the primary content, and the applied, delivered, and acknowledged
# generations, then the settled state. Never writes.
fm_shared_prefs_status() {
  local id=$1 dest_home=$2 src_data=$3 primary_id dest_id generation sha delivered acked acked_sha state short
  primary_id=$(fm_shared_prefs_content_id "$src_data" 2>/dev/null) || primary_id=unreadable
  dest_id=$(fm_shared_prefs_content_id "$dest_home/data" 2>/dev/null) || dest_id=unreadable
  generation=$(fm_shared_prefs_record_get "$dest_home/$FM_SHARED_PREFS_GENERATION_REL" generation 2>/dev/null) || generation=
  sha=$(fm_shared_prefs_record_get "$dest_home/$FM_SHARED_PREFS_GENERATION_REL" sha256 2>/dev/null) || sha=
  delivered=$(fm_shared_prefs_record_get "$dest_home/$FM_SHARED_PREFS_DELIVERED_REL" generation 2>/dev/null) || delivered=
  [ "$(fm_shared_prefs_record_get "$dest_home/$FM_SHARED_PREFS_DELIVERED_REL" sha256 2>/dev/null)" = "$sha" ] || delivered=
  acked=$(fm_shared_prefs_record_get "$dest_home/$FM_SHARED_PREFS_ACK_REL" generation 2>/dev/null) || acked=
  acked_sha=$(fm_shared_prefs_record_get "$dest_home/$FM_SHARED_PREFS_ACK_REL" sha256 2>/dev/null) || acked_sha=
  if [ "$dest_id" != "$primary_id" ]; then
    state="not-applied"
  elif [ -z "$generation" ] && [ "$primary_id" = absent ]; then
    state="none"
  elif [ -z "$generation" ] || [ "$sha" != "$primary_id" ]; then
    state="generation-not-recorded"
  elif [ "$acked" = "$generation" ] && [ "$acked_sha" = "$sha" ]; then
    state="acknowledged"
  elif [ "$delivered" != "$generation" ]; then
    state="delivery-pending"
  else
    state="acknowledgement-pending"
  fi
  short=$primary_id
  [ "$short" = absent ] || [ "$short" = unreadable ] || short=${short:0:12}
  printf '%s: primary=%s applied=%s delivered=%s acknowledged=%s state=%s\n' \
    "$id" "$short" "${generation:-none}" "${delivered:-none}" "${acked:-none}" "$state"
}
