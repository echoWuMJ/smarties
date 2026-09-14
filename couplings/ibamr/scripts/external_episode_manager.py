#!/usr/bin/env python3
"""Single-host supervisor. Deliberately does not import or initialise MPI."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


def validate_training(settings, threads):
    # Native Smarties uses schedule(static, batchSize_local/nThreads).
    # With the single learner used here, local batch size is the JSON batch.
    batch = settings["batchSize"]
    if not isinstance(batch, int) or batch < threads:
        raise ValueError("batchSize must be at least learner threads (OpenMP chunk must be positive)")
    if settings["minTotObsNum"] < batch:
        raise ValueError("minTotObsNum must be at least batchSize")


def publish(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(str(value) + "\n")
    temporary.replace(path)


class EpisodeJob:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.process = None
        self.log = None
        self.reported = False

    def start(self, command, env=None):
        if self.process is not None and self.process.poll() is None:
            raise RuntimeError("previous episode is still running")
        self.log = (self.directory / "process.log").open("a")
        self.process = subprocess.Popen(command, cwd=self.directory, env=env,
            stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT,
            start_new_session=True)
        self.reported = False
        publish(self.directory / "launcher.pid", self.process.pid)
        return self.process.pid

    def poll(self):
        code = self.process.poll()
        if code is not None and not self.reported:
            self.log.close()
            publish(self.directory / "exit.status", code)
            self.reported = True
        return code

    def wait(self):
        self.process.wait()
        return self.poll()

    def stop(self):
        if self.process is None or self.poll() is not None:
            return
        publish(self.directory / "cancel", "stop")
        # Applied only to an explicitly cancelled/failed run, never as a CFD
        # performance timeout. Signal only the session this supervisor created.
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass  # It exited after poll; wait still reaps the child.
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait()
        self.poll()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--environments", type=int, default=2)
    parser.add_argument("--ranks", type=int, default=16)
    parser.add_argument("--threads", type=int, default=8)
    parser.add_argument("--steps", type=int, default=8192)
    parser.add_argument("--max-periods", type=float, default=10)
    parser.add_argument("--seed", type=int, default=20260908)
    args = parser.parse_args()
    if min(args.environments,args.ranks,args.threads,args.steps) < 1 or args.environments*args.ranks > 32:
        parser.error("positive resources required; total CFD ranks must not exceed 32")
    if not math.isfinite(args.max_periods) or args.max_periods <= 0:
        parser.error("max-periods must be positive")
    run = args.run.resolve()
    validate_training(json.loads((run/"settings.json").read_text()),args.threads)
    binary = args.build.resolve() / "couplings/ibamr"
    slots = [run / f"env_{i}" for i in range(1,args.environments+1)]
    for slot in slots:
        slot.mkdir(mode=0o700)  # Refuse reuse of an existing mailbox/run.
    env = os.environ.copy()
    env["EEL_EXTERNAL_ROOT"] = str(run)
    env["OMP_NUM_THREADS"] = str(args.threads)
    env["OPENBLAS_NUM_THREADS"] = "1"
    learner = EpisodeJob(run)
    active = {}
    counters = {slot: 0 for slot in slots}
    command = ["mpiexec","--bind-to","none","-n",str(1+args.environments),
        str(binary/"ibamr_eel2d_smoke"),"--nMasters","1","--nThreads",str(args.threads),
        "--nEnvironments",str(args.environments),"--workerProcessesPerEnv","1",
        "--learnersOnWorkers","0","--nTrainSteps",str(args.steps),"--nTrainUpdates","0",
        "--logAllSamples","0","--setupFolder",".","--eel-mode","near-wall",
        "--learnerAuditDir",str(run/"learner-audit")]
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    result = 1
    try:
        learner.start(command,env)
        while learner.poll() is None:
            for slot in slots:
                previous = active.get(slot)
                if previous is not None:
                    code = previous.poll()
                    if code is None:
                        continue
                    if code != 0:
                        raise RuntimeError(f"CFD failed: {previous.directory} (exit {code})")
                request = slot/"request"
                if not request.exists():
                    continue
                episode = int(request.read_text().strip())
                if episode == counters[slot]:
                    continue
                if episode != counters[slot]+1:
                    raise RuntimeError("out-of-order episode request")
                directory = slot/f"episode_{episode}"
                directory.mkdir(mode=0o700)
                for filename in ("input2d","eel2d.vertex","task.conf"):
                    shutil.copy2(run/filename,directory/filename)
                cfd_env = env.copy()
                cfd_env["OMP_NUM_THREADS"] = "1"
                cfd_env.pop("EEL_KEEP_VIZ",None)
                if episode == 1:
                    cfd_env["EEL_KEEP_VIZ"] = "1"
                seed = args.seed + int(slot.name.split("_")[1])*100000 + episode
                cfd = EpisodeJob(directory)
                active[slot] = cfd
                cfd.start(["mpiexec","--bind-to","none","-n",str(args.ranks),
                    str(binary/"eel_near_wall_episode"),"--input-file","input2d",
                    "--task-file","task.conf","--wall-seed",str(seed),
                    "--wall-max-periods",str(args.max_periods)],cfd_env)
                counters[slot] = episode
            time.sleep(0.02)
        result = learner.poll()
    finally:
        cleanup_errors = []
        for job in [*active.values(), learner]:
            try:
                job.stop()
            except Exception as error:
                cleanup_errors.append(f"{job.directory}: {error}")
        if cleanup_errors:
            result = result or 1
            publish(run/"cleanup.errors", "\n".join(cleanup_errors))
        publish(run/"manager.exit.status",result)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
