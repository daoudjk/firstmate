Mode: Codex Stop-owned foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling the presented work, reconcile open decisions and unread status lines, then run the exact `WAKE_ACK_REQUIRED` command.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. The trusted `.codex/hooks.json` Stop handler owns the next bounded foreground checkpoint when the model attempts to finish.
   Do not start another watcher after an ordinary wake.
4. A quiet checkpoint continues the model so it can drain pending records and user messages before its next Stop checkpoint.
   An actionable checkpoint continues the model to handle and acknowledge the delivered wake.
5. If the hook reports `FIRSTMATE CODEX SUPERVISION STOPPED`, report that failure explicitly and end the continuation without repeated retries.
   The same Stop chain permits an attended exit after that one failure notification; a fresh user turn can retry after repair.
6. Never use shell `&`, Codex background tasks, or `bin/fm-watch-arm.sh` for normal Codex supervision.
   A standalone `bin/fm-watch-checkpoint.sh` call remains a foreground diagnostic probe.

The Stop handler uses the existing checkpoint and session-lock ownership checks described in `docs/turnend-guard.md`.
This is synchronous Stop continuation, with a model handling interval between checkpoints.
It does not provide asynchronous delivery after Codex actually exits or when trusted project hooks do not fire.
An explicit interrupt ends the wait; it does not authorize a replacement supervisor.
