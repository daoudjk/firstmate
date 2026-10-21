#!/usr/bin/env bash
# Opt-in real Codex proof of Stop-owned checkpoints, handled durable wakes,
# foreign-owner refusal, bounded visible failure, and explicit interruption.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_LIVE_E2E codex tmux python3 jq
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1]).resolve()
base = root / '.no-mistakes'
base.mkdir(exist_ok=True)
lab = Path(tempfile.mkdtemp(prefix='codex-continuity-', dir=base))
version = subprocess.check_output(['codex', '--version'], text=True).strip()
processes = []
socket_dir = tempfile.TemporaryDirectory(prefix='fm-codex-socket-')
socket = str(Path(socket_dir.name) / 'tmux.sock')
tmux = shutil.which('tmux')

def require(condition, message):
    if not condition:
        raise AssertionError(f'{version}: {message}; evidence={lab}')

def prepare(name):
    project = lab / name / 'project'
    home = lab / name / 'home'
    (home / 'state').mkdir(parents=True)
    (home / 'config').mkdir()
    history = home / 'state/pending-replies'
    history.mkdir()
    for index in range(1600):
        (history / f'history-{index}').write_text(f'corr_id=history-{index}\ntask_id=retired\nphase=resolved\n')
    subprocess.run(['git', 'clone', '-q', '--shared', str(root), str(project)], check=True)
    # Exercise working-tree changes too, before their implementation commit.
    for path in ('bin/fm-turnend-guard.sh', 'bin/fm-harness.sh', 'bin/fm-watch-checkpoint.sh', 'bin/fm-watch.sh', 'bin/fm-pending-reply-lib.sh', 'bin/fm-supervision-instructions.sh', 'docs/supervision-protocols/codex.md', '.codex/hooks.json'):
        shutil.copy2(root / path, project / path)
    (project / 'AGENTS.md').write_text('This is an isolated lifecycle test fixture. Follow the explicit diagnostic prompt. Never operate on another home.\n')
    (project / 'probe.py').write_text('''import json,os,time
p=json.load(__import__('sys').stdin)
x={k:p.get(k) for k in ('hook_event_name','tool_name','stop_hook_active')}
x['owner']=os.getppid();x['time']=time.time()
with open('hooks.jsonl','a') as f:f.write(json.dumps(x)+'\\n')
''')
    hooks = json.loads((project / '.codex/hooks.json').read_text())
    for event in ('PreToolUse', 'Stop'):
        hooks['hooks'][event].insert(0, {'hooks': [{'type': 'command', 'command': 'python3 probe.py'}]})
    (project / '.codex/hooks.json').write_text(json.dumps(hooks))
    # Count quiet returns observationally, after the real checkpoint finishes.
    checkpoint = project / 'bin/fm-watch-checkpoint.sh'
    text = checkpoint.read_text()
    text = text.replace('if [ "$RC" -eq 124 ]; then', 'if [ "$RC" -eq 124 ]; then\n  printf \'%s\\n\' "$$" >> "$FM_HOME/quiet-checkpoints"')
    checkpoint.write_text(text)
    # Observe the real native SessionStart caller's verdict, without changing it.
    start = project / 'bin/fm-session-start.sh'
    text = start.read_text()
    needle = 'PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)'
    start.write_text(text.replace(needle, needle + '\nprintf \'%s\\n\' "$PRIMARY_HARNESS" > "$FM_HOME/startup-harness"\n'))
    env = os.environ.copy()
    for key in ('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_CODE_SESSION_ID', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'CODEX_THREAD_ID', 'NO_MISTAKES_GATE'):
        env.pop(key, None)
    env.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(project), FM_POLL='1', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_SIGNAL_GRACE='1', FM_CODEX_WATCH_CHECKPOINT='12', TMUX=socket + ',0,0')
    return project, home, env

def launch(project, env, prompt, filename):
    output = (project.parent / filename).open('w')
    process = subprocess.Popen(['codex', 'exec', '--dangerously-bypass-hook-trust', '--dangerously-bypass-approvals-and-sandbox', '--skip-git-repo-check', '-c', 'model_reasoning_effort="low"', '--json', prompt], cwd=project, env=env, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    processes.append(process)
    output.close()
    return process

def records(project):
    file = project / 'hooks.jsonl'
    return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

def stops(project):
    return [item for item in records(project) if item['hook_event_name'] == 'Stop']

def watcher(home):
    lock = home / 'state/.watch.lock'
    try:
        if (lock / 'fm-home').read_text().strip() == str(home):
            return int((lock / 'pid').read_text())
    except (FileNotFoundError, ValueError):
        pass
    return None

def watcher_alive(home):
    pid = watcher(home)
    if pid is None:
        return False
    try:
        stat = Path(f'/proc/{pid}/stat')
        if stat.exists():
            text = stat.read_text()
            if text[text.rfind(')') + 2:].split()[0] == 'Z':
                return False
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, FileNotFoundError):
        return False

prompt = '''You are a disposable lifecycle test driver. Initially run bin/fm-lock.sh and bin/fm-harness.sh, create empty "$FM_HOME/state/probe.meta", then attempt final answer STOP_REQUEST. Do not run a watcher yourself: the trusted Stop hook owns it. On each Stop continuation, run bin/fm-wake-drain.sh, handle every event, and execute its exact WAKE_ACK_REQUIRED command. For a quiet interval or recovery check, acknowledge and attempt STOP_REQUEST again. If a stale: event is presented, write STALE_HANDLED into "$FM_HOME/stale-handled", acknowledge it, then attempt STOP_REQUEST. If a status says done: LAB_TASK_COMPLETE, acknowledge it FIRST, remove ONLY "$FM_HOME/state/probe.meta", write DONE_HANDLED into "$FM_HOME/done-handled", then answer DONE_HANDLED. Never remove metadata before that status. If a hook reports FIRSTMATE CODEX SUPERVISION STOPPED, report the failure explicitly and end without retrying. Never launch another supervisor, use background tools, edit hooks/config, or inspect other homes.'''
try:
    subprocess.run([tmux, '-S', socket, 'new-session', '-d', '-s', 'fm-lab-worker', 'bash --noprofile --norc'], check=True)
    project, home, env = prepare('continuity')
    env['FM_CODEX_WATCH_CHECKPOINT'] = '5'
    process = launch(project, env, prompt, 'transcript.jsonl')
    phase = 0
    foreign = None
    owner = None
    queued = False
    while process.poll() is None:
        queued |= (home / 'state/.wake-queue').exists() and (home / 'state/.wake-queue').stat().st_size > 0
        quiet_file = home / 'quiet-checkpoints'
        quiet_count = len(quiet_file.read_text().splitlines()) if quiet_file.exists() else 0
        if phase == 0 and quiet_count >= 12 and len(stops(project)) >= 13:
            owner = (home / 'state/.lock').read_text()
            foreign = launch(project, env, 'Run bin/fm-lock.sh. If it refuses, answer LOCK_REFUSED and do nothing else. Do not modify state or run a watcher.', 'foreign.jsonl')
            (home / 'state/probe.meta').write_text(f'window=fm-lab-worker:0\nharness=codex\nproject={project}\nworktree={project}\n')
            (home / 'state/probe.status').write_text('working: lab idle endpoint\n')
            phase = 1
        if phase == 1 and (home / 'stale-handled').exists():
            with (home / 'state/probe.status').open('a') as output:
                output.write('done: LAB_TASK_COMPLETE\n')
            (home / 'state/probe.turn-ended').touch()
            phase = 2
        time.sleep(0.1)
    require(process.returncode == 0 and phase == 2 and (home / 'done-handled').exists(), 'turn ended before stale and terminal wakes were handled')
    require(queued and not (home / 'state/.wake-queue').read_text().strip(), 'wake was not durably queued and explicitly acknowledged')
    require(not watcher(home), 'watcher leaked after the fleet became empty')
    require(len(list((home / 'state/pending-replies').iterdir())) == 1600, 'retained reply history was discarded')
    require((home / 'startup-harness').read_text().strip() == 'codex', 'native SessionStart lost its harness beyond eight ancestry hops')
    require(foreign is not None and foreign.wait() == 0, 'foreign live session did not stand down')
    require((home / 'state/.lock').read_text() == owner, 'foreign session replaced the live owner')
    require('LOCK_REFUSED' in (project.parent / 'foreign.jsonl').read_text(), 'competing real Codex session did not observe lock refusal')
    print(f'ok - {version}: at least twelve quiet native Stop checkpoints preceded handled stale and completion wakes, drained and acknowledged the durable queue, and preserved the live owner', flush=True)

    project, home, env = prepare('failure')
    process = launch(project, env, prompt, 'transcript.jsonl')
    injected = False
    while process.poll() is None:
        pid = watcher(home)
        if not injected and len(stops(project)) >= 3 and pid:
            # Exact owned disposable watcher only; no worker or shared daemon.
            os.kill(pid, signal.SIGTERM)
            injected = True
        time.sleep(0.1)
    transcript = (project.parent / 'transcript.jsonl').read_text()
    messages = '\n'.join(json.loads(line).get('item', {}).get('text', '') for line in transcript.splitlines() if line.startswith('{'))
    require(injected and process.returncode == 0, 'failed watcher did not reach a bounded attended exit')
    require('supervision' in messages.lower() and ('stopped' in messages.lower() or 'unavailable' in messages.lower()), 'actual model never reported the failed watcher')
    require((home / 'state/probe.meta').exists() and not watcher(home), 'failure discarded the task or leaked a watcher')
    require(len(stops(project)) == 4, 'failure notification was silent or repeated without a bound')
    print(f'ok - {version}: a watcher failure after prior Stop continuations produced one explicit failure turn and a bounded exit', flush=True)

    project, home, env = prepare('interrupt')
    env['FM_CODEX_WATCH_CHECKPOINT'] = '180'
    process = launch(project, env, prompt, 'transcript.jsonl')
    interrupted = False
    while process.poll() is None:
        if watcher(home):
            os.killpg(process.pid, signal.SIGINT)
            interrupted = True
            break
        time.sleep(0.1)
    process.wait()
    # Process exit and the watcher's EXIT cleanup can race by one scheduler turn.
    for _ in range(50):
        if not watcher_alive(home):
            break
        time.sleep(0.1)
    require(interrupted and len(stops(project)) == 1, 'explicit interruption started another Stop continuation')
    require((home / 'state/probe.meta').exists() and not watcher_alive(home), 'interrupt discarded a task or left a watcher')
    print(f'ok - {version}: explicit interrupt ended the Stop wait without reentry or task loss', flush=True)
    print(f'# evidence retained at {lab}', flush=True)
finally:
    for process in processes:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGINT)
            process.wait()
    subprocess.run([tmux, '-S', socket, 'kill-session', '-t', 'fm-lab-worker'], capture_output=True)
    socket_dir.cleanup()
PY
