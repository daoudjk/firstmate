#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root, fixtures = map(Path, sys.argv[1:])
failures = []


def gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


for timer in ('timeout', 'perl'):
    for action in ('deadline', 'interrupt', 'subscribe-interrupt', 'interrupt-resistant', 'blocked', 'quiet', 'error'):
        home = fixtures / f'eventwait-{timer}-{action}'
        for directory in ('state', 'config', 'data', 'fakebin', 'temp'):
            (home / directory).mkdir(parents=True, exist_ok=True)
        (home / 'state/crew.meta').write_text('window=lab:w:p\nbackend=herdr\nkind=ship\n')
        cli = home / 'fakebin/herdr'
        cli.write_text('''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['FM_EVENT_TEST_HOME'] + '/cli.log', 'a') as log:
    log.write(' '.join(args) + '\\n')
if args[:2] == ['status', '--json']:
    print(json.dumps({'client': {'version': '0.7.3', 'protocol': 16}, 'server': {'running': True}}))
elif args[:2] == ['session', 'list']:
    print(json.dumps({'sessions': [{'name': 'lab', 'socket_path': '/fixture-only.sock'}]}))
elif args[:2] == ['api', 'schema']:
    print(json.dumps({'methods': ['events.subscribe'], 'events': ['pane.agent_status_changed']}))
elif args[:2] == ['agent', 'get']:
    print(json.dumps({'result': {'agent': {'agent_status': 'idle'}}}))
elif args[:2] == ['pane', 'read']:
    print('fixture pane', time.monotonic_ns())
else:
    sys.exit(1)
''')
        cli.chmod(0o755)
        reader = home / 'reader.py'
        reader.write_text('''import os, signal, sys, time
from pathlib import Path
home = Path(os.environ['FM_EVENT_TEST_HOME'])
if os.environ['FM_EVENT_TEST_ACTION'] == 'interrupt-resistant':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
(home / 'reader.pid').write_text(str(os.getpid()))
(home / 'wait-owner.pid').write_text(str(os.getppid()))
assert sys.argv[2] == '300', sys.argv
mode = os.environ['FM_EVENT_TEST_ACTION']
if mode == 'subscribe-interrupt':
    time.sleep(300)
print('@subscribed', flush=True)
if mode == 'blocked':
    print('w:p\\t\\tblocked\\tclaude', flush=True)
elif mode == 'quiet':
    time.sleep(.1)
elif mode == 'error':
    sys.exit(4)
else:
    time.sleep(300)
''')
        env = os.environ.copy()
        for name in ('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'HERDR_PANE_ID', 'HERDR_SESSION', 'FM_BACKEND_HERDR_EVENTS_FORCE'):
            env.pop(name, None)
        env.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(root), FM_POLL='300', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999',
                   FM_SIGNAL_GRACE='1', FM_EVENT_TEST_HOME=str(home), FM_EVENT_TEST_ACTION=action,
                   FM_BACKEND_HERDR_BIN=str(cli), FM_BACKEND_HERDR_CLIENT_SESSION='lab',
                   FM_BACKEND_HERDR_EVENT_READER=f'{sys.executable} {reader}',
                   PATH=str(home / 'fakebin') + os.pathsep + env['PATH'], TMPDIR=str(home / 'temp'))
        if timer == 'perl':
            env['BASH_FUNC_command%%'] = '() { case "$*" in "-v timeout"|"-v gtimeout") return 1;; esac; builtin command "$@"; }'
        sentinel = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)'], start_new_session=True)
        session_code = "import os,sys,time; from pathlib import Path; Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(300)"
        checkpoint = subprocess.Popen(['bash', '-c',
                                       '"$1" -c "$2" "$3" >/dev/null 2>&1 & exec "$4" --seconds "$5"',
                                       '_', sys.executable, session_code, str(home / 'session.pid'),
                                       str(root / 'bin/fm-watch-checkpoint.sh'), '30' if 'interrupt' in action else '4'],
                                      env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        owned = []
        try:
            limit = time.monotonic() + 3.5
            while time.monotonic() < limit and not (home / 'reader.pid').exists():
                time.sleep(.02)
            assert (home / 'reader.pid').exists(), 'watcher did not reach the isolated reader'
            reader_pid = int((home / 'reader.pid').read_text())
            owner_pid = int((home / 'wait-owner.pid').read_text())
            watcher_pid = int((home / 'state/.watch.lock/pid').read_text())
            owned = [reader_pid, owner_pid, watcher_pid]
            session_pid = int((home / 'session.pid').read_text())
            assert os.getpgid(session_pid) == checkpoint.pid, 'session control is outside the checkpoint group'
            if 'interrupt' in action:
                checkpoint.send_signal(signal.SIGTERM)
            out, err = checkpoint.communicate(timeout=6)
            expected = 143 if 'interrupt' in action else (0 if action == 'blocked' else 124)
            assert checkpoint.returncode == expected, (checkpoint.returncode, out, err)
            assert all(gone(pid) for pid in owned), f'event-wait processes survived: {owned}'
            assert not (home / 'state/.watch.lock/pid').exists(), 'watcher singleton survived'
            assert not list((home / 'temp').glob('fm-herdr-eventwait.*')), 'reader FIFO survived'
            assert not list((home / 'state').glob('.fm-check-output.*')), 'capture output survived'
            assert sentinel.poll() is None, 'unrelated detached process was signalled'
            assert not gone(session_pid), 'native session process was signalled'
            if action == 'blocked':
                assert b'stale:' in out, (out, err)
            print(f'ok - {timer} backend {action}: reader reaped, owned state cleaned, session and detached processes preserved', flush=True)
        except Exception as exc:
            failures.append(f'{timer}/{action}: {exc}')
            print(f'not ok - {failures[-1]}', flush=True)
        finally:
            for pid in owned:
                if not gone(pid):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            try:
                os.killpg(checkpoint.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            checkpoint.communicate()
            sentinel.kill()
            sentinel.wait()

print('native Herdr qualification unavailable: isolated executable fixtures only', flush=True)
if failures:
    raise SystemExit(1)
