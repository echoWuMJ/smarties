import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from checkpoint_store import CheckpointStore, RunLock


class CheckpointStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.run = Path(self.temporary_directory.name)
        self.store = CheckpointStore(self.run)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def publish(self, payload=b"weights", updates=1):
        staging = self.store.begin()
        (staging / "learner").mkdir()
        (staging / "learner" / "state").write_bytes(payload)
        return self.store.publish(staging, {"updates": updates}, ["learner/state"])

    def test_incomplete_staging_is_not_selectable(self):
        staging = self.store.begin()
        (staging / "partial").write_bytes(b"unfinished")

        with self.assertRaises(FileNotFoundError):
            self.store.select()

    def test_publish_writes_the_only_descriptor_and_binary_inventory(self):
        saved = self.publish(b"\x00\xffweights", updates=7)

        self.assertEqual(self.run / "checkpoints", saved.parent)
        self.assertEqual(saved, self.store.select())
        self.assertFalse(any((self.run / "checkpoints").glob(".writing-*")))
        manifest = json.loads((saved / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(1, manifest["format_version"])
        self.assertEqual(saved.name, manifest["snapshot_id"])
        self.assertEqual(["learner/state"], manifest["required_files"])
        self.assertEqual({"updates": 7}, manifest["metadata"])
        self.assertEqual({"learner/state": len(b"\x00\xffweights")}, manifest["inventory"])
        self.assertEqual(["learner", "manifest.json"], sorted(p.name for p in saved.iterdir()))

    def test_publish_rejects_a_missing_required_member(self):
        staging = self.store.begin()

        with self.assertRaises(ValueError):
            self.store.publish(staging, {}, ["learner/state"])

        self.assertTrue(staging.exists())

    def test_corrupt_latest_is_rejected_without_fallback_and_previous_works(self):
        previous = self.publish(b"old", updates=1)
        latest = self.publish(b"new", updates=2)
        (latest / "learner" / "state").write_bytes(b"corrupt-size")

        with self.assertRaises(ValueError):
            self.store.select()
        self.assertEqual(previous, self.store.select("previous"))

    def test_prune_retains_the_last_two_of_three_publications(self):
        first = self.publish(updates=1)
        second = self.publish(updates=2)
        third = self.publish(updates=3)

        removed = self.store.prune()

        self.assertEqual([first], removed)
        self.assertFalse(first.exists())
        self.assertTrue(second.exists())
        self.assertTrue(third.exists())

    def test_insufficient_space_does_not_touch_an_older_snapshot(self):
        older = self.publish()
        usage = type("usage", (), {"total": 100, "used": 99, "free": 1})()

        with mock.patch("checkpoint_store.shutil.disk_usage", return_value=usage):
            with self.assertRaises(OSError):
                self.store.begin(required_bytes=2)

        self.assertEqual(older, self.store.select())

    def test_fsync_failure_does_not_replace_an_older_snapshot(self):
        older = self.publish()
        staging = self.store.begin()
        (staging / "state").write_bytes(b"new")

        with mock.patch("checkpoint_store.os.fsync", side_effect=OSError("disk error")):
            with self.assertRaises(OSError):
                self.store.publish(staging, {}, ["state"])

        self.assertEqual(older, self.store.select())
        self.assertTrue(staging.exists())

    def test_descriptor_write_failure_does_not_replace_an_older_snapshot(self):
        older = self.publish()
        staging = self.store.begin()
        (staging / "state").write_bytes(b"new")

        with mock.patch("checkpoint_store.json.dump", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.store.publish(staging, {}, ["state"])

        self.assertEqual(older, self.store.select())
        self.assertTrue(staging.exists())

    def test_unknown_snapshot_shaped_content_stops_prune_before_deletion(self):
        first = self.publish(updates=1)
        self.publish(updates=2)
        self.publish(updates=3)
        (self.run / "checkpoints" / "snapshot-999999").write_bytes(
            b"not owned by the store"
        )

        with self.assertRaises(ValueError):
            self.store.prune()

        self.assertTrue(first.exists())

    def test_required_paths_reject_empty_absolute_and_traversal(self):
        for required in ([], [""], ["../state"], ["/state"], ["a/../../state"]):
            with self.subTest(required=required):
                staging = self.store.begin()
                with self.assertRaises(ValueError):
                    self.store.publish(staging, {}, required)

    def test_keep_must_be_an_integer_of_at_least_two(self):
        for keep in (-1, 0, 1, True, False, 2.0, "2"):
            with self.subTest(keep=keep):
                with self.assertRaises(ValueError):
                    CheckpointStore(self.run, keep=keep)

    @unittest.skipIf(os.name == "nt", "symlink semantics are POSIX-specific")
    def test_symlinked_checkpoints_ancestor_is_rejected(self):
        outside = self.run / "outside"
        outside.mkdir()
        (self.run / "checkpoints").symlink_to(outside, target_is_directory=True)

        with self.assertRaises(ValueError):
            self.store.begin()

    @unittest.skipIf(os.name == "nt", "symlink semantics are POSIX-specific")
    def test_symlinks_are_rejected_anywhere_in_a_snapshot(self):
        staging = self.store.begin()
        (staging / "state").write_bytes(b"state")
        (staging / "alias").symlink_to("state")

        with self.assertRaises(ValueError):
            self.store.publish(staging, {}, ["state"])


@unittest.skipIf(os.name == "nt", "flock is POSIX-specific")
class RunLockTests(unittest.TestCase):
    def test_lock_excludes_a_second_owner(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            run = Path(temporary_directory)
            with RunLock(run):
                with self.assertRaises(BlockingIOError):
                    with RunLock(run):
                        pass

    def test_lock_releases_when_owner_process_dies(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            run = Path(temporary_directory)
            program = (
                "import sys,time; sys.path.insert(0, sys.argv[2]); "
                "from checkpoint_store import RunLock; "
                "lock=RunLock(sys.argv[1]); lock.__enter__(); print('locked', flush=True); time.sleep(60)"
            )
            process = subprocess.Popen(
                [sys.executable, "-c", program, str(run), str(SCRIPTS)],
                stdout=subprocess.PIPE,
                text=True,
            )
            self.assertEqual("locked\n", process.stdout.readline())
            with self.assertRaises(BlockingIOError):
                with RunLock(run):
                    pass
            process.kill()
            process.wait(timeout=10)
            process.stdout.close()
            with RunLock(run):
                pass


if __name__ == "__main__":
    unittest.main()
