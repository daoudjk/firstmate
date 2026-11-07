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
- A prerequisite view grouped by consuming phase, showing observation coverage, fresh versus migration requirements, ownership, next checks and authorization beside the existing four layers.
- Source, artifact, installed and configuration lineage, an experiment lifecycle timeline built from run evidence, the MVP acceptance criteria, credential metadata, required access interactions and the durable discrepancy list.
- Human notes on any component, connection, discrepancy, or criterion, and validated edits to the intended design.

Observation outcomes are distinct and never merged into a false green:

| Outcome | Meaning |
| --- | --- |
| `ok` | The read succeeded. |
| `absent` | The read succeeded and the resource does not exist. |
| `denied` | The provider refused the read. |
| `error` | The read failed or timed out. |
| `unknown` | Nothing was read: no usable binding, an unverified account scope, or the collection deadline. |

When a read fails, a last successful read from the same manifest revision and bindings is shown separately as historical, never as current.
Proof is `proven` (a pass for the current deployment), `unversioned` (a pass on a subject that declares no version source), `failed`, `stale` (pass or fail records exist but cannot qualify for the current deployment), `unknown` (the current version is unobserved), or `not-demonstrated`.

## Enabling it

The map is off unless `config/system-map` exists.
Without that file every integration point is a silent no-op, so a home that never opts in behaves exactly as before.

1. Copy [`docs/examples/system-map/sample.config`](examples/system-map/sample.config) to `config/system-map` and set `project=<id>` (repeatable), `port`, and the cadences.
2. Prepare a manifest file for the intended design, then install it with `bin/fm-system-map.sh intent init <project> <file>`; write private resource names to `data/system-map/<project>/bindings.json`.
   The tracked [sample manifest](examples/system-map/sample.manifest.json) and [sample bindings](examples/system-map/sample.bindings.json) show both shapes.
   The sample declares prerequisites for submit, wake, enroll, launch, score, cleanup, and stop, plus run and return to zero; its nine acceptance criteria require separate proof.
   Its console checkout observation establishes source availability; installed configuration remains unknown until a separate deployment resource is observed, and its proof requires matching evidence.
   Private project manifests, resource identifiers, and activation proposals stay in that project's local data rather than this repository; installing a proposal remains an operator decision.
3. Run `bin/fm-system-map.sh validate <project>` until it reports no binding problems, then `collect <project>` once.
4. On a host with a working systemd user manager, run `bin/fm-system-map.sh install` to install the collector timer, the UI service, and the watcher check.
   `install --dry-run` prints every file and command first, and `uninstall` removes exactly what install created.
   Install refuses same-named units or checks it does not own, and uninstall leaves them running and untouched.
   Install also refuses a run marked `FM_SYSTEM_MAP_FIXTURE=1`.
5. Run `bin/fm-system-map.sh open` to get the local UI URL.

| Key | Default | Meaning |
| --- | --- | --- |
| `project` | none | A map project id; one line per project. |
| `port` | 4790 | UI port on 127.0.0.1. |
| `active_interval` | 300 | Seconds between collections while a ship or scout task record exists or this home's parent records show delegated activity. |
| `idle_interval` | 3600 | Seconds between collections otherwise; persistent secondmate existence alone is idle. |
| `review_interval` | 86400 | Seconds between daily review requests. |
| `collect_timeout` | 120 | Bound on one whole collection; each provider call is also bounded. |
| `reemit_interval` | 21600 | Seconds before an unacknowledged request is surfaced again. |

## Layout

| Path | Owner | Content |
| --- | --- | --- |
| `config/system-map` | captain | Opt-in and cadences. |
| `data/system-map/<project>/manifest.json` | intended design | Groups, components, connections, intended state per mode, owners, observations, version and pin sources, lifecycle phases, prerequisites, lineage, acceptance criteria, known gaps, credential metadata. |
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

Nothing observed is ever written into `data/`'s intended design, and intent edits never touch `state/`.

## Data contracts

The manifest (`fm-system-map.manifest.v1`) declares observations by naming a built-in adapter and a binding key; it never carries a command.
Adapters are a fixed, read-only set: `aws.ec2_instance`, `aws.ec2_tagged_instances`, `aws.ec2_image`, `aws.ecs_service`, `aws.sqs_queue`, `aws.dynamodb_table`, `aws.dynamodb_item` (named attributes only), `aws.s3_bucket` (metadata only), `aws.ecr_image`, `aws.lambda_configuration`, `aws.scheduler_schedule`, `aws.iam_role`, the access metadata adapters below, `git.revision` (a local clone, no fetch), and `firstmate.task` (local task record for live or ended state; the status line is a last-event fact).
Each AWS call is a describe, get, list, or head operation with connect, read, and process timeouts, and provider text is stored with account numbers and ARNs redacted.
When `bindings.json` pins `expected_account`, the collector first checks the caller identity and skips every AWS read under any other account.
The additional metadata adapters require exact bindings: Lambda `function_name`, Scheduler `schedule_name` and `group_name`, and IAM `role_name`.
They call only `lambda get-function-configuration`, `scheduler get-schedule` and `iam get-role`, with fixed CLI projections excluding environment variables, target input and policy documents.
Lambda reports state, code hash, runtime, timeout and a role fingerprint; Scheduler reports state, expression, timezone, modification time and target/role fingerprints; IAM reports role identity, creation time and maximum session duration.
Role existence does not test trust or effective permission, and Lambda configuration does not establish runtime invocation or installed configuration equality.
Native activation of additional bindings remains an operator decision; unavailable or denied coverage can use an imported owner receipt.
A subject's `version_from` names the observation whose version identifies what is deployed, and `pin` names the binding field holding the intended version.
After a manifest revision or private binding changes, previous observations cannot establish current deployment, runtime, or proof until the next collection.
Snapshots and successful reads carry a canonical digest of the validated bindings so reused observation IDs cannot inherit another resource's evidence.

Optional manifest `prerequisites` is a list of `{id, title, producer, resource, phases, baseline, next_check}` records.
`producer` names an existing subject, `phases` is a nonempty list of declared lifecycle phase IDs, and `baseline` is `fresh`, `migration`, or `both`.
Optional `observation` must belong to that producer; optional `evidence` names a receipt ID whose `prerequisites` map assesses this prerequisite, with a missing receipt shown as missing evidence.
Optional `expected_state` tests the observation's resource state, `owners` uses the existing owner/task shape, and `authorization` is independently `authorized`, `awaiting-authorization`, `denied`, `unknown` (default), or `not-required`.
A successful read yields `present` or `mismatch`; `absent`, `denied`, `error`, `unknown`, `not-tested` and `stale` remain separate.
Freshness follows twice the current collection interval; stale records retain their earlier `observed_state` and time.
The view distinguishes `observed`, `imported`, `uncovered`, `uncollected` and `missing-evidence` coverage, and flags phases with no prerequisites declared.
An observation takes precedence over an imported assessment, including when it fails; neither presence nor authorization grants phase proof.
Imported assessments carry a `prerequisites` map from prerequisite ID to `present`, `absent`, `denied`, `unknown`, or `not-tested` on an ordinary evidence record, plus a required textual `scope`.
An imported assessment qualifies only when its `resource_identities` entry for the producer matches the currently bound prerequisite observation digest, or the producer's current version observation identity when the prerequisite declares no observation, and its `versions` entry matches the producer's current observed version; missing or mismatched versions, bindings or identities leave it unknown with missing evidence coverage.
They retain that record's observed/recorded time and provenance and never become collector observations; future-dated prerequisite assessments are rejected at intake.
Only the new prerequisite references are validated at intake; the existing deferred criterion/phase receipt-validation work remains separate.

### Access relationships

Optional `access_dependencies` holds shared checks referenced by optional `interactions`; these extend the manifest rather than create a second ledger.
Each dependency requires `id`, `title`, `kind`, `subject`, nonempty `owners` (the existing owner/task shape), and `next_check`.
Its optional `observation` belongs to that subject; optional `evidence` references an owner receipt through the existing evidence store.
`kind` is `role-existence`, `trust`, `identity-policy`, `resource-policy`, `key-policy`, `permissions-boundary`, `session-policy`, `organization-policy`, `endpoint-policy`, `pass-role`, `configuration`, or `tags`.
`applicability` defaults to `required`; `not-applicable` requires a specific `reason` and cannot carry an observation or baseline.
An optional `baseline` records `format` (`policy`, `configuration`, `tags`, or `role`), explicit boolean `complete`, `source`, the original `observed_at`, and canonical `sha256` (required when complete) plus optional `raw_sha256`.
For an SQS policy observation, a complete baseline also needs `encryption_identity`, the digest of the observed `KmsMasterKeyId` and `SqsManagedSseEnabled` attributes.
If the queue uses a KMS key, its dependency must name `key_dependency`, an observed `key-policy` dependency whose KMS binding identifies that same key; otherwise coverage remains insufficient.
For an IAM role observation, a complete baseline also needs `relationships_sha256`, the fingerprint of complete attached and inline policy membership and the permissions-boundary relationship.
The access adapters produce the digests to retain in a reviewed baseline; neither collection nor comparison adopts observations into intent.
An incomplete or absent baseline remains `incomplete-baseline`, even when a new read succeeds.
Policy dependencies may name exact literal principal subjects in `references`; their current role ARN fingerprints must match a literal principal in an Allow statement.
The view distinguishes a principal found only in Deny statements as `denied-reference`, without interpreting the policy's effective permissions.
Missing, denied, stale and wrong-reference principals stay distinct, with creation, identity and version metadata; role presence and a matching reference prove neither AWS propagation nor actual assumption.

Each interaction requires `id`, `title`, `caller` and `target` subject IDs, `identity` (an existing subject or credential ID), nonempty `operations` (`service:operation` strings), `phases`, dependency IDs in `dependencies`, explicit `context`, `analysis_scope`, nonempty `owners`, and `next_check`.
`context_complete` defaults to false and must be explicitly true for complete declared coverage or request proof.
Context records the concrete target constraints, service principal, transport, tag and condition inputs that matter; unresolved inputs must be described explicitly rather than assumed satisfied.
Every interaction exposes missing dependency kinds for role existence, trust, identity/resource/key policies and boundary/session/organization/endpoint restrictions, even when no checks for those kinds were declared.
Incomplete context and missing or stale request receipts appear in the consolidated gap list, with shared dependency gaps listed once and linked to every affected interaction.
An `iam:PassRole` assertion or a known role-carrying request (`lambda:CreateFunction`, `lambda:UpdateFunctionConfiguration`, `scheduler:CreateSchedule`, `scheduler:UpdateSchedule`, `ecs:RegisterTaskDefinition`, `ecs:RunTask`, `ec2:RunInstances`) additionally requires a `pass-role` dependency, including an explicit not-applicable reason when no role is passed.
Action spelling is compared without case for this dependency check.
Other callers declare that dependency whenever passing a role is part of their service request.
Use reasoned not-applicable references when a restriction cannot apply; an uncollected or unmapped restriction is never not-applicable by default.
The derived `access` view lists all gaps together, every interaction, its shared checks, and lifecycle phases without declared interactions.
It appears in Access coverage and in the relevant resource details, without granting permission or replacing deployment preflight.

Existing exact-instance and tagged-instance EC2 reads also expose the three IMDS metadata settings separately; missing settings, an empty range or a continuation token cannot establish configuration coverage.
The fixed access adapters use only these exact configured bindings and API calls:

| Adapter | Binding fields | Read-only calls |
| --- | --- | --- |
| `aws.iam_role_access` | `role_name` | IAM `GetRole` (identity, creation, trust, boundary), `ListAttachedRolePolicies`, `ListRolePolicies` |
| `aws.iam_inline_policy` | `role_name`, `policy_name` | IAM `GetRolePolicy` |
| `aws.iam_managed_policy` | `policy_arn` | IAM `GetPolicy`, `GetPolicyVersion` for its returned default version |
| `aws.s3_policy` | `bucket` | S3 `GetBucketPolicy` |
| `aws.sqs_policy` | `queue_url` | SQS `GetQueueAttributes` for policy and encryption metadata |
| `aws.dynamodb_policy` | `resource_arn` | DynamoDB `GetResourcePolicy` |
| `aws.kms_policy` | `key_id` | KMS `GetKeyPolicy` for `default` |
| `aws.ecs_task_metadata` | `task_definition` | ECS `DescribeTaskDefinition` with `include=TAGS`, projecting only identity, role references, status and tags |

Role policy lists read one bounded service page with CLI pagination disabled; truncation, continuation markers or a missing completeness member leave the inventory incomplete.
Incomplete or malformed role membership and boundary metadata cannot match a relationship baseline.
Each attached/inline policy and configured boundary needs a separately declared current policy observation with a matching baseline; listing an attachment never means its document was read.
The map does not enumerate accounts, collect secret values, pivot identities, simulate requests, grant permissions or retry denied reads under another identity.
Independent configured checks finish despite another check being missing, denied or incomplete, subject to the existing collection deadline and per-call timeout.
Access reads retain private immutable request/response provenance and hashes under `state/system-map/<project>/reads/`, which the HTTP server never serves.
The view projects document fingerprints, statement Allow/Deny counts, condition operator names and role/policy identity fingerprints, excluding policy values and tag values.
An account pin verified by the existing caller-identity read and an observing identity fingerprint are required for current access coverage; an unverified successful read stays unknown.
A missing response member is unknown; absence requires an authoritative provider response.
In particular, omitted task tags cannot become an empty historical tag baseline.

Policy comparison parses JSON and ignores object key order, statement order and array order only in IAM Action/NotAction, Resource/NotResource and Principal/NotPrincipal members.
It preserves scalar versus list types, identifiers, condition values and arbitrary arrays, with no condition evaluation or general IAM simulation.
Equal canonical digests with different raw digests are `representation-only`; different digests are `policy-drift` or `configuration-drift`; incomplete reads or incompatible formats are `insufficient-evidence`.
An SQS encryption identity change is `configuration-drift` even when its queue policy is unchanged, and it invalidates dependent interaction proof.
An IAM role membership or permissions-boundary change is `configuration-drift` even when the trust policy and separately readable policy documents are unchanged.
These are conservative document comparisons, not effective-permission verdicts.
`declared-baselines-observed` means every declared check and required kind has current baseline coverage; `effective_access` always remains `unknown`.
Explicit denies, unknown condition inputs and unobserved restrictions therefore cannot be converted into an Allow claim by document presence.

Owner receipts or imported reports can supply `access_checks` mapping dependency IDs to `{outcome, binding_digest, observer_identity, version, facts, error?}`.
The two identities are SHA-256 fingerprints: the exact observation binding (or producer version binding when no observation is declared) and the observing identity.
Successful `facts` contains `format`, explicit boolean `complete`, and canonical `sha256`, plus optional `raw_sha256`, SQS encryption and KMS key fingerprints, a role relationship fingerprint, `policy_identity`, all/Allow/Deny principal fingerprints, Allow/Deny counts and condition operator names; policy values are refused.
An assessment requires original `observed_at`, explicit `scope`, a nonhistorical owner receipt/report and matching producer `versions` and `resource_identities`, with a fresh independently observed producer version and deployment.
Qualified assessments are labeled `imported`, retaining source, time, scope and observing identity; missing, stale or mismatched evidence remains `missing-evidence` and unknown.
Any collected result, including denial or an incomplete read, takes precedence over an imported assessment.
Manual assertions cannot qualify as collected access metadata, and importing a check never grants an access or request-proof verdict.

An optional interaction `evidence` names an ordinary receipt whose `access_requests` maps that interaction ID to its current derived `assertion_digest`.
This digest binds the declared operations/target/context, complete private bindings, current participant identities/versions, policy fingerprints, observing identity/scope and dependency state.
Actual request proof requires receipt provenance, original `observed_at`, explicit `scope`, a nonhistorical result, and matching deployed versions and resource identities for caller, identity and target.
Checks, participant version observations and request receipts must be fresh within twice the current collection interval; refreshed identical reads preserve the assertion digest, while changed versions, identities, context or coverage invalidate it.
Future-dated or unknown-interaction request assessments are refused at intake.
Unversioned subjects and credential-only identities cannot qualify as demonstrated requests; they remain visible with `not-demonstrated` or `stale` proof until versioned identity evidence is modeled.
A matching pass becomes `demonstrated`, a matching fail `failed`, and neither establishes general access beyond that exact request context.
Source, build, installed, runtime and MVP proof retain their existing independent contracts.

Optional subject `lineage` is a list of `{stage, subject, expected?, evidence?, note?}` records.
`stage` is `source`, `artifact`, `installed`, or `config`, and `subject` names the independently tracked subject for that stage.
The view carries its current observed version, resource identity, observations and four layers; `expected` yields an explicit mismatch only when the current observed version differs.
An optional evidence ID can supply a separately labeled `reported_version` from that receipt's `versions[subject]` when no version is observed.
Reported or historical lineage never changes deployment or qualifies as live proof; receipt-reported lineage without a matching current resource binding stays stale, while a matching binding identifies the resource but cannot establish its current installed version.
Source revisions and built artifacts alone establish no installed version.
Stages with no observed version or receipt remain unknown; unqualified receipt reports remain visible as stale.

An evidence record (`fm-system-map.evidence.v1`) names its subjects, optional criterion, phase and run id, the exact `versions` it covers, a `pass`, `fail`, or `not-run` result, timestamps, a summary, and provenance.
For each version-tracked subject, a receipt must include `resource_identities` mapping the subject ID to its per-observation binding digest to qualify as proof.
Copy that digest from `resource_identity` in the current subject view or `binding_digest` on its version observation when producing the receipt.
A receipt qualifies for proof, acceptance, or task verification only when deployment is current and its version and resource identity match the observation.
Receipts without that identity remain visible but do not qualify; evidence intake never adds the identity on the producer's behalf.
A criterion fails while any subject it depends on has a deployment mismatch, even when a receipt passes for the observed version.
A declared pin without a binding value leaves deployment unknown and opens a deployment discrepancy; for a version-tracked subject, it also prevents proof, acceptance, and task verification from passing.
The map stamps `received_at` when it stores a receipt; live verification requires both its event time and receipt time to follow the task's precise completion time.
Provenance `kind` is `receipt`, `imported-report`, or `manual`; none of them is a collector observation.
A record proves a version-tracked subject only for the exact observed version and resource identity it names, and a `historical` record never qualifies.
A subject with no `version_from` cannot carry version-bound proof: a pass on it shows as `unversioned` ("passed, not version-bound"), a criterion that depends on it shows `unversioned` rather than passed, and landed work on it is never reported as live-verified.

Manifests, bindings, and evidence refuse fields or values that look like credential material.
Credential records extend purpose, owner, `expires`, and `rotation` with optional `issuer` (another credential ID), `not_before`, `expiry_basis` (`observed`, `inferred`, or `unknown`), `expected_expires`, `observed_at`, `evidence`, `renewal_owner`, `restart_required` (`yes`, `no`, or `unknown`), and positive `full_window_seconds`.
`expected_expires` records an inference without substituting it for an observed expiry; inferred dates cannot be stored in `expires`, and `expires` drives expiry alerts or safe timing when `expiry_basis` is `observed` or omitted for compatibility with existing manifests.
The credential view shows each identity's expiry, renewal mechanism, owner, issuer, and limits.
For a full run the start must be strictly before the earliest chain expiry minus the entire support interval, and after every known not-before time.
`latest_safe_start`, remaining seconds and `fits`/`does-not-fit` require observed expiries and known not-before dates throughout the issuer chain; missing validity, an inferred expiry or a cycle leaves feasibility unknown.
An expiry within seven days opens a discrepancy under its existing stable credential ID.

## Supervision integration

- **Activity.** Local ship/scout records select active cadence.
  For persistent secondmates, only a `working` parent status or a delivered, unresolved `fm-pending-reply.v1` request to a recorded secondmate selects it; a paused, blocked, decision or terminal parent status with that request's correlation ID at or after delivery parks the request.
  Resolved requests and mate existence alone do not select active cadence.
  The view exposes the selected interval and its task/parent-record reasons, and freshness uses that interval.
  These are bounded local status-tail reads in this home, with no secondmate chat, child-home scan, endpoint query or added collector/watch.
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

- The UI binds 127.0.0.1 only, accepts only a `127.0.0.1` or `localhost` Host header for its own port, and serves a fixed file list.
- POST writes require an `application/json` body and reject a foreign `Origin` or `Sec-Fetch-Site: cross-site` header; a local client with no `Origin` may send JSON.
- Writes are limited to notes and to the title, description, notes, and intended state of an existing subject; structural changes go through `intent replace` with a reason.
- Evidence paths are shown as text and only `https` links are clickable; no file content is served.
- A collection run with `FM_SYSTEM_MAP_FIXTURE=1` is marked as test data in the UI and the summary; installation is refused while that marker is set.
