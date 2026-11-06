---
name: system-map-review
description: >-
  Load on any `check:` wake whose output starts `system-map:`, when the session-start digest's System map section lists pending review requests, when the captain asks about the system map or a mapped component, at intake of a ship or scout for a project named in a map's `firstmate_projects`, and after cleanup of a task bound to the map.
user-invocable: false
metadata:
  internal: true
---

# system-map-review

The living system map (`bin/fm-system-map.sh`, contracts in `docs/system-map.md`) observes and records; it never acts.
This skill is how the main firstmate turns its requests into ordinary fleet work.
It adds no supervisor, no task ledger, and no cloud action: every follow-up goes through the existing intake, dispatch, and escalation contracts in `AGENTS.md`.

## Read the map

1. `bin/fm-system-map.sh view <project> --compact` prints the derived view as JSON; `summary` prints the bounded digest; the UI is `http://127.0.0.1:<port>/`.
2. Treat every layer separately.
   Implementation, deployment, runtime, and proof each carry their own status, and none implies another.
3. Unknown, denied, error, absent, stale, and not-demonstrated are different facts.
   Never report an unknown or denied observation as healthy, and never call a historical or other-version record proof.
4. A view marked as test data describes no real system.

## Daily review and discrepancy wakes

1. Compare the intended design, the latest observations, and the evidence records for each open discrepancy.
2. Read what changed since the previous review: new completion records, newly opened or resolved discrepancies, the bound tasks' current state through `bin/fm-crew-state.sh`, and recent merges in the bound projects.
3. For each open discrepancy, decide one of:
   - it is already owned: link it to the existing backlog task with `bin/fm-system-map.sh link <project> <discrepancy> <task>`;
   - it needs new work: file it through the ordinary intake and dispatch path, then link it;
   - it is an intended-design error: propose the edit to the captain; change intent only on the captain's word, with `intent set` or `intent replace`;
   - it is an accepted exception: leave it open and visible, and make sure its exception text names the approver and the end condition.
4. Suggest only fixes the evidence supports, and name that evidence.
5. Record the review with `bin/fm-system-map.sh review-done <project> --note "<one line>"`.
   Acknowledge a single request without a full review only with `ack <project> <key>`.
6. Report to the captain only exceptions under `AGENTS.md` section 9: a new high-severity discrepancy, an expiring credential, a collector that keeps failing, or a decision the map exposed.

## Hard limits

- Never repair cloud resources, change permissions, or start an experiment because the map shows a gap; those stay ordinary captain-authorized work.
- Never wake, steer, or relaunch a paused or idle worker to answer a map request; record the link and leave the work queued for its owner.
- Never edit the intended design to make a discrepancy disappear.
- Never copy a project's map into another home; secondmates read the primary map and report evidence through their parent channel (see `docs/system-map.md`).

## Task binding and completion

- At intake of a ship or scout for a mapped project, bind it: `bin/fm-system-map.sh bind <task> --project <project> --subject <ids>`, or `--no-subjects --note <why>` when it touches no mapped subject.
  An unbound task in a mapped project shows as a coverage discrepancy.
- Put the printed brief line into the task's `## Firstmate spec` so the worker knows which subjects it changes.
- Cleanup records implementation-complete automatically for a bound ship.
  `bin/fm-system-map.sh verify <task>` then shows whether each subject is live-verified; landed work is not live-verified until version-bound evidence recorded after the landing passes.
- Workers deliver receipts as evidence records (`evidence add`, or a file in `data/system-map/<project>/inbox/` that the next collection validates and ingests).
