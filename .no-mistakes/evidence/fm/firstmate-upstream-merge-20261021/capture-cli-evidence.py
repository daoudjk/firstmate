import json, os, pathlib, shutil, subprocess, tempfile
root=pathlib.Path.cwd()
evidence=pathlib.Path(__file__).parent
with tempfile.TemporaryDirectory(prefix=".test-merge-cli-", dir=root) as tmp:
    home=pathlib.Path(tmp)
    for name in ("data", "state", "config", "bin"):
        (home/name).mkdir()
    env=dict(os.environ, FM_HOME=str(home))
    for key in ("FM_DATA_OVERRIDE", "FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE", "TASKS_AXI_BACKEND", "TASKS_AXI_FILE", "FM_ROOT_OVERRIDE"):
        env.pop(key, None)
    transcript=[]
    def run(args, **kw):
        result=subprocess.run(args,env=env,capture_output=True,text=True,**kw)
        transcript.append("$ "+" ".join(str(x) for x in args)+"\n"+result.stdout+result.stderr+f"[exit {result.returncode}]\n")
        assert result.returncode==0, transcript[-1]
        return result.stdout
    # Public status output backed by a real markdown backlog.
    (home/".tasks.toml").write_text('backend = "markdown"\n')
    (home/"data/backlog.md").write_text("## In flight\n- [ ] merge-sync - Preserve fork behavior (repo: firstmate) (kind: ship)\n## Queued\n- [ ] review-choice - Decide the rollout (kind: captain)\n## Done\n- [x] retired - PRIVATE_FINISHED_WORK (kind: captain)\n")
    (home/"state/merge-sync.meta").write_text("kind=ship\npr=https://github.com/daoudjk/firstmate/pull/123\n")
    (home/"state/merge-sync.status").write_text("working: validating merge\n")
    for scope in ("full", "counts"):
        out=run(["python3",str(root/"bin/fm_voice_records.py"),"status","--home",str(home),"--scope",scope])
        answer=json.loads(out)
        assert (answer["in_flight"],answer["queued"],answer["awaiting_captain"],answer["open_pull_requests"])==(1,1,1,1)
        assert "PRIVATE_FINISHED_WORK" not in out
        if scope=="counts": assert "Preserve fork" not in out and "github.com" not in out
    # Preserve the actual emitted worker-facing delivery contract as evidence.
    run(["bash",str(root/"bin/fm-brief.sh"),"merge-proof","renamed-project","--mode","no-mistakes","--delivery-repo","daoudjk/firstmate"])
    shutil.copy2(home/"data/merge-proof/brief.md",evidence/"generated-delivery-brief.md")
    # Run real Stop hooks in an isolated primary with real watchers, no model.
    run(["git","init","-q",str(home)])
    (home/"AGENTS.md").write_text("")
    for source in (root/"bin").glob("*.sh"):
        shutil.copy2(source,home/"bin"/source.name)
    shutil.copytree(root/"bin/backends",home/"bin/backends")
    shutil.copy2(shutil.which("bash"),home/"codex")
    env.update(FM_GATE_REFUSE_BYPASS="1",FM_TEST_SEAM="1",FM_ROOT_OVERRIDE=str(home),FM_CODEX_WATCH_CHECKPOINT="1",FM_POLL="1",FM_SIGNAL_GRACE="1",FM_CHECK_INTERVAL="999999",FM_HEARTBEAT="999999")
    for key in ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID"):
        env.pop(key,None)
    for host in (False,True):
        if host: (home/"config/supervision-host").write_text("")
        transcript.append("Real Stop hooks; supervision host enabled="+str(host)+"\n")
        out=run([str(home/"codex"),"-c", r'''printf '%s\n' "$$" > "$FM_HOME/state/.lock"
for active in false true true; do
  printf '{"stop_hook_active":%s}' "$active" | "$FM_HOME/bin/fm-turnend-guard.sh" --codex
  printf 'Stop active=%s, continuation exit=%s\n' "$active" "$?"
done'''])
        assert out.count("continuation exit=2")==3, out
        assert not (home/"state/.watch.lock/pid").exists()
        if host:
            transcript.append("Persisted supervision-host event log:\n"+(home/"state/.supervision-host.log").read_text())
    (evidence/"cli-behavior-transcript.txt").write_text("Fixture-only demonstration. PR URL and task records are synthetic; no forge mutations or model calls.\n\n"+"\n".join(transcript))
print("Saved generated-delivery-brief.md and cli-behavior-transcript.txt")
