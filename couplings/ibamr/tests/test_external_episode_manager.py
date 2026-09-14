"""A missing reap or swallowed exit status must fail these real-process tests."""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import os
import signal

SCRIPT = pathlib.Path(__file__).parents[1] / "scripts/external_episode_manager.py"

class ManagerTests(unittest.TestCase):
    @unittest.skipUnless(hasattr(os, "killpg"), "POSIX process group check")
    def test_process_exits_between_poll_and_signal(self):
        spec = importlib.util.spec_from_file_location("manager", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            job = module.EpisodeJob(pathlib.Path(directory))
            job.start([sys.executable, "-c", "import time; time.sleep(30)"])
            original_killpg = os.killpg
            def exit_before_signal(pid, sig):
                original_killpg(pid, signal.SIGTERM)
                job.process.wait()
                # The group actually disappeared after the live poll.
                original_killpg(pid, sig)
            with patch.object(module.os, "killpg", side_effect=exit_before_signal):
                job.stop()
            self.assertIsNotNone(job.process.returncode)
            self.assertTrue((pathlib.Path(directory)/"exit.status").exists())

    def test_reject_zero_openmp_chunk_before_launch(self):
        spec = importlib.util.spec_from_file_location("manager", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(hasattr(module, "validate_training"), "launcher lacks batch/thread validation")
        with self.assertRaises(ValueError):
            module.validate_training({"batchSize": 4, "minTotObsNum": 8}, 8)
        module.validate_training({"batchSize": 8, "minTotObsNum": 8}, 8)

    def test_new_process_per_episode_and_exit_status(self):
        self.assertTrue(SCRIPT.exists(), "external episode manager has not been implemented")
        spec = importlib.util.spec_from_file_location("manager", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            job = module.EpisodeJob(pathlib.Path(directory))
            first = job.start([sys.executable, "-c", "import sys; sys.exit(0)"])
            self.assertEqual(job.wait(), 0)
            second = job.start([sys.executable, "-c", "import sys; sys.exit(7)"])
            self.assertNotEqual(first, second)
            self.assertEqual(job.wait(), 7)
            self.assertEqual((pathlib.Path(directory)/"exit.status").read_text().strip(), "7")

if __name__ == "__main__":
    unittest.main()
