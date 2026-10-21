#!/usr/bin/env python3
"""Cancel an isolated hook process group through the checkpoint interface."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def alive(pid):
    if pid is None:
        return False
    result = subprocess.run(
        ['ps', '-o', 'stat=', '-p', str(pid)], text=True, capture_output=True,
        check=False,
    )
    state = result.stdout.strip()
    return bool(state) and not state.startswith('Z')


root, fixtures = map(Path, sys.argv[1:3])
checkpoint = Path(sys.argv[3]) if len(sys.argv) > 3 else root / 'bin/fm-watch-checkpoint.sh'
for mode in ('native', 'perl'):
    home = fixtures / f'native-group-cancel-{mode}'
    state = home / 'state'
    state.mkdir(parents=True)
    env = os.environ.copy()
    env.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(root), FM_STATE_OVERRIDE=str(state),
               FM_POLL='300', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999')
    if mode == 'perl':
        env['BASH_FUNC_command%%'] = (
            '() { case "$*" in "-v timeout"|"-v gtimeout") return 1;; esac; '
            'builtin command "$@"; }'
        )
    child = subprocess.Popen(
        [str(checkpoint), '--seconds', '180'], env=env, start_new_session=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    watcher = None
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            lock = state / '.watch.lock/pid'
            if lock.exists() and (state / '.last-watcher-beat').exists():
                watcher = int(lock.read_text())
                break
            if child.poll() is not None:
                out, err = child.communicate()
                raise AssertionError((mode, 'checkpoint exited before readiness', out, err))
            time.sleep(.02)
        assert watcher is not None, f'{mode}: no ready watcher'
        # Native hook cancellation can kill the hook group before its EXIT
        # handlers run. A retained dead lock is allowed; a live waiter is not.
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=5)
        deadline = time.monotonic() + 2
        while alive(watcher) and time.monotonic() < deadline:
            time.sleep(.02)
        assert not alive(watcher), f'{mode}: native group cancellation left watcher {watcher} alive'
        child.communicate(timeout=5)
        print(f'ok - {mode} timer leaves no live watcher after hard native hook-group cancellation', flush=True)
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=5)
        # A failing counterfactual may have escaped into its own process group.
        # Retire it only while it still belongs to this fixture's own session.
        if alive(watcher):
            try:
                if os.getsid(watcher) == child.pid:
                    os.killpg(os.getpgid(watcher), signal.SIGTERM)
            except ProcessLookupError:
                pass
