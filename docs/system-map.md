# Living system map

The living system map is an opt-in, private, local view of one project's intended design next to what read-only collectors actually observe and what version-bound evidence actually proves.
It answers "what is this system supposed to be, what is it now, and what has been demonstrated" without a second task tracker or a second supervisor.
`bin/fm-system-map.sh` owns the command surface (its header and `help`), and `system-map-review` owns how the main firstmate acts on map requests.

## What it shows

- A map of components and connections, drawn inside the manifest's groups, with an Intended, Observed, and Difference lens.
  Every connection is also listed in a table so each one can be opened from the keyboard.
- For every component and connection, four separate layers: implementation, deployment, runtime, and proof.
  None implies another, and there is no completion percentage.
- Each observation's outcome, state, facts, check time, and scope (region, account label, and whether the account was verified).
- The durable discrepancy list, an experiment lifecycle timeline built from run evidence, the MVP acceptance criteria, and credential metadata.
- Human notes on any component, connection, discrepancy, or criterion, and validated edits to the intended design.

Observation outcomes are distinct and never merged into a false green:

| Outcome | Meaning |
| --- | --- |
| `ok` | The read succeeded. |
| `absent` | The read succeeded and the resource does not exist. |
| `denied` | The provider refused the read. |
| `error` | The read failed or timed out. |
| `unknown` | Nothing was read: no usable binding, an unverified account scope, or the collection deadline. |

When a read fails, the last successful read is kept in a separate record and shown as historical, never as current.
Proof is `proven` (a pass at the exact observed version), `unversioned` (a pass on a subject that declares no version source), `failed`, `stale` (pass or fail records exist only for other versions or are historical), `unknown` (the current version is unobserved), or `not-demonstrated`.

## Enabling it

The map is off unless `config/system-map` exists.
Without that file every integration point is a silent no-op, so a home that never opts in behaves exactly as before.

1. Copy [`docs/examples/system-map/sample.config`](examples/system-map/sample.config) to `config/system-map` and set `project=<id>` (repeatable), `port`, and the cadences.
2. Write `data/system-map/<project>/manifest.json` (intended design) and `data/system-map/<project>/bindings.json` (private resource names); the tracked [sample manifest](examples/system-map/sample.manifest.json) and [sample bindings](examples/system-map/sample.bindings.json) show both shapes.
   Install a first manifest with `bin/fm-system-map.sh intent init <project> <file>`.
3. Run `bin/fm-system-map.sh validate <project>` until it reports no binding problems, then `collect <project>` once.
4. Run `bin/fm-system-map.sh install` to install the collector timer, the UI service, and the watcher check.
   `install --dry-run` prints every file and command first, and `uninstall` removes exactly what install created.
   Install refuses same-named units or checks it does not own, and uninstall leaves them running and untouched. Install also refuses a run marked `FM_SYSTEM_MAP_FIXTURE=1`.
5. Run `bin/fm-system-map.sh open` to get the local UI URL; keep its fragment key private.

| Key | Default | Meaning |
| --- | --- | --- |
| `project` | none | A map project id; one line per project. |
| `port` | 4790 | UI port on 127.0.0.1. |
| `active_interval` | 300 | Seconds between collections while a ship or scout task record exists. |
| `idle_interval` | 3600 | Seconds between collections otherwise; persistent secondmate records never count as active work. |
| `review_interval` | 86400 | Seconds between daily review requests. |
| `collect_timeout` | 120 | Bound on one whole collection; each provider call is also bounded. |
| `reemit_interval` | 21600 | Seconds before an unacknowledged request is surfaced again. |

## Layout

| Path | Owner | Content |
| --- | --- | --- |
| `config/system-map` | captain | Opt-in and cadences. |
| `data/system-map/<project>/manifest.json` | intended design | Groups, components, connections, intended state per mode, owners, observation declarations, version and pin sources, lifecycle phases, acceptance criteria, known gaps, credential metadata. |
| `data/system-map/<project>/bindings.json` | private | Region, account label, optional expected account, CLI profile name, and per-binding resource names; `firstmate_projects` names the Firstmate projects whose tasks need a map reference. |
| `data/system-map/<project>/evidence/` | append-only | One version-bound evidence record per file. |
| `data/system-map/<project>/inbox/` | drop box | Receipts the next collection validates and moves into `evidence/`; invalid ones move to `inbox/rejected/`. |
| `data/system-map/<project>/annotations.json` | humans | Notes; resolving a note keeps it. |
| `data/system-map/<project>/discrepancies.json` | collector | Durable discrepancy ledger with stable ids and task links. |
| `data/system-map/<project>/tasks/`, `completions/` | firstmate | Task bindings and landed-work records. |
| `data/system-map/<project>/history/` | intent edits | Every previous manifest revision plus a change log. |
| `state/system-map/<project>/snapshot.json` | collector | The latest published observations, replaced atomically. |
| `state/system-map/<project>/last-success.json` | collector | The last successful read of each observation, kept separately. |
| `state/system-map/<project>/health.json`, `requests.json`, `schedule.json` | collector | Collector health, pending supervisor requests, review schedule. |
| `state/system-map/capability` | map owner | Owner-only 0600 capability for every UI API read and write. |

Nothing observed is ever written into `data/`'s intended design, and intent edits never touch `state/`.

## Data contracts

The manifest (`fm-system-map.manifest.v1`) declares observations by naming a built-in adapter and a binding key; it never carries a command.
Adapters are a fixed, read-only set: `aws.ec2_instance`, `aws.ec2_tagged_instances`, `aws.ec2_image`, `aws.ecs_service`, `aws.sqs_queue`, `aws.dynamodb_table`, `aws.dynamodb_item` (named attributes only), `aws.s3_bucket` (metadata only), `aws.ecr_image`, `git.revision` (a local clone, no fetch), and `firstmate.task` (local task record for live or ended state; the status line is a last-event fact).
Each AWS call is a describe, get, list, or head operation with connect, read, and process timeouts, and provider text is stored with account numbers and ARNs redacted.
When `bindings.json` pins `expected_account`, the collector first checks the caller identity and skips every AWS read under any other account.
A subject's `version_from` names the observation whose version identifies what is deployed, and `pin` names the binding field holding the intended version.
After a manifest revision or private binding changes, previous observations cannot establish current deployment, runtime, or proof until the next collection.
Snapshots and successful reads carry a canonical digest of the validated bindings so reused observation IDs cannot inherit another resource's evidence.

An evidence record (`fm-system-map.evidence.v1`) names its subjects, optional criterion, phase and run id, the exact `versions` it covers, a `pass`, `fail`, or `not-run` result, timestamps, a summary, and provenance.
For each version-tracked subject, a receipt may include `resource_identities` mapping the subject ID to its per-observation binding digest, exposed as `resource_identity` in the subject view and `binding_digest` on its version observation. A receipt qualifies for proof, acceptance, or task verification only when both its version and resource identity match the current observation. Receipts without that identity remain visible but do not qualify; evidence intake never adds the identity on the producer's behalf.
The map stamps `received_at` when it stores a receipt; live verification requires both its event time and receipt time to follow the task's precise completion time.
Provenance `kind` is `receipt`, `imported-report`, or `manual`; none of them is a collector observation.
A record proves a version-tracked subject only for the exact observed version and resource identity it names, and a `historical` record never qualifies.
A subject with no `version_from` cannot carry version-bound proof: a pass on it shows as `unversioned` ("passed, not version-bound"), a criterion that depends on it shows `unversioned` rather than passed, and landed work on it is never reported as live-verified.

Manifests, bindings, and evidence refuse fields or values that look like credential material.
Credentials are described by purpose, owner, expiry, and rotation only, and an expiry within seven days opens a discrepancy.

## Supervision integration

- **Scheduler.** A systemd user timer runs `fm-system-map.sh tick` on the active cadence; `tick` collects when the active or idle interval is due and queues the daily review request.
  Run `collect` for a manual observation instead of forcing the scheduled tick.
  The units carry an explicit `PATH` built from the tools resolved at install time, because user services do not inherit the login `PATH`.
  The collector never starts a supervisor and runs whether or not one exists.
  A collection advances `last_success_at` only after at least one observation succeeds.
- **Requests.** New or reopened high and medium discrepancies and the daily review become durable records in `requests.json`.
  The registered watcher check (`state/system-map.check.sh`) surfaces them as one `check:` wake while a supervisor runs, and the session-start digest lists them otherwise.
  They stay pending until `review-done` or `ack`.
- **Session start.** The digest's System map section is a bounded local read of the snapshot and ledger, with no network call.
- **Tasks.** `bind` records which subjects a task changes; an unbound live task in a `firstmate_projects` project is a coverage discrepancy.
- **Completion.** `bin/fm-teardown.sh` calls `complete` after the task record is removed; it records implementation-complete for a bound ship, is bounded, and cannot fail or undo the cleanup.
  `verify <task>` keeps implementation-complete separate from live-verified, which needs passing current-version evidence recorded after the landing.

## Secondmates

One home owns each map: the primary home that holds its `config/system-map`.
Secondmates do not copy manifests or snapshots into their own homes.
They read the primary map through its UI URL, or with `FM_HOME=<primary home> bin/fm-system-map.sh view <project>` or `summary`, which only read.
Their workers' receipts reach the primary through the existing parent channel ([`docs/secondmate-parent-channel.md`](secondmate-parent-channel.md)); the main firstmate records them with `evidence add` or the inbox drop box.
A file on disk changing does not refresh any running agent's context; an agent sees new map state only when it reads the map again.

## Safety boundaries

- The UI binds 127.0.0.1 only, accepts only a `127.0.0.1` or `localhost` Host header for its own port, serves a fixed file list, and requires the owner-only capability for every API read and write.
  The public page never embeds the capability; `open` places it in a URL fragment that the browser sends only as an API header.
- Writes are limited to notes and to the title, description, notes, and intended state of an existing subject; structural changes go through `intent replace` with a reason.
- Evidence paths are shown as text and only `https` links are clickable; no file content is served.
- A collection run with `FM_SYSTEM_MAP_FIXTURE=1` is marked as test data in the UI and the summary; installation is refused while that marker is set.
