#!/usr/bin/env bash
# fm-system-map.sh - the living system map: intended design, read-only
# observations, version-bound evidence, discrepancies, and a local UI.
#
# Opt-in per home: without config/system-map, the passive commands (tick,
# summary, check, complete) exit 0 silently and every other command refuses, so
# wiring them into session start, the watcher, and teardown changes nothing for
# a home that never enabled the map. docs/system-map.md owns the data
# contracts, the activation procedure, and the operating model; the
# system-map-review skill owns how the main firstmate acts on a map request.
#
# Usage: fm-system-map.sh <command> [args]
#
#   tick                       Scheduled entry point (user timer). Collects each
#                              configured project when its cadence is due
#                              (active_interval while a ship or scout task record
#                              exists; persistent secondmate records never count;
#                              idle_interval otherwise) and queues the daily
#                              review request. Never starts a supervisor.
#   collect [project]          Collect now. Exit 75 when another collection holds
#                              the project's lock.
#   summary                    Bounded local-only digest for session start.
#   check                      Watcher check body: prints one line when durable
#                              review requests are due, nothing otherwise.
#   status                     Collector health, scheduler units, watcher check.
#   view [project] [--compact] Print the derived read-only view as JSON: per
#                              subject implementation, deployment, runtime, and
#                              proof layers, discrepancies, acceptance, timeline.
#   validate [project]         Validate manifest, bindings, and evidence. Exit 1
#                              when a binding or evidence record is unusable.
#   serve                      Serve the UI on 127.0.0.1 at the configured port.
#   open                       Print the local UI URL.
#   evidence add <project> <file.json>
#                              Record one append-only version-bound evidence
#                              record (receipts dropped in
#                              data/system-map/<project>/inbox/ are ingested by
#                              the next collection instead).
#   annotate <project> <target> <text> [--author NAME]
#   intent set <project> <subject> <field> <value> [--base-revision N] [--reason R]
#                              Edit title, description, notes, or intended.<mode>.
#   intent replace <project> <manifest.json> --reason R
#   intent init <project> <manifest.json>
#                              Edits validate, increment the manifest revision,
#                              and archive the previous one under
#                              data/system-map/<project>/history/. Init creates
#                              the first manifest at revision 1.
#   bind <task> [--project P] --subject a,b [--note N]
#   bind <task> [--project P] --no-subjects --note REASON
#                              Validated companion binding of a task to map
#                              components and connections, or a reviewed
#                              exemption. A live task in a bindings.json
#                              firstmate_projects project with neither shows as
#                              a coverage discrepancy.
#   complete <task> [--kind K] [--mode M] [--pr URL]
#                              Called by fm-teardown.sh after a task's record is
#                              removed; records implementation-complete for a
#                              bound ship. Advisory: never fails teardown.
#   verify <task>              Implementation-complete vs live-verified per bound
#                              subject. Exit 3 when landed work is not yet
#                              live-verified.
#   link <project> <discrepancy> <task>
#                              Link a discrepancy to an existing backlog task.
#   ack <project> [key...]     Acknowledge pending review requests (all if none).
#   review-done <project> [--note N]
#                              Record a completed review and clear its requests.
#   install [--dry-run]
#   uninstall [--dry-run]      Single-owner, idempotent install and removal of
#                              the systemd user collector timer, the UI service,
#                              and the registered watcher check
#                              (state/system-map.check.sh). Units carry a
#                              per-home tag and an explicit bounded PATH.
#
# Test seams: FM_SYSTEM_MAP_AWS (aws executable), FM_SYSTEM_MAP_SYSTEMCTL,
# FM_SYSTEM_MAP_UNIT_DIR, plus the usual FM_CONFIG_OVERRIDE, FM_DATA_OVERRIDE,
# and FM_STATE_OVERRIDE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_ROOT FM_HOME

case "${1:-}" in
  ''|-h|--help|help)
    sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '/^set -u$/d' -e 's/^# \{0,1\}//'
    exit 0
    ;;
esac

PYTHON=$(command -v python3 2>/dev/null) || {
  case "${1:-}" in
    tick|summary|check|complete) [ -f "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/system-map" ] || exit 0 ;;
  esac
  echo "error: python3 is required for the system map" >&2
  exit 1
}
exec "$PYTHON" -I "$SCRIPT_DIR/fm_system_map.py" "$@"
