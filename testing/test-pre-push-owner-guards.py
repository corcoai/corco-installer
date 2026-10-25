"""The pre-push hook and the owner's guards (CORCO-3140, CORCO-4011).

core.hooksPath=.githooks replaces the global hooks folder, so .githooks/pre-push calls the
owner's shared pushed-commit check, "Git hooks/repository-pre-push" in the owner's
Information Security repository, through the global core.hooksPath. On a machine that has
the owner's guards a missing entry refuses the push; on a machine without them, as in a
second developer's plain clone, the push goes on and the hook says so. These tests copy the
real hook into a disposable repository and push to a local bare remote, with the global
configuration and HOME of each push named by the test, so they never touch the machine's
own hooks folder.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HOOK = REPO_ROOT / ".githooks/pre-push"
REFUSED = "this machine has the owner's Information Security guards, so the push was refused"
NOTICE = "the owner's Information Security guards are not installed on this machine"


def git(cwd: Path, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(  # noqa: S603  git, with literal arguments
        ["git", *args],  # noqa: S607  git resolved from PATH
        cwd=cwd, capture_output=True, text=True, check=False, env=env,
    )


class PrePushCase(unittest.TestCase):
    def setUp(self) -> None:
        temporary = Path(tempfile.mkdtemp(prefix="owner guards push ")).resolve()
        self.addCleanup(shutil.rmtree, temporary, True)
        self.home = temporary / "home"
        self.home.mkdir()
        self.hooks = temporary / "owner hooks"
        self.hooks.mkdir()
        self.calls = temporary / "calls"
        self.entry = self.hooks / "repository-pre-push"
        self.set_entry(0)
        self.global_config = temporary / "gitconfig"
        self.name_global_hooks(self.hooks)
        self.remote = temporary / "remote.git"
        setup = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull}
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            setup.pop(name, None)
        self.assertEqual(git(temporary, "init", "-q", "--bare", str(self.remote), env=setup).returncode, 0)
        self.repo = temporary / "clone"
        self.repo.mkdir()
        for args in (
            ("init", "-q", "-b", "main"),
            ("config", "user.name", "Fixture"),
            ("config", "user.email", "fixture@example.invalid"),
            ("config", "core.hooksPath", ".githooks"),
            ("remote", "add", "origin", str(self.remote)),
        ):
            self.assertEqual(git(self.repo, *args, env=setup).returncode, 0, args)
        (self.repo / ".githooks").mkdir()
        shutil.copy2(HOOK, self.repo / ".githooks/pre-push")
        (self.repo / "module.py").write_text("VALUE = 1\n", encoding="utf-8")
        self.assertEqual(git(self.repo, "add", "-A", env=setup).returncode, 0)
        # The fixture's .githooks holds only pre-push, so its own commit runs no pre-commit.
        self.assertEqual(git(self.repo, "commit", "-q", "-m", "baseline", env=setup).returncode, 0)
        self.environment = {**setup, "GIT_CONFIG_GLOBAL": str(self.global_config), "HOME": str(self.home)}

    def set_entry(self, code: int) -> None:
        self.entry.write_text(f'#!/bin/sh\necho "$@" >> "{self.calls}"\nexit {code}\n', encoding="utf-8")
        self.entry.chmod(0o755)

    def name_global_hooks(self, folder: Path | None) -> None:
        text = "" if folder is None else f'[core]\n\thooksPath = "{folder}"\n'
        self.global_config.write_text(text, encoding="utf-8")

    def push(self) -> subprocess.CompletedProcess:
        return git(self.repo, "push", "-q", "origin", "main", env=self.environment)

    def pushed(self) -> bool:
        return git(self.remote, "rev-parse", "--verify", "-q", "refs/heads/main", env=self.environment).returncode == 0


class WhereTheEntryIsInstalled(PrePushCase):
    def test_the_push_runs_it_with_the_push_arguments(self) -> None:
        result = self.push()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.pushed())
        self.assertEqual(self.calls.read_text(encoding="utf-8"), f"origin {self.remote}\n")
        self.assertNotIn(NOTICE, result.stderr)

    def test_its_refusal_refuses_the_push(self) -> None:
        self.set_entry(1)
        result = self.push()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.pushed())


class WhereTheOwnersGuardsAreInstalledWithoutTheEntry(PrePushCase):
    def assert_refused(self) -> None:
        result = self.push()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(REFUSED, result.stderr)
        self.assertFalse(self.pushed())

    def test_a_stale_owner_checkout_refuses_the_push(self) -> None:
        self.entry.unlink()
        (self.hooks / "pre-commit.py").write_text("", encoding="utf-8")
        self.assert_refused()

    def test_a_global_hooks_folder_that_does_not_exist_refuses_the_push(self) -> None:
        self.name_global_hooks(self.hooks.parent / "moved away")
        self.assert_refused()


class WhereTheOwnersGuardsAreNotInstalled(PrePushCase):
    def assert_pushed_with_the_notice(self) -> None:
        result = self.push()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(NOTICE, result.stderr)
        self.assertTrue(self.pushed())

    def test_no_global_hooks_folder_pushes_and_says_so(self) -> None:
        self.name_global_hooks(None)
        self.assert_pushed_with_the_notice()

    def test_another_global_hooks_folder_pushes_and_says_so(self) -> None:
        self.entry.unlink()
        (self.hooks / "pre-push").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.assert_pushed_with_the_notice()


if __name__ == "__main__":
    unittest.main()
