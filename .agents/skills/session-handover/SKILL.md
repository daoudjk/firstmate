---
name: session-handover
description: Load when the captain asks to wind down, pause for a handover, or switch providers or supervisor sessions, and whenever the session-start digest prints a HANDOVER PENDING section.
user-invocable: false
metadata:
  internal: true
---

# Session handover

One supervisor session hands this home to another, often on another provider.
The handover is one durable record that recovery reads, never a set of free documents.
`bin/fm-handover.sh` owns the record, its fields, and every command named below; its header is the reference.
The incoming session finds the record in its startup digest, so the captain never has to paste anything across.

## Outgoing session

1. Keep supervising until the record is written.
   Never switch off a reminder, a progress review, or any other recurring check to make the handover quiet: the incoming session needs them running.
2. Export provider-private memory first.
   Anything only this provider's own memory holds - preferences, learnings, task facts - goes into this home's `data/` owners (`data/captain.md`, `data/learnings.md`, the backlog item note) before handing over, because the next provider cannot read it.
3. Decide each worker's intent: `resume` (the default) or `hold`.
   Do not append status lines on a worker's behalf and do not mark workers paused by hand; the record carries the intent.
4. Run `bin/fm-handover.sh prepare` and fix every gap with the command it names: a live worker with no backlog item, a worker whose current state reads unknown, or an open decision that is not a captain hold (`captain-hold-lifecycle` owns holds).
   Re-run until it reports ready.
5. Write the goal and notes files.
   Describe the work as what it is - its function, interfaces, and authorization scope - under the `AGENTS.md` section 11 wording rule, because the incoming model reads these words cold and may refuse work that is framed as something it is not.
   Name every worker that runs under another home together with that home; the record lists each registered second mate's home and its active workers, and the notes say what the incoming session should expect from them.
6. Run `bin/fm-handover.sh write --goal-file <goal> --notes-file <notes>`, adding `--next <task>=<text>` where a worker's next step is not already in its own `HANDOFF.md`, and `--hold <task>` for each held worker.
7. Tell the captain the fleet is handed over and what the next session will resume, then run `bin/fm-handover.sh release` as the last action and end the session.
   Release gives up the lock and stops this home's watcher, so the incoming session can take both.
   If this session runs any other long-lived process in this home (an app server, a background monitor), stop it too; `bin/fm-lock.sh status` must read free afterwards.
   A turn-end supervision check that reports monitoring stopped after the release is expected: exit the session instead of re-arming, because re-arming takes the lock back.

## Incoming session

1. A `HANDOVER PENDING` digest section means the fleet is parked on purpose.
   A quiet wake queue is not progress, and nothing else happens until the resume rows are relaunched.
   If the digest reports the lock was refused, the outgoing session did not release it: report that diagnostic to the captain and stay read-only under `AGENTS.md` section 3.
2. Read the summary file the section names once, then run `bin/fm-handover.sh resume-plan`.
3. Relaunch every resume row before reporting anything to the captain.
   Load `harness-adapters` first.
   A row printed with `--harness <harness> --model <model>` placeholders was recorded on another harness: choose the replacement under `AGENTS.md` section 4 dispatch rules, and check the recorded provider's remaining quota before keeping it, since a worker relaunched onto an exhausted account stops silently.
   After each relaunch, `bin/fm-crew-state.sh <task>` must read a known state; recover one that does not under `stuck-crewmate-recovery`.
4. A second mate's row relaunches the mate itself; the workers under its home are that home's to relaunch, and its own startup reconciles them.
5. Hold rows stay parked; their decisions are already captain holds in the backlog.
   Record any other deliberate outcome with `bin/fm-handover.sh mark <task> hold|running`.
6. Run `bin/fm-handover.sh accept`; it refuses while a resume row is neither relaunched nor marked.
   Then tell the captain what resumed, what stays held, and which decisions wait on them.
