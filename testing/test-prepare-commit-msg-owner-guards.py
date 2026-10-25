"""The prepare-commit-msg caller and the owner's guards (CORCO-4015).

core.hooksPath=.githooks replaces the global hooks folder, so .githooks/prepare-commit-msg
calls the owner's shared "Git hooks/prepare-commit-msg" through the global core.hooksPath.
It never refuses a commit. Where that hook is missing on a machine that has the owner's
guards, the caller says what did not run and how to repair it; on a machine without them, as
in a second developer's plain clone, it says only that the guards are not installed. These
tests copy the real caller into a disposable repository and commit there, with the global
configuration and HOME of each commit named by the test, so they never touch the machine's
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
HOOK = REPO_ROOT / ".githooks/prepare-commit-msg"
OWNER = "and this machine has the owner's Information Security guards, so neither .git/hooks/prepare-commit-msg nor"
REPAIR = "set the global core.hooksPath to that folder, or bring its checkout up to date with git pull --ff-only"
NOTICE = "the owner's Information Security guards are not installed on this machine"
FIXTURE_LINE = "shared hook ran"


def git(cwd: Path, *args: str, env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(  # noqa: S603  git, with literal arguments
        ["git", *args],  # noqa: S607  git resolved from PATH
        cwd=cwd, capture_output=True, text=True, check=False, env=env,
    )


class PrepareCommitMsgCase(unittest.TestCase):
    def setUp(self) -> None:
        temporary = Path(tempfile.mkdtemp(prefix="owner guards message ")).resolve()
        self.addCleanup(shutil.rmtree, temporary, True)
        self.home = temporary / "home"
        self.home.mkdir()
        self.hooks = temporary / "owner hooks"
        self.hooks.mkdir()
        self.calls = temporary / "calls"
        self.entry = self.hooks / "prepare-commit-msg"
        self.entry.write_text(
            f'#!/bin/sh\necho "$@" >> "{self.calls}"\nprintf "{FIXTURE_LINE}\\n" >> "$1"\n',
            encoding="utf-8")
        self.entry.chmod(0o755)
        self.global_config = temporary / "gitconfig"
        self.name_global_hooks(self.hooks)
        base = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.environment = {**base, "GIT_CONFIG_GLOBAL": str(self.global_config),
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
        shutil.copy2(HOOK, self.repo / ".githooks/prepare-commit-msg")

    def name_global_hooks(self, folder: Path | None) -> None:
        text = "" if folder is None else f'[core]\n\thooksPath = "{folder}"\n'
        self.global_config.write_text(text, encoding="utf-8")

    def commit(self) -> subprocess.CompletedProcess:
        (self.repo / "module.py").write_text("VALUE = 1\n", encoding="utf-8")
        self.assertEqual(git(self.repo, "add", "-A", env=self.environment).returncode, 0)
        return git(self.repo, "commit", "-q", "-m", "change the module", env=self.environment)

    def message(self) -> str:
        return git(self.repo, "log", "-1", "--format=%B", env=self.environment).stdout

    def assert_committed_unchanged(self) -> subprocess.CompletedProcess:
        result = self.commit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.message(), "change the module\n\n")
        return result


class WhereTheSharedHookIsInstalled(PrepareCommitMsgCase):
    def test_the_commit_runs_it_and_prints_nothing(self) -> None:
        result = self.commit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text(encoding="utf-8"), ".git/COMMIT_EDITMSG message\n")
        self.assertIn(FIXTURE_LINE, self.message())
        self.assertEqual(result.stderr, "")


class WhereTheOwnersGuardsAreInstalledWithoutTheHook(PrepareCommitMsgCase):
    def assert_repair_message(self, folder: Path) -> None:
        result = self.assert_committed_unchanged()
        self.assertIn(f"no shared hook at '{folder}/prepare-commit-msg'", result.stderr)
        self.assertIn(OWNER, result.stderr)
        self.assertIn("(fails open)", result.stderr)
        self.assertIn(REPAIR, result.stderr)
        self.assertNotIn(NOTICE, result.stderr)

    def test_a_stale_owner_checkout_names_what_did_not_run(self) -> None:
        self.entry.unlink()
        (self.hooks / "pre-commit.py").write_text("", encoding="utf-8")
        self.assert_repair_message(self.hooks)

    def test_a_global_hooks_folder_that_does_not_exist_names_what_did_not_run(self) -> None:
        moved = self.hooks.parent / "moved away"
        self.name_global_hooks(moved)
        self.assert_repair_message(moved)


class WhereTheOwnersGuardsAreNotInstalled(PrepareCommitMsgCase):
    def assert_notice(self) -> None:
        result = self.assert_committed_unchanged()
        self.assertIn(NOTICE, result.stderr)
        self.assertNotIn(OWNER, result.stderr)
        self.assertNotIn("git pull", result.stderr)
        self.assertNotIn("'/prepare-commit-msg'", result.stderr)

    def test_a_plain_clone_commits_and_says_only_that_the_guards_are_not_installed(self) -> None:
        self.name_global_hooks(None)
        self.assert_notice()

    def test_another_global_hooks_folder_commits_and_says_so(self) -> None:
        self.entry.unlink()
        (self.hooks / "pre-commit").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.assert_notice()


if __name__ == "__main__":
    unittest.main()
