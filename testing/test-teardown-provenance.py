"""teardown.sh and TEARDOWN.md are recorded copies of corco-platform's files, never edits.

The Cloud Shell teardown button opens TEARDOWN.md and runs teardown.sh from a clone of
this repository. Both files are copied byte for byte from corcoai/corco-platform, which
owns them (deployment/scripts/teardown.sh and deployment/docs/TEARDOWN_TUTORIAL.md), at
the commit teardown.provenance.json names. Two copies that are edited separately drift
apart, and the copy customers run is then the one nobody tests. So:

- each file must match the sha256 that teardown.provenance.json records for it, so an edit
  made here in place fails;
- the provenance must name corco-platform, a 40-hex commit and the source path of each file;
- teardown.sh must be executable, because the tutorial runs it as ./teardown.sh;
- neither file may name an internal ticket key or an internal tool path, because this
  repository is public.

corco-platform's testing/test-installer-teardown-copy.py checks the other half: that each
copy here equals its source there. Each check is negative-tested: one appended byte must
fail the hash, and an invented reference must be found.

To refresh: change the file in corco-platform and push it, copy it over the file here,
set its sha256 and the source_commit in teardown.provenance.json in the same commit, and
push to main. Moving the release branch is a customer release.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROVENANCE = ROOT / "teardown.provenance.json"
COPIES = (
    ("teardown.sh", "deployment/scripts/teardown.sh"),
    ("TEARDOWN.md", "deployment/docs/TEARDOWN_TUTORIAL.md"),
)
INTERNAL_REFERENCE = re.compile(r"\b(?:CORCO|SD|PD|TEST)-\d+\b|\btools/admin[\w.-]*")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hash_mismatches(root: Path, record: dict) -> list:
    problems = []
    for name, source_path in COPIES:
        copy = root / name
        entries = [entry for entry in record.get("files", []) if entry.get("file") == name]
        if not copy.is_file():
            problems.append(f"{name} is missing")
        elif len(entries) != 1:
            problems.append(f"teardown.provenance.json must list {name} exactly once")
        elif entries[0].get("source_path") != source_path:
            problems.append(f"teardown.provenance.json must name {source_path} as the source of {name}")
        elif sha256(copy) != entries[0].get("sha256"):
            problems.append(f"{name} does not match the sha256 in teardown.provenance.json")
    return problems


def internal_references(text: str) -> list:
    return [
        f"line {number}: {match.group(0)}"
        for number, line in enumerate(text.splitlines(), start=1)
        for match in INTERNAL_REFERENCE.finditer(line)
    ]


class TheTeardownFilesAreRecordedCopies(unittest.TestCase):
    def setUp(self):
        self.assertTrue(PROVENANCE.is_file(), f"{PROVENANCE.name} is missing")
        self.record = json.loads(PROVENANCE.read_text(encoding="utf-8"))

    def test_each_file_matches_its_recorded_sha256(self):
        self.assertEqual(hash_mismatches(ROOT, self.record), [], __doc__)

    def test_the_provenance_names_its_source(self):
        self.assertEqual(self.record.get("source_repository"), "corcoai/corco-platform")
        self.assertRegex(self.record.get("source_commit", ""), r"^[0-9a-f]{40}$")
        self.assertEqual(
            [(entry.get("file"), entry.get("source_path")) for entry in self.record.get("files", [])],
            list(COPIES),
        )
        for entry in self.record["files"]:
            self.assertRegex(entry.get("sha256", ""), r"^[0-9a-f]{64}$")

    def test_teardown_sh_is_executable(self):
        self.assertTrue(os.access(ROOT / "teardown.sh", os.X_OK), "the tutorial runs ./teardown.sh")

    def test_an_edited_copy_fails_and_the_original_passes(self):
        for name, _source_path in COPIES:
            with self.subTest(file=name), tempfile.TemporaryDirectory(prefix="Corco Teardown Drift ") as scratch:
                temp_root = Path(scratch)
                for other, _ in COPIES:
                    (temp_root / other).write_bytes((ROOT / other).read_bytes())
                self.assertEqual(hash_mismatches(temp_root, self.record), [])
                edited = temp_root / name
                edited.write_bytes(edited.read_bytes() + b"\n")
                self.assertTrue(hash_mismatches(temp_root, self.record), f"an edit to {name} passed")


class TheCopiesAreFitForThisPublicRepository(unittest.TestCase):
    def test_no_copy_names_an_internal_ticket_or_tool(self):
        for name, _source_path in COPIES:
            with self.subTest(file=name):
                self.assertEqual(internal_references((ROOT / name).read_text(encoding="utf-8")), [])

    def test_the_check_finds_an_invented_reference(self):
        invented = "# safe line\n# see SD-0 and CORCO-0, run by tools/admin-example.sh\n"
        self.assertEqual(
            internal_references(invented),
            ["line 2: SD-0", "line 2: CORCO-0", "line 2: tools/admin-example.sh"],
        )
        self.assertEqual(internal_references("# CORCO_TEARDOWN_TOKEN and a 404 answer\n"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
