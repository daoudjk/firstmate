import json, os, pathlib, subprocess, tempfile
root=pathlib.Path.cwd()
evidence=pathlib.Path(__file__).parent
with tempfile.TemporaryDirectory(prefix='.test-voice-backend-',dir=root) as temp:
    home=pathlib.Path(temp)
    for name in ('data','state','config','fakebin'):
        (home/name).mkdir()
    (home/'.tasks.toml').write_text('backend = "beads"\n')
    (home/'data/backlog.md').write_text('## In flight\n- [ ] obsolete - STALE_MARKDOWN_TASK (kind: captain)\n')
    (home/'state/live.meta').write_text('pr=https://github.com/daoudjk/firstmate/pull/123\n')
    listing='tasks[2]{id,state,kind,repo,title,hold_kind,hold_reason,hold_until,priority,links}:\n  live,in_flight,ship,firstmate,Current backend task,captain,Decide rollout,none,1,none\n  queued,queued,captain,firstmate,Choose release window,none,none,none,2,none\n'
    (home/'listing').write_text(listing)
    stub=home/'fakebin/tasks-axi'
    stub.write_text('#!/usr/bin/env python3\nimport os,pathlib\nprint((pathlib.Path(os.environ["FM_HOME"])/"listing").read_text(),end="")\n')
    stub.chmod(0o755)
    env=dict(os.environ,FM_HOME=str(home),PATH=str(home/'fakebin')+os.pathsep+os.environ['PATH'])
    for key in ('FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(key,None)
    transcript=['Non-markdown adapter regression: the external tasks-axi listing is a deterministic protocol fixture. The actual voice CLI, backend addressing, and wrapper execute unchanged. A stale markdown file is deliberately present. No model or forge calls.\n', 'Adapter listing:\n'+listing]
    args=['status','--home',str(home),'--scope','full']
    old=subprocess.check_output(['git','show','a0f8bc8:bin/fm_voice_records.py'],text=True)
    baseline=subprocess.run(['python3','-c',f'exec(compile({old!r}, {str(root/"bin/fm_voice_records.py")!r}, "exec"), dict(__name__="__main__", __file__={str(root/"bin/fm_voice_records.py")!r}))',*args],env=env,capture_output=True,text=True)
    assert baseline.returncode==0,baseline.stderr
    before=json.loads(baseline.stdout)
    assert before['in_flight']==1 and before['queued']==0 and before['open_pull_requests']==0
    assert 'STALE_MARKDOWN_TASK' in baseline.stdout
    transcript.append('Before review fix (executed parent implementation):\n'+baseline.stdout)
    for scope in ('full','counts'):
        command=['python3',str(root/'bin/fm_voice_records.py'),'status','--home',str(home),'--scope',scope]
        result=subprocess.run(command,env=env,capture_output=True,text=True)
        assert result.returncode==0,result.stderr
        answer=json.loads(result.stdout)
        assert (answer['in_flight'],answer['queued'],answer['awaiting_captain'],answer['open_pull_requests'])==(1,1,2,1)
        assert 'STALE_MARKDOWN_TASK' not in result.stdout
        if scope=='counts': assert 'Current backend task' not in result.stdout and 'github.com' not in result.stdout
        transcript.append('$ '+' '.join(command)+'\n'+result.stdout)
    (home/'config/voice-read-deny').write_text('Decide rollout\n')
    result=subprocess.run(['python3',str(root/'bin/fm_voice_records.py'),*args],env=env,capture_output=True,text=True,check=True)
    answer=json.loads(result.stdout)
    assert answer['withheld_as_confidential']==1 and answer['in_flight_detail']==answer['pull_request_detail']==[]
    transcript.append('After denying hold text "Decide rollout":\n'+result.stdout)
    (evidence/'backend-regression-transcript.txt').write_text('\n'.join(transcript))
print('Baseline stale-data failure reproduced; fixed CLI reports configured backend and preserves scope/deny filters.')
