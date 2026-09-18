"""Crash-safe, hash-free storage for paired Smarties/IBAMR checkpoints."""

from __future__ import annotations

import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
from typing import Any


_STAGING_RE = re.compile(r"^\.writing-(\d{6})$")
_SNAPSHOT_RE = re.compile(r"^snapshot-(\d{6})$")
_MANIFEST = "manifest.json"


class CheckpointStore:
    def __init__(self, run: Path, keep: int = 2):
        self.run = Path(run)
        self.checkpoints = self.run / "checkpoints"
        if type(keep) is not int or keep < 2:
            raise ValueError("keep must be an integer of at least two")
        self.keep = keep

    def begin(self, required_bytes: int = 0) -> Path:
        if required_bytes < 0:
            raise ValueError("required_bytes must not be negative")
        self._ensure_storage_root()
        if shutil.disk_usage(self.checkpoints).free < required_bytes:
            raise OSError("insufficient free space for checkpoint")
        number = max(self._existing_numbers(), default=0) + 1
        staging = self.checkpoints / f".writing-{number:06d}"
        staging.mkdir()
        return staging

    def publish(
        self, staging: Path, metadata: dict, required_files: list[str]
    ) -> Path:
        staging = Path(staging)
        self._validate_staging_path(staging)
        required = self._validate_required_files(required_files)
        inventory = self._inventory(staging)
        for member in required:
            if member not in inventory:
                raise ValueError(f"required checkpoint member is missing: {member}")

        match = _STAGING_RE.fullmatch(staging.name)
        assert match is not None
        saved = self.checkpoints / f"snapshot-{int(match.group(1)):06d}"
        if saved.exists():
            raise FileExistsError(saved)
        manifest: dict[str, Any] = {
            "format_version": 1,
            "snapshot_id": saved.name,
            "required_files": required,
            "metadata": metadata,
            "inventory": inventory,
        }
        descriptor = staging / _MANIFEST
        with descriptor.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(manifest, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        self._sync_tree(staging, descriptor)
        staging.rename(saved)
        self._fsync_directory(self.checkpoints)
        return saved

    def select(self, which: str = "latest") -> Path:
        if which not in {"latest", "previous"}:
            raise ValueError("which must be 'latest' or 'previous'")
        snapshots = self._snapshot_paths()
        offset = 1 if which == "previous" else 0
        if len(snapshots) <= offset:
            raise FileNotFoundError(f"no {which} checkpoint snapshot")
        selected = snapshots[-1 - offset]
        self._validate_snapshot(selected)
        return selected

    def prune(self) -> list[Path]:
        snapshots = self._snapshot_paths()
        for snapshot in snapshots:
            self._validate_snapshot(snapshot)
        doomed = snapshots[: max(0, len(snapshots) - self.keep)]
        for snapshot in doomed:
            shutil.rmtree(snapshot)
        if doomed:
            self._fsync_directory(self.checkpoints)
        return doomed

    def _existing_numbers(self) -> list[int]:
        numbers: list[int] = []
        for entry in self.checkpoints.iterdir():
            match = _STAGING_RE.fullmatch(entry.name) or _SNAPSHOT_RE.fullmatch(entry.name)
            if match:
                numbers.append(int(match.group(1)))
        return numbers

    def _snapshot_paths(self) -> list[Path]:
        if self.run.is_symlink():
            raise ValueError("run directory must not be a symlink")
        if not self.checkpoints.exists() and not self.checkpoints.is_symlink():
            return []
        if not stat.S_ISDIR(self.checkpoints.lstat().st_mode):
            raise ValueError("checkpoints path must be a real directory")
        snapshots: list[Path] = []
        for entry in self.checkpoints.iterdir():
            if not _SNAPSHOT_RE.fullmatch(entry.name):
                continue
            if not stat.S_ISDIR(entry.lstat().st_mode):
                raise ValueError(f"unknown snapshot-shaped content: {entry}")
            snapshots.append(entry)
        return sorted(snapshots, key=lambda path: int(path.name.removeprefix("snapshot-")))

    def _validate_staging_path(self, staging: Path) -> None:
        self._ensure_storage_root()
        if staging.parent.resolve() != self.checkpoints.resolve():
            raise ValueError("staging directory is not owned by this store")
        if (
            not _STAGING_RE.fullmatch(staging.name)
            or not staging.exists()
            or not stat.S_ISDIR(staging.lstat().st_mode)
        ):
            raise ValueError("invalid staging directory")
        descriptor = staging / _MANIFEST
        try:
            descriptor.lstat()
        except FileNotFoundError:
            pass
        else:
            raise ValueError("staging directory already has a descriptor")

    def _ensure_storage_root(self) -> None:
        self.run.mkdir(parents=True, exist_ok=True)
        if self.run.is_symlink():
            raise ValueError("run directory must not be a symlink")
        if self.checkpoints.exists() or self.checkpoints.is_symlink():
            if not stat.S_ISDIR(self.checkpoints.lstat().st_mode):
                raise ValueError("checkpoints path must be a real directory")
        else:
            self.checkpoints.mkdir()

    @staticmethod
    def _validate_required_files(required_files: list[str]) -> list[str]:
        if not required_files:
            raise ValueError("required_files must not be empty")
        checked: list[str] = []
        for value in required_files:
            if not isinstance(value, str) or not value or "\\" in value:
                raise ValueError("required files must be nonempty POSIX relative paths")
            path = PurePosixPath(value)
            if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
                raise ValueError(f"invalid required file path: {value!r}")
            normalized = path.as_posix()
            if normalized == _MANIFEST or normalized in checked:
                raise ValueError(f"invalid required file path: {value!r}")
            checked.append(normalized)
        return checked

    @staticmethod
    def _inventory(root: Path) -> dict[str, int]:
        inventory: dict[str, int] = {}
        for directory, directory_names, file_names in os.walk(root, followlinks=False):
            directory_path = Path(directory)
            for name in directory_names:
                mode = (directory_path / name).lstat().st_mode
                if not stat.S_ISDIR(mode):
                    raise ValueError(f"snapshot contains a non-directory entry: {name}")
            for name in file_names:
                path = directory_path / name
                relative = path.relative_to(root).as_posix()
                if relative == _MANIFEST:
                    continue
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode):
                    raise ValueError(f"snapshot contains a non-regular file: {relative}")
                inventory[relative] = info.st_size
        return dict(sorted(inventory.items()))

    def _validate_snapshot(self, snapshot: Path) -> None:
        descriptor = snapshot / _MANIFEST
        try:
            descriptor_mode = descriptor.lstat().st_mode
        except OSError as error:
            raise ValueError(f"invalid checkpoint descriptor: {snapshot}") from error
        if not stat.S_ISREG(descriptor_mode):
            raise ValueError(f"checkpoint descriptor is not a regular file: {snapshot}")
        try:
            manifest = json.loads(descriptor.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise ValueError(f"invalid checkpoint descriptor: {snapshot}") from error
        if not isinstance(manifest, dict):
            raise ValueError(f"invalid checkpoint descriptor: {snapshot}")
        if manifest.get("format_version") != 1 or manifest.get("snapshot_id") != snapshot.name:
            raise ValueError(f"invalid checkpoint descriptor: {snapshot}")
        required = self._validate_required_files(manifest.get("required_files"))
        if not isinstance(manifest.get("metadata"), dict):
            raise ValueError(f"invalid checkpoint metadata: {snapshot}")
        expected = manifest.get("inventory")
        if not isinstance(expected, dict) or any(
            not isinstance(name, str) or type(size) is not int or size < 0
            for name, size in expected.items()
        ):
            raise ValueError(f"invalid checkpoint inventory: {snapshot}")
        actual = self._inventory(snapshot)
        if actual != expected or any(member not in actual for member in required):
            raise ValueError(f"checkpoint inventory mismatch: {snapshot}")

    @staticmethod
    def _fsync_directory(directory: Path) -> None:
        if os.name != "posix":
            return
        descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def _sync_tree(self, root: Path, descriptor: Path) -> None:
        directories: list[Path] = []
        for directory, _, file_names in os.walk(root, followlinks=False):
            directory_path = Path(directory)
            directories.append(directory_path)
            for name in file_names:
                path = directory_path / name
                if path == descriptor:
                    continue
                flags = os.O_RDONLY if os.name == "posix" else os.O_RDWR
                file_descriptor = os.open(path, flags)
                try:
                    os.fsync(file_descriptor)
                finally:
                    os.close(file_descriptor)
        for directory in reversed(directories):
            self._fsync_directory(directory)


class RunLock:
    def __init__(self, run: Path):
        self.run = Path(run)
        self._stream = None

    def __enter__(self) -> "RunLock":
        if os.name != "posix":
            raise NotImplementedError("RunLock requires POSIX flock")
        import fcntl

        self.run.mkdir(parents=True, exist_ok=True)
        self._stream = (self.run / ".checkpoint.lock").open("a+b")
        try:
            fcntl.flock(self._stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            self._stream.close()
            self._stream = None
            raise
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        assert self._stream is not None
        import fcntl

        fcntl.flock(self._stream.fileno(), fcntl.LOCK_UN)
        self._stream.close()
        self._stream = None
