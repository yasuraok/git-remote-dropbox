import json
import os
import shutil
import subprocess
import tempfile
import time
from typing import Dict, List, Optional, Tuple

from git_remote_dropbox import git
from git_remote_dropbox.util import Level, Poison, readline, stderr, stdout


class RcloneError(RuntimeError):
    pass


def _run_rclone(args: List[str], input_data: Optional[bytes] = None) -> bytes:
    cmd = ["rclone", *args]
    # Debug: print command to stderr for visibility
    stderr(f"rclone command: {' '.join(cmd)}\n")
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE if input_data is not None else None, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = proc.communicate(input=input_data)
    # Decode outputs for inspection
    try:
        serr = err.decode("utf8", errors="replace")
    except Exception:
        serr = "<binary>"
    # Print basic diagnostics
    stderr(f"rclone rc={proc.returncode} stdout_len={len(out)} stderr_len={len(err)}\n")
    if serr:
        stderr(f"rclone stderr: {serr[:1000]}\n")
    if proc.returncode != 0:
        # Raise with original stderr so callers can inspect content if needed.
        raise RcloneError(serr)
    return out


def _run_rclone_print(args: List[str]) -> None:
    """Run rclone command with real-time stdout/stderr output to console."""
    cmd = ["rclone", *args]
    stderr(f"rclone command: {' '.join(cmd)}\n")

    # Use Popen with real-time output
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, bufsize=1)

    # Read and print output in real-time
    if proc.stdout:
        for line in proc.stdout:
            stderr(f"rclone stdout: {line.rstrip()}\n")

    # Wait for completion
    returncode = proc.wait()

    stderr(f"rclone rc={returncode}\n")

    if returncode != 0:
        raise RcloneError(f"rclone command failed with exit code {returncode}")


class RcloneHelper:
    """
    Minimal rclone-backed helper prototype.

    This is a pragmatic, best-effort reimplementation of the Dropbox-backed
    `Helper` that uses the `rclone` CLI. It intentionally implements a subset
    of behaviors and does not provide the same atomic revision semantics as
    the Dropbox backend. It's useful as a prototype to experiment with an
    alternate backend.
    """

    def __init__(self, remote: str, path: str, processes: int = 4) -> None:
        self.remote = remote
        # path is expected to start with '/'
        self.path = path.lstrip("/")
        self._verbosity = Level.INFO
        self._refs: Dict[str, str] = {}
        self._first_push = True

    @property
    def verbosity(self) -> Level:
        return self._verbosity

    def _trace(self, message: str, level: Level = Level.DEBUG, *, exact: bool = False) -> None:
        if level > self._verbosity:
            return
        if exact:
            if level == self._verbosity:
                stderr(message)
            return
        if level <= Level.ERROR:
            stderr(f"error: {message}\n")
        elif level == Level.INFO:
            stderr(f"info: {message}\n")
        else:
            stderr(f"debug: {message}\n")

    def _full_remote_path(self, path: str) -> str:
        # rclone expects "remote:relative/path"
        rel = path.lstrip("/")
        if rel:
            return f"{self.remote}:{rel}"
        return f"{self.remote}:"

    def run(self) -> None:
        while True:
            line = readline()
            # Debug: log incoming protocol line
            stderr(f"helper recv: {line}\n")
            if line == "capabilities":
                _write("option")
                _write("push")
                _write("fetch")
                _write()
            elif line.startswith("option"):
                if line.startswith("option verbosity"):
                    self._verbosity = Level(int(line.split()[-1]))
                    _write("ok")
                else:
                    _write("unsupported")
            elif line.startswith("list"):
                for_push = "for-push" in line
                refs = self.get_refs(for_push=for_push)
                for sha, ref in refs:
                    _write(f"{sha} {ref}")
                head = self.read_symbolic_ref("HEAD")
                if head:
                    _write(f"@{head[1]} HEAD")
                _write()
            elif line.startswith("push"):
                # simplistic: read push lines until blank
                remote_head = None
                while True:
                    parts = line.split(" ")[1].split(":")
                    src, dst = parts[0], parts[1]
                    if src == "":
                        self._delete(dst)
                    else:
                        self._push(src, dst)
                        if self._first_push and (not remote_head or src == git.symbolic_ref_value("HEAD")):
                            remote_head = dst
                    line = readline()
                    if line == "":
                        if self._first_push:
                            self._first_push = False
                            if remote_head:
                                if not self.write_symbolic_ref("HEAD", remote_head):
                                    self._trace("failed to set default branch on remote", Level.INFO)
                            else:
                                self._trace("first push but no branch to set remote HEAD")
                        break
                _write()
            elif line.startswith("fetch"):
                while True:
                    _, sha, _ = line.split(" ")
                    self._fetch(sha)
                    line = readline()
                    if line == "":
                        break
                _write()
            elif line == "":
                break
            else:
                self._trace(f"unsupported operation: {line}", Level.ERROR)
                break

    def _ref_path(self, name: str) -> str:
        if not name.startswith("refs/"):
            raise ValueError("invalid ref name")
        return f"{self.path}/{name}"

    def _object_path(self, name: str) -> str:
        prefix = name[:2]
        suffix = name[2:]
        return f"{self.path}/objects/{prefix}/{suffix}"

    def _get_file(self, path: str) -> Tuple[str, bytes]:
        self._trace(f"fetching: {path}")
        full = self._full_remote_path(path)
        # Strict fetch: do not suppress errors.
        content = _run_rclone(["cat", full])
        # use timestamp as a pseudo-revision
        rev = str(int(time.time() * 1000))
        return (rev, content)

    def _batch_copy(self, dst: str, new_sha: str, objects: List[str]) -> None:
        """Push objects and ref in a single batch operation."""
        batch_temp_dir = tempfile.mkdtemp(prefix="rclone_batch_")
        self._trace(f"Started batch operation in {batch_temp_dir}")

        try:
            # Add all objects to batch
            for sha in objects:
                data = git.encode_object(sha)
                path = self._object_path(sha)
                full = self._full_remote_path(path)
                self._trace(f"adding to batch: {full}")

                # Create local file path preserving remote structure
                rel_path = full
                if rel_path.startswith(self.remote + ":"):
                    rel_path = rel_path[len(self.remote) + 1:]

                local_path = os.path.join(batch_temp_dir, rel_path)
                os.makedirs(os.path.dirname(local_path), exist_ok=True)

                with open(local_path, 'wb') as f:
                    f.write(data)

            # Add ref file to batch
            refpath = self._ref_path(dst)
            refpath_full = self._full_remote_path(refpath)
            content = f"{new_sha}\n".encode("utf8")
            self._trace(f"adding ref to batch: {refpath_full}")

            rel_path = refpath_full
            if rel_path.startswith(self.remote + ":"):
                rel_path = rel_path[len(self.remote) + 1:]

            local_path = os.path.join(batch_temp_dir, rel_path)
            os.makedirs(os.path.dirname(local_path), exist_ok=True)

            with open(local_path, 'wb') as f:
                f.write(content)

            # Execute batch copy
            self._trace(f"Executing batch copy with {len(objects) + 1} files", Level.INFO)
            remote_base = f"{self.remote}:"
            _run_rclone_print(["copy", "-v", batch_temp_dir, remote_base])
            self._trace("Batch copy completed successfully")

        finally:
            # Clean up temporary directory
            if os.path.exists(batch_temp_dir):
                shutil.rmtree(batch_temp_dir)

    def _delete(self, ref: str) -> None:
        self._trace(f"deleting ref {ref}")
        path = self._ref_path(ref)
        full = self._full_remote_path(path)
        try:
            _run_rclone(["deletefile", full])
        except RcloneError:
            # ignore if file doesn't exist
            pass
        _write(f"ok {ref}")

    def _push(self, src: str, dst: str) -> None:
        force = False
        if src.startswith("+"):
            src = src[1:]
            force = True

        # Get current remote ref if it exists
        refpath = self._ref_path(dst)
        current_remote_sha = None
        try:
            _, data = self._get_file(refpath)
            current_remote_sha = data.decode("utf8").strip()
        except RcloneError:
            # Reference doesn't exist yet, this is ok
            pass

        # Get the SHA we want to push
        new_sha = git.ref_value(src)

        # If we have a current remote ref and this is not a force push,
        # check if this is a fast-forward
        if current_remote_sha and not force:
            # Check if current_remote_sha is an ancestor of new_sha
            # If not, this is a non-fast-forward push and should be rejected
            try:
                # Use git merge-base to check if current is ancestor of new
                import subprocess
                result = subprocess.run(
                    ["git", "merge-base", "--is-ancestor", current_remote_sha, new_sha],
                    capture_output=True
                )
                if result.returncode != 0:
                    # Not a fast-forward, reject the push
                    _write(f"error {dst} non-fast-forward")
                    return
            except (subprocess.SubprocessError, FileNotFoundError):
                # If we can't determine ancestry, allow the push
                # This maintains compatibility when git tools aren't available
                pass

        # Dropboxの実装に倣って、既存のrefsからpresentリストを構築
        present: List[str] = []
        try:
            refs = self.get_refs(for_push=False)
            present = [sha for sha, _ in refs]
        except Exception:
            # リモートが存在しない場合や他のエラーの場合はpresentは空のまま
            present = []

        objects = git.list_objects(src, present)

        # Execute batch copy for all objects and ref
        self._batch_copy(dst, new_sha, objects)

        _write(f"ok {dst}")

    def get_refs(self, *, for_push: bool) -> List[Tuple[str, str]]:
        loc = f"{self.path}/refs"
        full = self._full_remote_path(loc)
        # Call lsjson to list refs. If the remote directory doesn't exist
        # yet (common on the first push), treat that as empty refs when
        # we're preparing for a push. For other callers, propagate the
        # rclone error to fail fast on unexpected failures.
        try:
            out = _run_rclone(["lsjson", "--recursive", full])
        except RcloneError as e:
            serr = str(e)
            # rclone reports "directory not found" when path is absent.
            if for_push and "directory not found" in serr:
                return []
            # otherwise, re-raise to let the caller handle failure
            raise
        entries = json.loads(out.decode("utf8"))
        refs: List[Tuple[str, str]] = []
        for e in entries:
            if e.get("IsDir"):
                continue
            path = e.get("Path")
            # rclone lsjson returns path relative to the provided path; normalize
            # build the remote path and cat to get contents
            remote_path = f"{loc}/{path}"
            try:
                # After lsjson lists the entry, the file should exist; use
                # the strict fetch variant and only skip if rclone reports
                # a genuine 'directory not found' for this specific path.
                _, data = self._get_file(remote_path)
            except RcloneError as e:
                serr = str(e)
                # If the file truly vanished between lsjson and cat, skip
                # this single entry but report other rclone errors upstream.
                if "directory not found" in serr:
                    continue
                raise
            sha = data.decode("utf8").strip()
            refs.append((sha, self._ref_name_from_path(remote_path)))
        return refs

    def _ref_name_from_path(self, path: str) -> str:
        prefix = f"{self.path}/"
        if not path.startswith(prefix):
            raise ValueError("invalid ref path")
        return path[len(prefix):]

    def write_symbolic_ref(self, path: str, ref: str, rev: Optional[str] = None) -> bool:
        p = f"{self.path}/{path}"
        full = self._full_remote_path(p)
        content = f"ref: {ref}\n".encode("utf8")

        try:
            _run_rclone(["rcat", full], input_data=content)
            return True
        except RcloneError:
            return False

    def read_symbolic_ref(self, path: str) -> Optional[Tuple[str, str]]:
        p = f"{self.path}/{path}"
        try:
            rev, data = self._get_file(p)
        except RcloneError as e:
            serr = str(e)
            if "directory not found" in serr:
                return None
            raise
        ref = data.decode("utf8").strip()
        if ref.startswith("ref: "):
            ref = ref[len("ref: ") :]
        return (rev, ref)

    def _fetch(self, sha: str, _seen: Optional[set] = None) -> None:
        # Recursively fetch the given object and any objects it references.
        if _seen is None:
            _seen = set()
        if sha in _seen:
            return
        _seen.add(sha)
        path = self._object_path(sha)
        _, data = self._get_file(path)
        computed = git.decode_object(data)
        if computed != sha:
            raise RuntimeError("hash mismatch")
        # Fetch objects referenced by this object (trees -> blobs/trees, commits -> tree/parents, tags -> target)
        try:
            refs = git.referenced_objects(sha)
        except Exception:
            refs = []
        for r in refs:
            self._fetch(r, _seen)


def _write(message: Optional[str] = None) -> None:
    # Echo outgoing protocol messages to stderr for debugging as well
    if message is not None:
        stdout(f"{message}\n")
        try:
            stderr(f"helper send: {message}\n")
        except Exception:
            pass
    else:
        stdout("\n")
        try:
            stderr("helper send: <blank>\n")
        except Exception:
            pass
