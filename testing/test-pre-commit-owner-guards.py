"""The end of the pre-commit hook and the owner's guards (CORCO-3184, CORCO-4011).

core.hooksPath=.githooks replaces the global hooks folder, so .githooks/pre-commit ends by
calling the owner's shared credential scan, "Git hooks/repository-pre-commit" in the owner's
Information Security repository, through the global core.hooksPath. On a machine that has
the owner's guards a missing entry refuses the commit; on a machine without them, as in a
second developer's plain clone, the commit goes on with this repository's own checks and
the hook says so. These tests copy the real hook into a disposable repository, with a
stand-in gitleaks on PATH and the global configuration and HOME of each commit named by the
test, so they never touch the machine's own hooks folder or its gitleaks.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = next(folder for folder in Path(__file__).resolve().parents if (folder / ".githooks").is_dir())
HOOK = REPO_ROOT / ".githooks/pre-commit"
REFUSED = "this machine has the owner's Information Security guards, so the commit was refused"
NOTICE = "the owner's Information Security guards are not installed on this machine"


def git(cwd: Path, *args: str, env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(  # noqa: S603  git, with literal arguments
        ["git", *args],  # noqa: S607  git resolved from PATH
        cwd=cwd, capture_output=True, text=True, check=False, env=env,
    )


def executable(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)
    return path


class PreCommitCase(unittest.TestCase):
    def setUp(self) -> None:
        temporary = Path(tempfile.mkdtemp(prefix="owner guards commit ")).resolve()
        self.addCleanup(shutil.rmtree, temporary, True)
        self.home = temporary / "home"
        self.home.mkdir()
        self.hooks = temporary / "owner hooks"
        self.ran = temporary / "shared scan ran"
        self.entry = self.hooks / "repository-pre-commit"
        self.set_entry(0)
        # The stand-in gitleaks exits with the status in this file, so a test can make the
        # repository's own secret scan refuse without a real key or a real gitleaks.
        self.gitleaks_status = temporary / "gitleaks status"
        self.gitleaks_status.write_text("0\n", encoding="utf-8")
        stand_ins = temporary / "bin"
        executable(stand_ins / "gitleaks", f'#!/bin/sh\nexit "$(cat "{self.gitleaks_status}")"\n')
        (stand_ins / "python3").symlink_to(sys.executable)
        git_folder = str(Path(shutil.which("git") or "/usr/bin/git").parent)
        search = os.pathsep.join(dict.fromkeys([str(stand_ins), git_folder, "/usr/bin", "/bin"]))
        self.global_config = temporary / "gitconfig"
        self.name_global_hooks(self.hooks)
        base = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        base.pop("VIRTUAL_ENV", None)
        self.environment = {**base, "PATH": search, "GIT_CONFIG_GLOBAL": str(self.global_config),
                            "GIT_CONFIG_NOSYSTEM": "1", "HOME": str(self.home)}
        self.repo = temporary / "clone"
        self.repo.mkdir()
        for args in (
            ("init", "-q", "-b", "main"),
            ("config", "user.name", "Fixture"),
            ("config", "user.email", "fixture@example.invalid"),
            ("config", "commit.gpgsign", "false"),
            ("config", "core.hooksPath", ".githooks"),
        ):
            self.assertEqual(git(self.repo, *args, env=self.environment).returncode, 0, args)
        (self.repo / ".githooks").mkdir()
        shutil.copy2(HOOK, self.repo / ".githooks/pre-commit")

    def set_entry(self, code: int) -> None:
        executable(self.entry, f'#!/bin/sh\ntouch "{self.ran}"\nexit {code}\n')

    def name_global_hooks(self, folder: Path | None) -> None:
        text = "" if folder is None else f'[core]\n\thooksPath = "{folder}"\n'
        self.global_config.write_text(text, encoding="utf-8")

    def commit(self) -> subprocess.CompletedProcess:
        # A Python file and no Markdown, so no other gate of the hook has work to do.
        (self.repo / "module.py").write_text("VALUE = 1\n", encoding="utf-8")
        self.assertEqual(git(self.repo, "add", "module.py", env=self.environment).returncode, 0)
        return git(self.repo, "commit", "-q", "-m", "change the module", env=self.environment)

    def committed(self) -> bool:
        return git(self.repo, "rev-parse", "--verify", "-q", "HEAD", env=self.environment).returncode == 0


class WhereTheEntryIsInstalled(PreCommitCase):
    def test_the_commit_runs_it(self) -> None:
        result = self.commit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.ran.exists(), "the hook did not call repository-pre-commit")
        self.assertNotIn(NOTICE, result.stderr)

    def test_its_refusal_refuses_the_commit(self) -> None:
        self.set_entry(1)
        result = self.commit()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("the shared credential scan refused the commit", result.stderr)
        self.assertFalse(self.committed())


class WhereTheOwnersGuardsAreInstalledWithoutTheEntry(PreCommitCase):
    def assert_refused(self) -> None:
        result = self.commit()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(REFUSED, result.stderr)
        self.assertFalse(self.committed())

    def test_a_stale_owner_checkout_refuses_the_commit(self) -> None:
        # The owner's hooks folder from before repository-pre-commit: it holds pre-commit.py.
        self.entry.unlink()
        (self.hooks / "pre-commit.py").write_text("", encoding="utf-8")
        self.assert_refused()

    def test_a_global_hooks_folder_that_does_not_exist_refuses_the_commit(self) -> None:
        self.name_global_hooks(self.hooks.parent / "moved away")
        self.assert_refused()


class WhereTheOwnersGuardsAreNotInstalled(PreCommitCase):
    def assert_committed_with_the_notice(self) -> None:
        result = self.commit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(NOTICE, result.stderr)
        self.assertTrue(self.committed())

    def test_a_plain_clone_commits_and_says_so(self) -> None:
        self.name_global_hooks(None)
        self.assert_committed_with_the_notice()

    def test_another_global_hooks_folder_commits_and_says_so(self) -> None:
        # A second developer's own global hooks folder, which is not the owner's.
        self.entry.unlink()
        executable(self.hooks / "pre-commit", "#!/bin/sh\nexit 0\n")
        self.assert_committed_with_the_notice()

    def test_the_own_secret_scan_still_refuses(self) -> None:
        # The repository's own gitleaks scan does not depend on the owner's guards.
        self.name_global_hooks(None)
        self.gitleaks_status.write_text("1\n", encoding="utf-8")
        result = self.commit()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("looks like a secret", result.stderr)
        self.assertFalse(self.committed())


if __name__ == "__main__":
    unittest.main()
