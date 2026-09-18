#!/usr/bin/env python3
"""Single-host paired restart supervisor; this process never initializes MPI."""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

from checkpoint_store import CheckpointStore, RunLock
from external_episode_manager import EpisodeJob, publish, validate_training

DEFAULTS = dict(environments=2, ranks=16, threads=8, steps=8192,
                max_periods=10.0, seed=20260908, checkpoint_minutes=30.0,
                keep_checkpoints=2, bin_paths=[], library_paths=[])
REQUIRED = {"source", "build", "python", "environment_script"}


def load_config(path):
    data = json.loads(Path(path).read_text())
    if not isinstance(data, dict) or set(data) - (set(DEFAULTS) | REQUIRED | {"settings"}):
        raise ValueError("unknown run configuration key; do not store credentials or shell environment")
    if REQUIRED - set(data):
        raise ValueError(f"missing configuration: {sorted(REQUIRED - set(data))}")
    cfg = {**DEFAULTS, **data}
    for key in ("environments", "ranks", "threads", "steps", "seed", "keep_checkpoints"):
        if type(cfg[key]) is not int or cfg[key] < 1:
            raise ValueError(f"{key} must be a positive integer")
    if cfg["environments"] * cfg["ranks"] > 32 or cfg["keep_checkpoints"] < 2:
        raise ValueError("total CFD ranks must not exceed 32; retain at least two checkpoints")
    for key in ("max_periods", "checkpoint_minutes"):
        if type(cfg[key]) not in (int, float) or not math.isfinite(cfg[key]) or cfg[key] <= 0:
            raise ValueError(f"{key} must be finite and positive")
    for key in REQUIRED | ({"settings"} if "settings" in cfg else set()):
        if not isinstance(cfg[key], str) or not cfg[key].startswith("/") or "\n" in cfg[key]:
            raise ValueError(f"{key} must be an absolute Linux path")
    for key in ("bin_paths", "library_paths"):
        if not isinstance(cfg[key], list) or any(not isinstance(x, str) or not x.startswith("/") or ":" in x for x in cfg[key]):
            raise ValueError(f"{key} must be a list of absolute paths")
    return cfg


def read_proxy(path):
    fields = Path(path).read_text().split()
    if len(fields) != 5 or fields[0] != "1":
        raise ValueError("invalid proxy state")
    episode, sequence, kind, action = int(fields[1]), int(fields[2]), fields[3], float(fields[4])
    if episode < 1 or sequence < 0 or kind not in {"A", "N"} or not math.isfinite(action) or abs(action)>1:
        raise ValueError("invalid proxy state values")
    if (kind == "A" and sequence == 0) or (kind == "N" and sequence != 0):
        raise ValueError("invalid proxy pending boundary")
    return dict(episode=episode, sequence=sequence, kind=kind, action=action)


def snapshot_members(staging, environments, ranks):
    staging = Path(staging)
    required = ["learner/learner.native", "learner/learner.meta"]
    required += [f"config/{name}" for name in ("input2d", "eel2d.vertex", "task.conf", "settings.json")]
    states = {}
    for i in range(1, environments + 1):
        slot = f"env_{i}"
        state = states[slot] = read_proxy(staging / slot / "proxy.state")
        required += [f"{slot}/agent.state", f"{slot}/proxy.state"]
        if state["kind"] == "A":
            cfd = staging / slot / "cfd"
            fields = (cfd / "environment.state").read_text().split()
            if len(fields)!=7 or fields[0]!="1" or int(fields[1])<0:
                raise ValueError("invalid CFD restart descriptor")
            if any(not math.isfinite(float(value)) for value in fields[2:]) or float(fields[2])<0:
                raise ValueError("invalid CFD restart time/history")
            adapter=(cfd/"adapter.state").read_text().split()
            if len(adapter)!=30 or adapter[0]!="1" or int(adapter[2])+1!=state["sequence"] or int(adapter[3])!=state["sequence"]:
                raise ValueError("CFD/proxy checkpoint sequence mismatch")
            if int(adapter[2])<0 or int(adapter[5])<0 or any(not math.isfinite(float(x)) for x in adapter[1:]):
                raise ValueError("invalid CFD adapter values")
            step = int(fields[1])
            required += [f"{slot}/cfd/environment.state", f"{slot}/cfd/adapter.state"]
            required += [f"{slot}/cfd/samrai/restore.{step:06d}/nodes.{ranks:05d}/proc.{rank:05d}"
                         for rank in range(ranks)]
    for member in required:
        path = staging / member
        if path.is_symlink() or not path.is_file() or path.stat().st_size==0:
            raise ValueError(f"missing or empty snapshot member: {member}")
    return required, states


def new_session(run):
    sessions = Path(run) / "sessions"
    sessions.mkdir(exist_ok=True)
    numbers = [int(p.name.split("-")[1]) for p in sessions.iterdir()
               if p.name.startswith("session-") and p.name.split("-")[1].isdigit()]
    session = sessions / f"session-{max(numbers, default=0)+1:06d}"
    session.mkdir(mode=0o700)
    return session


def assert_no_live_jobs(run):
    # flock dies with a killed supervisor, but its independent MPI sessions
    # can survive. Refuse a second launch; never kill an unverified stale PID.
    for pidfile in (Path(run)/"sessions").glob("session-*/**/launcher.pid"):
        try:
            pid=int(pidfile.read_text().strip())
            if pid<=0: raise ValueError("nonpositive launcher PID")
            cwd=os.readlink(f"/proc/{pid}/cwd")
        except FileNotFoundError:
            continue
        if Path(cwd).resolve()==pidfile.parent.resolve():
            raise RuntimeError(f"previous MPI launcher still alive: pid={pid}, directory={pidfile.parent}; stop it before resume")


def learner_command(cfg, session):
    return ["mpiexec", "--bind-to", "none", "-n", str(1+cfg["environments"]),
            str(Path(cfg["build"]) / "couplings/ibamr/ibamr_eel2d_smoke"),
            "--nMasters", "1", "--nThreads", str(cfg["threads"]),
            "--nEnvironments", str(cfg["environments"]), "--workerProcessesPerEnv", "1",
            "--learnersOnWorkers", "0", "--nTrainSteps", str(cfg["steps"]),
            "--nTrainUpdates", "0", "--logAllSamples", "0", "--setupFolder", ".",
            "--restart", "none",
            "--eel-mode", "near-wall", "--learnerAuditDir", str(session / "learner-audit")]


def text(path):
    try: return Path(path).read_text().strip()
    except FileNotFoundError: return ""


class PairedRun:
    def __init__(self, run, cfg, restore=None):
        self.run, self.cfg, self.restore = Path(run), cfg, restore
        self.session = new_session(self.run)
        self.control = self.session / "control"
        self.control.mkdir()
        self.slots = [self.session / f"env_{i}" for i in range(1, cfg["environments"]+1)]
        for slot in self.slots: slot.mkdir()
        self.store = CheckpointStore(run, cfg["keep_checkpoints"])
        self.learner = EpisodeJob(self.session)
        self.active, self.counters = {}, {slot:0 for slot in self.slots}
        self.restored = {}
        if restore:
            for slot in self.slots:
                state = read_proxy(restore / slot.name / "proxy.state")
                self.restored[slot] = state
                self.counters[slot] = state["episode"]-1
        self.env = os.environ.copy()
        # Never inherit paired markers from a surrounding unrelated launch.
        for key in ("SMARTIES_PAIRED_RESTORE", "EEL_PAIRED_RESTORE", "EEL_CFD_RESTORE"):
            self.env.pop(key, None)
        self.env.update(EEL_EXTERNAL_ROOT=str(self.session), SMARTIES_PAIRED_CONTROL=str(self.control),
                        OMP_NUM_THREADS=str(cfg["threads"]), OMP_DYNAMIC="FALSE", OPENBLAS_NUM_THREADS="1")
        self.env["PATH"] = os.pathsep.join(cfg["bin_paths"]+[self.env.get("PATH", "")])
        self.env["LD_LIBRARY_PATH"] = os.pathsep.join(cfg["library_paths"]+
            [str(Path(cfg["build"])/"lib"), self.env.get("LD_LIBRARY_PATH", "")])
        if restore:
            self.env.update(SMARTIES_PAIRED_RESTORE=str(restore/"learner"), EEL_PAIRED_RESTORE=str(restore))
        self.stop_requested = False
        self.save_stop_failed = False
        self.stage = None
        self.last_checkpoint = time.monotonic()
        self.required_bytes = 64*1024*1024
        if restore:
            inventory=json.loads((restore/"manifest.json").read_text())["inventory"]
            self.required_bytes=max(self.required_bytes, int(sum(inventory.values())*1.25)+16*1024*1024)
        self.last_notice = 0.0
        for name in ("input2d", "eel2d.vertex", "task.conf", "settings.json"):
            source=(restore/"config" if restore else self.run)/name
            shutil.copy2(source, self.session/name)

    def log(self, message):
        print(time.strftime("%Y-%m-%d %H:%M:%S"), message, flush=True)

    def launch_requests(self, allow_new=True):
        for slot in self.slots:
            previous = self.active.get(slot)
            if previous is not None:
                code = previous.poll()
                if code is None: continue
                if code: raise RuntimeError(f"CFD failed: {previous.directory} (exit {code})")
            if not allow_new: continue
            request = text(slot/"request")
            if not request: continue
            episode = int(request)
            if episode == self.counters[slot]: continue
            if episode != self.counters[slot]+1: raise RuntimeError("out-of-order episode request")
            if self.stage:
                publish(slot/"park.next", episode)
                continue
            directory = slot/f"episode_{episode}"
            directory.mkdir(mode=0o700)
            for name in ("input2d", "eel2d.vertex", "task.conf"):
                shutil.copy2(self.session/name, directory/name)
            env=self.env.copy()
            env["OMP_NUM_THREADS"]="1"
            env.pop("EEL_KEEP_VIZ", None)
            state=self.restored.get(slot)
            if state and state["kind"]=="A" and episode==state["episode"]:
                env["EEL_CFD_RESTORE"]=str(self.restore/slot.name/"cfd")
            elif episode==1:
                env["EEL_KEEP_VIZ"]="1"
            job=EpisodeJob(directory)
            seed=self.cfg["seed"]+int(slot.name.split("_")[1])*100000+episode
            command=["mpiexec", "--bind-to", "none", "-n", str(self.cfg["ranks"]),
                     str(Path(self.cfg["build"])/"couplings/ibamr/eel_near_wall_episode"),
                     "--input-file", "input2d", "--task-file", "task.conf", "--wall-seed", str(seed),
                     "--wall-max-periods", str(self.cfg["max_periods"])]
            job.start(command, env)
            self.active[slot]=job
            self.counters[slot]=episode
            self.log(f"started {slot.name} episode={episode} ranks={self.cfg['ranks']}")

    def release_restore(self):
        if not self.restore: return True
        if text(self.control/"learner.restored")!=str(self.restore/"learner"): return False
        for slot,state in self.restored.items():
            if text(slot/"resume.ready")!=str(self.restore/slot.name): return False
            if state["kind"]=="A":
                job=self.active.get(slot)
                if job is None or text(job.directory/"resume.ready")!=str(self.restore/slot.name/"cfd"): return False
        publish(self.session/"resume.release", self.restore)
        self.log(f"all restored participants ready; releasing {self.restore.name}")
        return True

    def begin_checkpoint(self):
        try: stage=self.store.begin(self.required_bytes)
        except OSError as error:
            self.last_checkpoint=time.monotonic()
            self.log(f"checkpoint not started; old snapshots retained: {error}")
            if self.stop_requested: raise RuntimeError("save-and-stop failed: cannot allocate checkpoint") from error
            return
        (stage/"learner").mkdir()
        (stage/"config").mkdir()
        for name in ("input2d", "eel2d.vertex", "task.conf", "settings.json"):
            shutil.copy2(self.session/name, stage/"config"/name)
        for slot in self.slots:
            (stage/slot.name).mkdir()
            (stage/slot.name/"cfd").mkdir()
            publish(slot/"checkpoint.request", stage/slot.name)
        self.stage=stage
        self.log(f"checkpoint requested: {stage.name}; waiting for action boundaries")

    def advance_checkpoint(self):
        stage=self.stage
        if not stage: return False
        for slot in self.slots:
            dest=stage/slot.name
            if text(slot/"proxy.ready")!=str(dest): return False
            state=read_proxy(dest/"proxy.state")
            if state["kind"]=="A":
                job=self.active.get(slot)
                if job is None or job.directory.name!=f"episode_{state['episode']}":
                    raise RuntimeError("proxy checkpoint does not match active CFD episode")
                if text(job.directory/"checkpoint.request")!=str(dest/"cfd"):
                    publish(job.directory/"checkpoint.request", dest/"cfd")
                if text(job.directory/"cfd.ready")!=str(dest/"cfd"): return False
        request=self.control/"learner.request"
        if text(request)!=str(stage/"learner"): publish(request, stage/"learner")
        error=text(self.control/"learner.error")
        if error: raise RuntimeError(f"learner checkpoint failed: {error}")
        if text(self.control/"learner.ready")!=str(stage/"learner"): return False
        required,states=snapshot_members(stage,self.cfg["environments"],self.cfg["ranks"])
        meta=dict(configuration=self.cfg, environments=states,
                  learner=json.loads((stage/"learner/learner.meta").read_text()),
                  session=self.session.name)
        try:
            snapshot=self.store.publish(stage, meta, required)
        except OSError as error:
            # All owners are still safely paused. A storage error does not
            # invalidate their live state or justify discarding old snapshots.
            self.log(f"checkpoint publication failed; no new recovery point confirmed: {error}")
            self.save_stop_failed=self.stop_requested
            return self.release_checkpoint()
        size=sum(v for v in json.loads((snapshot/"manifest.json").read_text())["inventory"].values())
        self.required_bytes=max(64*1024*1024,int(size*1.25)+16*1024*1024)
        try: removed=self.store.prune()
        except (OSError,ValueError) as error:
            # A valid new snapshot remains usable; unknown user files are never deleted.
            self.log(f"checkpoint published but retention skipped: {error}")
            removed=[]
        self.log(f"checkpoint published: {snapshot} bytes={size} removed={[p.name for p in removed]}")
        return self.release_checkpoint()

    def release_checkpoint(self):
        stage=self.stage
        if self.stop_requested: publish(self.control/"learner.stop", "stop")
        (self.control/"learner.request").unlink()
        for slot in self.slots:
            publish(slot/"checkpoint.release", str(stage/slot.name)+"\n"+("STOP" if self.stop_requested else "CONTINUE"))
        self.stage=None
        self.last_checkpoint=time.monotonic()
        return self.stop_requested

    def execute(self):
        result=1
        old_handlers={}
        def stop(signum,frame):
            self.stop_requested=True
            self.log("save-and-stop requested; waiting for current control intervals")
        for sig in (signal.SIGINT,signal.SIGTERM):
            old_handlers[sig]=signal.signal(sig,stop)
        try:
            self.learner.start(learner_command(self.cfg,self.session),self.env)
            resumed=self.restore is None
            stopping=False
            while self.learner.poll() is None:
                self.stop_requested |= (self.run/"stop.request").exists()
                self.launch_requests(allow_new=not stopping)
                if not resumed: resumed=self.release_restore()
                if resumed and not stopping:
                    if not self.stage and (self.stop_requested or
                        time.monotonic()-self.last_checkpoint>=60*self.cfg["checkpoint_minutes"]):
                        self.begin_checkpoint()
                    stopping=self.advance_checkpoint()
                if self.stage and time.monotonic()-self.last_notice>60:
                    ready=[slot.name for slot in self.slots if text(slot/"proxy.ready")==str(self.stage/slot.name)]
                    self.log(f"checkpoint waiting; parked proxies={ready}")
                    self.last_notice=time.monotonic()
                time.sleep(.02)
            learner_result=self.learner.poll()
            # Normal learner exit follows all proxy callbacks, which await CFD exit.status.
            for job in self.active.values():
                if job.poll() is None: raise RuntimeError("learner exited with live CFD job")
                if job.poll()!=0: raise RuntimeError("CFD job exited abnormally")
            result=learner_result or int(self.save_stop_failed)
            if result==0 and not stopping:
                publish(self.run/"completed", self.session.name)
                self.log("training budget completed normally")
            elif result==0:
                self.log("paired checkpoint saved; all MPI jobs exited normally")
            return result
        finally:
            for job in [*self.active.values(),self.learner]:
                if job.process is not None: job.stop()
            publish(self.session/"manager.exit.status",result)
            for sig,handler in old_handlers.items(): signal.signal(sig,handler)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("action",choices=("start","resume","stop"))
    p.add_argument("--run",type=Path,required=True)
    p.add_argument("--config",type=Path)
    p.add_argument("--checkpoint",choices=("latest","previous"),default="latest")
    p.add_argument("--checkpoint-minutes",type=float)
    p.add_argument("--keep-checkpoints",type=int)
    args=p.parse_args(argv)
    if not args.run.is_absolute() or args.run.is_symlink(): p.error("run must be an absolute, non-symlink path")
    run=args.run.resolve()
    if args.action=="start":
        if run.exists(): raise FileExistsError(f"start refuses existing run directory: {run}")
        if not args.config: p.error("start requires --config")
        cfg=load_config(args.config)
        for name in ("checkpoint_minutes","keep_checkpoints"):
            if getattr(args,name) is not None: cfg[name]=getattr(args,name)
        if not math.isfinite(cfg["checkpoint_minutes"]) or cfg["checkpoint_minutes"]<=0 or cfg["keep_checkpoints"]<2:
            p.error("positive checkpoint interval and at least two retained checkpoints required")
        subprocess.run([sys.executable,str(Path(cfg["source"])/"couplings/ibamr/scripts/prepare_near_wall_run.py"),
                        cfg["source"],str(run)],check=True)
        if cfg.get("settings"): shutil.copy2(cfg["settings"],run/"settings.json")
        publish(run/"run-config.json",json.dumps(cfg,indent=2))
    else:
        if args.config or args.checkpoint_minutes is not None or args.keep_checkpoints is not None:
            p.error("resume/stop use the saved configuration without overrides")
        cfg=load_config(run/"run-config.json")
    if args.action=="stop":
        try:
            with RunLock(run): pass
        except BlockingIOError:
            publish(run/"stop.request","save-and-stop")
            print(f"已请求保存后停止：{run}",flush=True)
            return 0
        raise RuntimeError("no running supervisor holds this directory; nothing was signalled")
    with RunLock(run):
        assert_no_live_jobs(run)
        if (run/"completed").exists():
            print("原训练预算已完成；没有启动新的训练。")
            return 0
        restore=None
        if args.action=="resume":
            restore=CheckpointStore(run,cfg["keep_checkpoints"]).select(args.checkpoint)
            descriptor=json.loads((restore/"manifest.json").read_text())
            if descriptor["metadata"]["configuration"]!=cfg:
                raise ValueError("run configuration changed since checkpoint; restore refused")
            snapshot_members(restore,cfg["environments"],cfg["ranks"])
        settings=(restore/"config/settings.json") if restore else run/"settings.json"
        validate_training(json.loads(settings.read_text()),cfg["threads"])
        (run/"stop.request").unlink(missing_ok=True)
        manager=PairedRun(run,cfg,restore)
        print(f"运行目录：{run}\n当前输出：{manager.session}",flush=True)
        return manager.execute()


if __name__=="__main__":
    try: raise SystemExit(main())
    except Exception as error:
        print(f"paired run failed: {error}",file=sys.stderr,flush=True)
        raise SystemExit(1)
