"""A commit is refused while a staged Markdown link is broken or same-repo relative.

The pre-commit hook runs the vendored link checker in testing/corco_tools/ on the index,
the same copy the doc-links CI job runs on the whole tree. The link rules are the
checker's, tested where it is written; what this repository owns is the gate in
.githooks/pre-commit, and these tests pin its decisions by driving the real hook in a
disposable repository that holds the real vendored copy:

- a commit that stages no Markdown and deletes no path commits without running python3;
- a deletion commits without it too while the index tracks no Markdown, and is checked
  while it does;
- otherwise the checker's exit status decides: 0 commits, 1 is a finding, and anything
  else (no python3 that can run the copy) is refused with the route that fixes it;
- a commit by path is checked too.

The fixture puts stand-ins for gitleaks and for the estate's shared credential scan in
front of the hook's other checks. Every document, address and name here is invented.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOOK = ROOT / ".githooks/pre-commit"
VENDORED = ROOT / "testing/corco_tools"
CI = ROOT / ".github/workflows/ci.yml"
FINDING = "a staged Markdown link is broken or same-repo relative"
CANNOT_RUN = "python3 could not run the vendored link checker"
# A python3 that records that it was called and then fails as a missing or too old
# interpreter would, so a test can tell "never run" from "run and refused".
BROKEN_PYTHON = """#!/bin/sh
echo called > "{record}"
exit {status}
"""


def executable(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)
    return path


def write(root: Path, relative: str, text: str) -> None:
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


class HookCase(unittest.TestCase):
    """The real hook and the real vendored checker in a disposable repository."""

    def setUp(self) -> None:
        temporary = Path(tempfile.mkdtemp(prefix="doc links gate "))
        self.addCleanup(shutil.rmtree, temporary, True)
        temporary = temporary.resolve()
        self.record = temporary / "record"
        self.stand_ins = temporary / "bin"
        executable(self.stand_ins / "gitleaks", "#!/bin/sh\nexit 0\n")
        (self.stand_ins / "python3").symlink_to(sys.executable)
        git_folder = str(Path(shutil.which("git") or "/usr/bin/git").parent)
        # The stand-ins come first, so the python3 the hook finds is the one the test chose.
        search = os.pathsep.join(dict.fromkeys([str(self.stand_ins), git_folder, "/usr/bin", "/bin"]))
        # The hook ends with the estate's credential scan, found through the global
        # core.hooksPath; GIT_CONFIG_GLOBAL names a stand-in for it.
        shared_scan = executable(temporary / "estate hooks/repository-pre-commit", "#!/bin/sh\nexit 0\n")
        global_config = temporary / "gitconfig"
        global_config.write_text(f'[core]\n\thooksPath = "{shared_scan.parent}"\n', encoding="utf-8")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith(("GIT_", "PYTHON"))}
        self.env.update(PATH=search, GIT_CONFIG_GLOBAL=str(global_config), GIT_CONFIG_NOSYSTEM="1")
        self.repo = temporary / "fixture"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "gate-test@example.test")
        self.git("config", "user.name", "Gate Test")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        (self.repo / ".githooks").mkdir()
        shutil.copy2(HOOK, self.repo / ".githooks/pre-commit")
        shutil.copytree(VENDORED, self.repo / "testing/corco_tools", ignore=shutil.ignore_patterns("__pycache__"))
        write(self.repo, "docs/Guide.md", "# Guide\n\nSee [the other page](/docs/Other.md).\n")
        write(self.repo, "docs/Other.md", "# Other\n\nPlain text.\n")
        write(self.repo, "setup.sh", "#!/bin/sh\necho set up\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "baseline")
        self.git("config", "core.hooksPath", ".githooks")

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=self.repo, capture_output=True, text=True, check=True, env=self.env,
        ).stdout

    def commit(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", "commit", "-q", "-m", "a change", *args],
            cwd=self.repo, capture_output=True, text=True, check=False, env=self.env,
        )

    def stage(self, relative: str, text: str) -> None:
        write(self.repo, relative, text)
        self.git("add", relative)

    def break_python(self, status: int) -> None:
        (self.stand_ins / "python3").unlink()
        executable(self.stand_ins / "python3", BROKEN_PYTHON.format(record=self.record, status=status))

    def assertCommits(self, result: subprocess.CompletedProcess) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assertRefused(self, result: subprocess.CompletedProcess, *expected: str) -> None:
        # Git sends a hook's standard output to standard error, so the whole report is there.
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        for text in expected:
            self.assertIn(text, result.stderr)
        self.assertNotIn("Traceback", result.stdout + result.stderr)


class TheGateDecidesWhenTheCheckIsNeeded(HookCase):
    def test_a_commit_without_markdown_or_a_deletion_never_runs_python(self) -> None:
        self.break_python(1)
        self.stage("setup.sh", "#!/bin/sh\necho set up again\n")
        self.assertCommits(self.commit())
        self.assertFalse(self.record.exists())

    def test_staged_markdown_without_a_python3_that_runs_the_copy_is_refused(self) -> None:
        self.break_python(2)
        self.stage("docs/Guide.md", "# Guide\n\nNew text.\n")
        self.assertRefused(self.commit(), CANNOT_RUN, "(exit 2", "python3 --version")
        self.assertTrue(self.record.exists())

    def test_a_deletion_is_checked_while_markdown_is_tracked(self) -> None:
        self.break_python(2)
        self.git("rm", "-q", "setup.sh")
        self.assertRefused(self.commit(), CANNOT_RUN)

    def test_a_deletion_needs_no_python_once_no_markdown_is_tracked(self) -> None:
        self.git("rm", "-q", "docs/Guide.md", "docs/Other.md")
        self.assertCommits(self.commit())
        self.break_python(2)
        self.git("rm", "-q", "setup.sh")
        self.assertCommits(self.commit())
        self.assertFalse(self.record.exists())


class TheVendoredCheckerJudgesTheLinks(HookCase):
    def test_a_repo_absolute_link_to_a_staged_page_commits(self) -> None:
        write(self.repo, "docs/New.md", "# New\n")
        self.git("add", "docs/New.md")
        self.stage("docs/Guide.md", "# Guide\n\nSee [the new page](/docs/New.md).\n")
        self.assertCommits(self.commit())

    def test_a_broken_link_is_refused(self) -> None:
        self.stage("docs/Guide.md", "# Guide\n\nSee [a page](/docs/Missing.md).\n")
        self.assertRefused(self.commit(), FINDING, "/docs/Missing.md")

    def test_a_same_repo_relative_link_is_refused(self) -> None:
        self.stage("docs/Guide.md", "# Guide\n\nSee [the other page](Other.md).\n")
        self.assertRefused(self.commit(), FINDING, "Other.md")

    def test_a_link_to_a_file_that_is_not_staged_is_refused(self) -> None:
        write(self.repo, "docs/New.md", "# New\n")
        self.stage("docs/Guide.md", "# Guide\n\nSee [the new page](/docs/New.md).\n")
        self.assertRefused(self.commit(), FINDING, "/docs/New.md")

    def test_a_deletion_that_breaks_a_link_is_refused(self) -> None:
        self.git("rm", "-q", "docs/Other.md")
        self.assertRefused(self.commit(), FINDING, "/docs/Other.md")

    def test_a_commit_by_path_is_checked(self) -> None:
        write(self.repo, "docs/Guide.md", "# Guide\n\nSee [a page](/docs/Missing.md).\n")
        self.assertRefused(self.commit("--", "docs/Guide.md"), FINDING, "/docs/Missing.md")


class TheGateIsWired(unittest.TestCase):
    def test_the_hook_runs_the_vendored_copy_before_the_credential_scan(self) -> None:
        text = HOOK.read_text(encoding="utf-8")
        gate = text.index('PYTHONPATH="$link_top/testing" python3 -P -m corco_tools.check_doc_links --staged --strict')
        self.assertLess(gate, text.index("# The estate's credential scan"))

    def test_ci_runs_this_test_by_name(self) -> None:
        # Named, not discovered, as every test here is (ci.yml): a test that stops being
        # run shows up as a missing step rather than as silence.
        self.assertIn("python testing/test-doc-links-gate.py", CI.read_text(encoding="utf-8"))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=2).result.wasSuccessful() else 1)
