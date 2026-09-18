import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from paired_run import load_config, read_proxy, snapshot_members, new_session, learner_command, PairedRun, assert_no_live_jobs, main
from checkpoint_store import RunLock


class PairedRunTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def config(self, **changes):
        data = dict(source="/source", build="/build", python="/uv/python3.12", environment_script="/env.sh")
        data.update(changes)
        path = self.root / "config.json"
        path.write_text(json.dumps(data))
        return load_config(path)

    def test_simple_defaults_and_unchanged_budget_command(self):
        cfg = self.config(steps=456)
        self.assertEqual((cfg["environments"], cfg["ranks"], cfg["threads"]), (2, 16, 8))
        command = learner_command(cfg, self.root)
        self.assertEqual(command[command.index("--nTrainSteps") + 1], "456")
        self.assertEqual(command[command.index("--restart")+1], "none")  # disable legacy weights-only restore

    def test_reject_unknown_and_overbudget_resources(self):
        for changes in [dict(password="secret"), dict(ranks=24), dict(keep_checkpoints=1),
                        dict(threads=True), dict(checkpoint_minutes=0), dict(max_periods=float("nan"))]:
            with self.assertRaises(ValueError): self.config(**changes)

    def test_sessions_never_reuse_previous_output(self):
        first = new_session(self.root)
        (first / "process.log").write_text("old data")
        second = new_session(self.root)
        self.assertNotEqual(first, second)
        self.assertEqual((first / "process.log").read_text(), "old data")

    def test_proxy_pending_is_next_episode(self):
        path = self.root / "proxy.state"
        path.write_text("1 4 0 N 0\n")
        self.assertEqual(read_proxy(path), dict(episode=4, sequence=0, kind="N", action=0.0))
        for invalid in ["1 4 1 N 0", "1 4 0 A .3", "1 -1 0 N 0", "1 4 1 A nan"]:
            path.write_text(invalid)
            with self.assertRaises(ValueError): read_proxy(path)

    def test_require_all_cfd_rank_members_and_pending_has_no_cfd(self):
        learner = self.root / "learner"
        learner.mkdir()
        (learner / "learner.native").write_bytes(b"native")
        (learner / "learner.meta").write_text("{}")
        (self.root / "config").mkdir()
        for name in ("input2d", "eel2d.vertex", "task.conf", "settings.json"):
            (self.root / "config" / name).write_text("saved input")
        for i in (1,2):
            env = self.root / f"env_{i}"
            env.mkdir()
            (env / "agent.state").write_bytes(b"agent")
            (env / "proxy.state").write_text("1 3 5 A .2" if i==1 else "1 6 0 N 0")
        cfd = self.root / "env_1/cfd"
        native = cfd / "samrai/restore.000002/nodes.00002"
        native.mkdir(parents=True)
        (cfd / "environment.state").write_text("1 2 .0002 0 0 0 0")
        adapter="1 .4 4 5 1.2 0 "+" ".join(["0"]*24)
        (cfd / "adapter.state").write_text(adapter)
        (native / "proc.00000").write_bytes(b"hdf")
        with self.assertRaises(ValueError): snapshot_members(self.root, 2, 2)
        (native / "proc.00001").write_bytes(b"hdf")
        members, states = snapshot_members(self.root, 2, 2)
        self.assertIn("env_1/cfd/samrai/restore.000002/nodes.00002/proc.00001", members)
        self.assertEqual(states["env_2"]["kind"], "N")
        self.assertFalse(any(x.startswith("env_2/cfd") for x in members))
        (cfd / "adapter.state").write_text(adapter.replace(".4 4 5", ".4 3 4"))
        with self.assertRaises(ValueError): snapshot_members(self.root, 2, 2)

    def test_publication_failure_releases_pause_without_claiming_saved(self):
        cfg=self.config()
        for name in ("input2d","eel2d.vertex","task.conf","settings.json"):
            (self.root/name).write_text("original input")
        manager=PairedRun(self.root,cfg)
        manager.begin_checkpoint()
        stage=manager.stage
        for slot in manager.slots:
            (stage/slot.name/"proxy.state").write_text("1 1 0 N 0")
            (stage/slot.name/"agent.state").write_bytes(b"agent")
            (slot/"proxy.ready").write_text(str(stage/slot.name))
        (stage/"learner/learner.native").write_bytes(b"native")
        (stage/"learner/learner.meta").write_text("{}")
        (manager.control/"learner.ready").write_text(str(stage/"learner"))
        with patch.object(manager.store,"publish",side_effect=OSError("disk full")):
            self.assertFalse(manager.advance_checkpoint())
        self.assertIsNone(manager.stage)
        self.assertFalse((manager.control/"learner.request").exists())
        self.assertTrue((manager.slots[0]/"checkpoint.release").read_text().endswith("CONTINUE\n"))
        self.assertFalse(list((self.root/"checkpoints").glob("snapshot-*")))

    def manager_fixture(self):
        cfg=self.config(steps=8)
        for name in ("input2d","eel2d.vertex","task.conf"):
            (self.root/name).write_text("original input")
        (self.root/"settings.json").write_text('{"batchSize":8,"minTotObsNum":8}')
        return PairedRun(self.root,cfg)

    def parked_pending_participants(self,manager,steps):
        stage=manager.stage
        self.assertIsNotNone(stage,"stop/budget must start checkpoint before polling participants")
        for slot in manager.slots:
            (stage/slot.name/"proxy.state").write_text("1 1 0 N 0")
            (stage/slot.name/"agent.state").write_bytes(b"agent")
            (slot/"proxy.ready").write_text(str(stage/slot.name))
        (stage/"learner/learner.native").write_bytes(b"native")
        (stage/"learner/learner.meta").write_text(json.dumps(dict(
            algorithmStage=0,nGradSteps=1,nLocTimeSteps=steps+8,
            nLocTimeStepsTrain=steps,nTrainSteps=manager.cfg["steps"])))
        (manager.control/"learner.ready").write_text(str(stage/"learner"))

    def execute_queued_checkpoint(self,budget):
        manager=self.manager_fixture()
        class LearnerPeer:
            process=None
            def start(self,*args): pass
            def poll(self): return 0 if (manager.control/"learner.stop").exists() else None
        manager.learner=LearnerPeer()
        for slot in manager.slots: (slot/"request").write_text("1")
        trigger=manager.control/"learner.budget_reached" if budget else self.root/"stop.request"
        trigger.write_text("reached" if budget else "stop")
        def participants(_):
            if manager.stage: self.parked_pending_participants(manager,8 if budget else 6)
        # Only the learner boundary is substituted. Real launch_requests,
        # checkpoint coordination/publication and completion markers execute.
        with patch("paired_run.subprocess.Popen",side_effect=AssertionError("new CFD launched after stop/budget")), \
             patch("paired_run.time.sleep",side_effect=participants):
            self.assertEqual(manager.execute(),0)
        for slot in manager.slots:
            self.assertEqual(list(slot.glob("episode_*")),[])
            self.assertTrue((slot/"checkpoint.release").read_text().endswith("STOP\n"))
        self.assertEqual((self.root/"completed").exists(),budget)
        self.assertEqual(len(list((self.root/"checkpoints").glob("snapshot-*"))),1)

    def test_stop_prevents_queued_episode_launch_same_iteration(self):
        self.execute_queued_checkpoint(False)

    def test_budget_marker_checkpoints_without_new_episode_and_marks_completed(self):
        self.execute_queued_checkpoint(True)

    def test_checkpoint_metadata_detects_budget_reached_during_acquisition(self):
        manager=self.manager_fixture()
        manager.begin_checkpoint()
        self.parked_pending_participants(manager,8)
        self.assertTrue(manager.advance_checkpoint())
        self.assertTrue((manager.control/"learner.stop").exists())

    @unittest.skipUnless(os.name=="posix", "runtime lock is POSIX")
    def test_resume_at_saved_cumulative_budget_starts_no_jobs(self):
        manager=self.manager_fixture()
        manager.begin_checkpoint()
        self.parked_pending_participants(manager,8)
        required,states=snapshot_members(manager.stage,2,16)
        meta=json.loads((manager.stage/"learner/learner.meta").read_text())
        manager.store.publish(manager.stage,dict(configuration=manager.cfg,learner=meta),required)
        (self.root/"run-config.json").write_text(json.dumps(manager.cfg))
        sessions=list((self.root/"sessions").iterdir())
        with patch("paired_run.subprocess.Popen",side_effect=AssertionError("completed snapshot launched MPI")):
            self.assertEqual(main(["resume","--run",str(self.root)]),0)
        self.assertTrue((self.root/"completed").exists())
        self.assertEqual(list((self.root/"sessions").iterdir()),sessions)

    def test_dead_supervisor_does_not_allow_duplicate_surviving_mpi_jobs(self):
        directory=self.root/"sessions/session-000001/env_1/episode_1"
        directory.mkdir(parents=True)
        (directory/"launcher.pid").write_text("12345")
        with patch("os.readlink",return_value=str(directory)):
            with self.assertRaises(RuntimeError): assert_no_live_jobs(self.root)
        # A reused PID in another cwd must not be signalled or treated as ours.
        with patch("os.readlink",return_value="/some/other/work"):
            assert_no_live_jobs(self.root)
        with patch("os.readlink",side_effect=FileNotFoundError):
            assert_no_live_jobs(self.root)

    def test_start_refuses_existing_directory_before_launch(self):
        self.config()
        with patch("paired_run.subprocess.run") as launched:
            with self.assertRaises(FileExistsError):
                main(["start","--run",str(self.root),"--config",str(self.root/"config.json")])
            launched.assert_not_called()

    @unittest.skipUnless(os.name=="posix", "runtime lock is POSIX")
    def test_resume_missing_snapshot_starts_no_process(self):
        (self.root/"run-config.json").write_text(json.dumps(self.config()))
        with patch("paired_run.subprocess.Popen") as launched:
            with self.assertRaises(FileNotFoundError): main(["resume","--run",str(self.root)])
            launched.assert_not_called()

    @unittest.skipUnless(os.name=="posix", "runtime lock is POSIX")
    def test_stop_publishes_request_only_for_live_locked_manager(self):
        (self.root/"run-config.json").write_text(json.dumps(self.config()))
        with self.assertRaises(RuntimeError): main(["stop","--run",str(self.root)])
        self.assertFalse((self.root/"stop.request").exists())
        with RunLock(self.root):
            self.assertEqual(main(["stop","--run",str(self.root)]),0)
        self.assertEqual((self.root/"stop.request").read_text(),"save-and-stop\n")


if __name__ == "__main__": unittest.main()
