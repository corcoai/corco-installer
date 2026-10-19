#!/usr/bin/env python3
"""check_doc_links.py - resolve every Markdown link in a repository and report the misses.

This exists because the estate's two link conventions cannot both be checked by eye,
and one of them is invisible to a reader:

  * inside a repository a link is repo-root-absolute -- /software_development/docs/X.md
  * across repositories it is sibling-relative       -- ../corco-gtm/sales/docs/SALES.md

The second one is the trap. The example in the workspace CLAUDE.md is written as if
from a repository root, so it is correct only for a file that sits there. A document at
<repo>/<area>/docs/X.md is two directories down, and the same ../corco-gtm/... written
from it resolves to <repo>/<area>/corco-gtm/... -- inside its own repository, where
nothing is. Sixteen links across nine documents were wrong in exactly this way and none
of them looked wrong. The correct prefix is one ../ per directory level, plus one.

A depth error is checkable without the sibling repository being present, which is what
makes this a CI gate rather than a workspace-only script: the ../ count is a property of
where the file sits, and CI checks out one repository. When the siblings do happen to be
checked out -- an operator's workspace -- the target's existence is checked as well, from
the main checkout and from any linked worktree of it alike: the estate is the folder that
holds the main checkout, read from Git (corco_tools.repo.CheckoutLayout), never the folder
that happens to hold the checkout being checked.

Two severities, because a gate that arrives red teaches people to ignore red. A link
that does not resolve is an error and fails the run. A same-repo relative link that does
resolve today is a warning: it works from where the file is and breaks the moment the
file moves, which is the whole reason the repo-absolute convention exists, but there are
enough of them that fixing them is its own change. --strict promotes warnings to errors
for the run that finally does it.

Two kinds of target are reported as they stand, without being resolved. A file:// URL is
an absolute path on the machine that wrote it, which no other host or reader can open. A
target holding a raw space is not a link to CommonMark at all -- GitHub shows it as
literal text -- and it escaped this check entirely until the check looked for it.

A ../ target is read by where it lands, not by how it starts. One whose first segment
after the ../ run names an estate repository is a cross-repository link. One that stays
inside the repository, deployment/x.md linking ../docs/y.md, is a same-repo relative
link like any other; it was reported as leaving the repository until CORCO-3188. Only one
that climbs above the repository root without naming a sibling is reported as that.

Two modes. Without --staged every tracked document is read from disk, which is what CI
runs. With --staged the index is read instead, which is what a pre-commit hook runs:
each staged document, or every tracked one when the commit deletes a path, since a
deletion can break a link in a document the commit leaves alone. A target is looked up
in the index as well, so a link to a file that exists on disk but is not staged fails.
A cross-repository target is checked for its shape only, as CI checks it, so a sibling
checkout that is behind its origin cannot refuse a commit CI would accept.
"""

from __future__ import annotations

import argparse
import os
import posixpath
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from urllib.parse import quote, unquote

from .repo import (
    ESTATE_REPOS,
    CheckoutLayout,
    GitError,
    RepoRootError,
    StagedIndex,
    repo_root,
    staged_changes,
)

#: Generated aggregates are rebuilt from their sources. Auditing one reports every source
#: defect a second time and adds its own staleness on top, so the sources are the subject.
GENERATED = frozenset({"ALL_DOCS.md"})

#: Directories that are not documentation: version control, virtualenvs, dependency and
#: build trees, and the per-repository agent scratch space (which holds worktrees --
#: whole second checkouts, whose links belong to whichever branch they are on). Only the
#: no-git fallback in markdown_files uses this; where there is a checkout to ask, git
#: already excludes every one of these by tracking nothing in them.
SKIP_DIRS = frozenset({".git", ".venv", "node_modules", "__pycache__", ".claude", "dist"})

# A Markdown inline link. The target stops at whitespace or the closing paren, and an
# optional quoted title after it is consumed so it is not mistaken for part of the path.
LINK = re.compile(r"\[[^\]\n]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")

# Anything shaped like an inline link, whatever its target holds. LINK stops a target at
# whitespace, so a target with a raw space never matches it; this looser pattern finds
# those, which would otherwise pass unchecked.
LINK_SHAPED = re.compile(r"\[[^\]\n]*\]\(([^)\n]*)\)")

# A cross-repository link, split so the ../ run can be counted and replaced.
CROSS_REPO = re.compile(r"(\]\()((?:\.\./)+)([^)\s]+)(\))")

# A ../ target split into its ../ run and the rest.
CROSS_REPO_HEAD = re.compile(r"((?:\.\./)+)(.*)", re.S)

# Any inline link, split so the target alone can be replaced.
LINK_TARGET = re.compile(r"(\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")

FENCE = re.compile(r"^\s*(?:```|~~~)")

# Targets that name something other than a path in this filesystem.
EXTERNAL = ("http://", "https://", "mailto:", "tel:", "ftp://", "#")

#: Whitespace that cannot stand raw in a link target. CommonMark ends the target at the
#: first one, so GitHub shows the whole link as literal text. This one pattern is both the
#: rule check_file reports and the first thing encode_target removes, which is what keeps
#: a target the checker proposes from being one the checker rejects (CORCO-2104).
RAW_WHITESPACE = re.compile(r"\s")

#: What encode_target escapes: the whitespace above, plus the four characters that would
#: change what the target means if left raw -- "%" starts an escape, "#" starts the
#: fragment, and "(" ")" can end the link early. decode_target is the exact inverse.
_ESCAPED = re.compile(r"[%#()]|" + RAW_WHITESPACE.pattern)


def encode_target(path: str) -> str:
    """Spell a filesystem path as a link target the checker itself accepts.

    Every target the checker proposes to a reader, or writes with --fix, goes through here.
    A path is decoded to look it up (decode_target) and must be encoded again to be shown:
    printing the decoded path hands back a raw space, which the rule above rejects. Only
    the characters that must change do, so slashes and accents stay readable.
    """
    return _ESCAPED.sub(lambda match: quote(match.group(0), safe=""), path)


def decode_target(target: str) -> tuple[str, str]:
    """Split a link target into the filesystem path it names and its fragment as written.

    The fragment is split off before decoding, so %23 stays part of the filename while a
    real # starts the fragment. The path is decoded exactly once, the inverse of
    encode_target.
    """
    bare, _, fragment = target.partition("#")
    return unquote(bare), fragment


def strip_code(text: str) -> str:
    """Blank out fenced blocks and inline code spans, preserving line structure.

    Documentation about links contains things shaped like links. DEVELOPER_DOCUMENTATION.md
    documents the syntax as `[text](url)` and an earlier version of this check duly
    reported `url` as a broken link, which is the kind of false positive that gets a
    gate switched off.

    Every replacement is the same length as what it replaces, so the result is a mask
    that can be indexed with offsets taken from the original. The fixer relies on that
    to decide whether a match it found in the source is real code or prose; blanking a
    fenced line to "" instead shifts every offset after the first code block, which
    silently makes the fixer skip links it should rewrite.
    """
    out = []
    in_fence = False
    for line in text.split("\n"):
        if FENCE.match(line):
            in_fence = not in_fence
            out.append(" " * len(line))
            continue
        if in_fence:
            out.append(" " * len(line))
            continue
        # Inline spans, longest run of backticks first so ``a `b` c`` is one span.
        out.append(re.sub(r"(`+)(?:(?!\1).)*\1", lambda m: " " * len(m.group(0)), line))
    return "\n".join(out)


def markdown_files(root: Path):
    """Every Markdown document in the repository that is subject to the conventions.

    Tracked files where there is a git checkout to ask, and a filesystem walk only
    where there is not. The two are not the same set and the difference is the whole
    point: CI sees exactly what is committed, so a local run that also read ignored
    files would report findings nobody can reproduce and miss none that matter. It
    bites immediately -- corco-web tracks no Markdown at all, and the only .md on
    disk there is a brand document sync-brand.sh copies in under an ignored path.
    """
    if (root / ".git").exists():
        try:
            listed = subprocess.run(  # noqa: S603  fixed argv, no shell; root is a path this process resolved
                ["git", "-C", str(root), "ls-files", "-z", "--", "*.md"],  # noqa: S607  git intentionally resolved from PATH
                capture_output=True,
                check=True,
                text=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError):
            pass  # No usable git; fall through to the walk below.
        else:
            for rel in sorted(p for p in listed.split("\0") if p):
                path = root / rel
                if path.name not in GENERATED and path.is_file():
                    yield path
            return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in sorted(filenames):
            if name.endswith(".md") and name not in GENERATED:
                yield Path(dirpath) / name


class DiskTree:
    """Documents and targets as they are on disk: what a full run and --fix read."""

    def read(self, path: Path) -> str:
        return path.read_text(encoding="utf-8")

    def exists(self, path: Path) -> bool:
        return path.exists()

    def resolve(self, path: Path) -> Path:
        return path.resolve()


class StagedTree:
    """Documents and in-repository targets as the index holds them: what the commit will hold.

    A path under ``root`` exists when the index tracks it or a file below it. A path
    outside ``root`` is in no commit this check can see, so it is looked up on disk.
    Paths are normalised by their spelling, never through the disk: the index holds no
    symbolic links to follow.
    """

    def __init__(self, root: Path, index: StagedIndex | None = None) -> None:
        self.root = Path(os.path.normpath(root))
        self.index = index if index is not None else StagedIndex(self.root)
        self.present = {"."}
        for tracked in self.index.tracked:
            self.present.add(tracked)
            self.present.update(str(parent) for parent in PurePosixPath(tracked).parents)
        self.texts: dict[str, bytes | None] = {}

    def _relative(self, path: Path) -> str | None:
        normalised = Path(os.path.normpath(path))
        if not normalised.is_relative_to(self.root):
            return None
        return normalised.relative_to(self.root).as_posix()

    def load(self, paths: list[Path]) -> None:
        """Read the staged text of every path in one git process, before the documents are checked."""
        wanted = [relative for relative in map(self._relative, paths) if relative is not None and relative not in self.texts]
        self.texts.update(self.index.read(wanted))

    def read(self, path: Path) -> str:
        relative = self._relative(path)
        if relative is None:
            raise OSError(f"{path} is outside {self.root}")
        if relative not in self.texts:
            self.load([path])
        data = self.texts[relative]
        if data is None:
            raise OSError(f"{relative} is not in the index")
        return data.decode("utf-8")

    def exists(self, path: Path) -> bool:
        relative = self._relative(path)
        if relative is None:
            return Path(os.path.normpath(path)).exists()
        return relative in self.present

    def resolve(self, path: Path) -> Path:
        return Path(os.path.normpath(path))


#: How parent_link reads a ../ target.
SIBLING, OUTSIDE = "sibling", "outside"


def parent_link(document: str, bare: str) -> str | None:
    """Read a relative target from ``document``, a repository path: SIBLING, OUTSIDE or None.

    SIBLING: the first segment after the ../ run names an estate repository, so it is a
    cross-repository link. Read first, so a sibling link one ../ short is still measured
    as one. OUTSIDE: it climbs above the repository root and names no sibling. None: it
    stays inside the repository, deployment/x.md linking ../docs/y.md, so it is a same-repo
    relative link (CORCO-3188). Read from the target as written, so the answer is the same
    on disk, in a worktree and in the index.
    """
    if not bare.startswith("../"):
        return None
    if CROSS_REPO_HEAD.match(bare).group(2).split("/", 1)[0] in ESTATE_REPOS:
        return SIBLING
    landed = posixpath.normpath(posixpath.join(posixpath.dirname(document), bare))
    return OUTSIDE if landed == ".." or landed.startswith("../") else None


def depth_of(path: Path, root: Path) -> int:
    """How many directories below the repository root the file sits."""
    return len(path.relative_to(root).parts) - 1


class Finding:
    __slots__ = ("path", "line", "target", "message", "error")

    def __init__(self, path: str, line: int, target: str, message: str, *, error: bool):
        self.path = path
        self.line = line
        self.target = target
        self.message = message
        self.error = error

    def render(self) -> str:
        return "  %s:%d\n      %s\n      %s" % (self.path, self.line, self.target, self.message)


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def check_file(
    path: Path, root: Path, workspace: CheckoutLayout | None, tree: DiskTree | StagedTree | None = None,
) -> list[Finding]:
    """Every convention violation in one document.

    ``workspace`` is the layout of ``root`` when sibling checkouts sit beside its main
    checkout, and None when only the shape of a cross-repository link can be checked.
    ``tree`` is where the document and its targets are read: the disk by default, or the
    index (StagedTree) for a pre-commit run.
    """
    tree = tree if tree is not None else DiskTree()
    rel = str(path.relative_to(root))
    try:
        raw = tree.read(path)
    except (UnicodeDecodeError, OSError) as exc:
        return [Finding(rel, 1, "<unreadable>", str(exc), error=True)]

    text = strip_code(raw)
    depth = depth_of(path, root)
    findings: list[Finding] = []

    # A raw space ends a link target for CommonMark, so GitHub renders the whole link as
    # literal text, and LINK below never matches it. Report it here, or nothing will.
    linked = {match.start() for match in LINK.finditer(text)}
    for match in LINK_SHAPED.finditer(text):
        if match.start() in linked or not RAW_WHITESPACE.search(match.group(1)):
            continue
        findings.append(
            Finding(
                rel,
                line_of(text, match.start()),
                match.group(1),
                "raw space in the target, so GitHub shows this as literal text; "
                "write each space as %20",
                error=True,
            )
        )

    for match in LINK.finditer(text):
        target = match.group(1)
        if target.startswith(EXTERNAL):
            continue
        line = line_of(text, match.start())
        if target.startswith("file:"):
            # An absolute path on the machine that wrote it. Resolving it as a relative
            # path, as the last branch below would, reports a missing file even where the
            # file exists, which sends whoever fixes it after the wrong problem.
            findings.append(
                Finding(
                    rel,
                    line,
                    target,
                    "file:// URL: an absolute path on one machine, which no other host "
                    "or reader can open",
                    error=True,
                )
            )
            continue
        # Strip the URL fragment before decoding: %23 belongs to the filename.
        # Keep target encoded for diagnostics; only filesystem lookup is decoded.
        bare, _fragment = decode_target(target)
        if not bare:
            continue

        if bare.startswith("/"):
            # Repo-root-absolute: the in-repository convention, checkable here in full.
            if not tree.exists(root / bare.lstrip("/")):
                findings.append(
                    Finding(rel, line, target, "repo-absolute target does not exist", error=True)
                )
            continue

        kind = parent_link(Path(rel).as_posix(), bare)
        if kind is not None:
            prefix, rest = CROSS_REPO_HEAD.match(bare).groups()
            if kind == OUTSIDE:
                findings.append(
                    Finding(
                        rel,
                        line,
                        target,
                        "leaves the repository but does not name a sibling checkout",
                        error=True,
                    )
                )
                continue
            expected = depth + 1
            actual = prefix.count("../")
            if actual != expected:
                off = expected - actual
                how = (
                    "%d level%s short of this file's depth" % (off, "" if off == 1 else "s")
                    if off > 0
                    else "%d ../ too many" % -off
                )
                findings.append(
                    Finding(
                        rel,
                        line,
                        target,
                        "cross-repo link is %s; expected %s%s"
                        % (how, "../" * expected, encode_target(rest)),
                        error=True,
                    )
                )
                continue
            # The depth is right. Existence is only knowable when the sibling is
            # checked out, which CI never is and a workspace usually is. The link is
            # followed from the main checkout, where it was written to work: from a
            # worktree, path.parent / bare lands beside the worktree, not in the estate.
            if workspace is not None and not tree.exists(workspace.on_disk(workspace.logical(path.parent / bare))):
                findings.append(
                    Finding(rel, line, target, "sibling checkout has no such file", error=True)
                )
            continue

        # Anything else is same-repo relative, a ../ that stays inside the repository
        # included. Resolving is the point of the check: a link that does not resolve is
        # broken regardless of convention, and one that does is style drift that breaks
        # when the file moves.
        resolved = tree.resolve(path.parent / bare)
        if not tree.exists(resolved):
            findings.append(Finding(rel, line, target, "relative target does not exist", error=True))
        else:
            try:
                canonical = "/" + encode_target(str(resolved.relative_to(tree.resolve(root))))
            except ValueError:
                canonical = "a path outside the repository"
            findings.append(
                Finding(
                    rel,
                    line,
                    target,
                    "same-repo relative; the convention is repo-absolute: %s" % canonical,
                    error=False,
                )
            )

    return sorted(findings, key=lambda finding: finding.line)


def fix_depths(path: Path, root: Path) -> list[str]:
    """Correct cross-repo links whose ../ count assumes the file sits at the root.

    Only the ../ run is touched, and only when the count is wrong. The rest of the
    target is left exactly as written: this corrects where a link starts from, and has
    no opinion about whether the thing it names is the right thing to name.
    """
    raw = path.read_text(encoding="utf-8")
    depth = depth_of(path, root)
    rel = str(path.relative_to(root))
    changed: list[str] = []

    # Code spans must not be rewritten, so the substitution runs against the original
    # text but consults the stripped copy to decide whether a match is real.
    masked = strip_code(raw)

    def replace(match: re.Match) -> str:
        if masked[match.start() : match.end()].strip() == "":
            return match.group(0)
        prefix, rest = match.group(2), match.group(3)
        if rest.split("/", 1)[0] not in ESTATE_REPOS:
            return match.group(0)
        expected = "../" * (depth + 1)
        if prefix == expected:
            return match.group(0)
        changed.append("  %s\n      %s%s -> %s%s" % (rel, prefix, rest, expected, rest))
        return match.group(1) + expected + rest + match.group(4)

    new = CROSS_REPO.sub(replace, raw)
    if new != raw:
        path.write_text(new, encoding="utf-8")
    return changed


def fix_relative(path: Path, root: Path) -> list[str]:
    """Rewrite same-repo relative links into the repo-root-absolute convention.

    Purely mechanical, and provable: the relative target is resolved against the file's
    own directory, so the rewrite names the identical file and can only be applied when
    that file exists. What changes is that the link survives the document being moved,
    which is the whole point of the convention.

    Safe for the rendered output as well. preprocess_links in export-docs.sh converts a
    repo-absolute target back to a path relative to the directory the render is written
    into, which for a same-directory link is the bare filename it already was.
    """
    raw = path.read_text(encoding="utf-8")
    rel = str(path.relative_to(root))
    resolved_root = root.resolve()
    changed: list[str] = []
    masked = strip_code(raw)

    def replace(match: re.Match) -> str:
        if masked[match.start() : match.end()].strip() == "":
            return match.group(0)
        target = match.group(2)
        if target.startswith(EXTERNAL) or target.startswith("/"):
            return match.group(0)
        bare, fragment = decode_target(target)
        if not bare:
            return match.group(0)
        if parent_link(Path(rel).as_posix(), bare) is not None:
            return match.group(0)
        try:
            resolved = (path.parent / bare).resolve()
            canonical = "/" + encode_target(str(resolved.relative_to(resolved_root)))
        except (ValueError, OSError):
            return match.group(0)
        if not resolved.exists():
            return match.group(0)
        new_target = canonical + ("#" + fragment if fragment else "")
        changed.append("  %s\n      %s -> %s" % (rel, target, new_target))
        return match.group(1) + new_target + match.group(3)

    new = LINK_TARGET.sub(replace, raw)
    if new != raw:
        path.write_text(new, encoding="utf-8")
    return changed


def detect_workspace(root: Path) -> CheckoutLayout | None:
    """The layout of ``root`` in the estate workspace, if its main checkout sits in one.

    A checkout of any other estate repository beside the main checkout is the evidence;
    without one, cross-repository targets are unresolvable and only their shape is
    checked. Git says where the main checkout is, so a linked worktree finds the same
    siblings as its main checkout (CORCO-2841). Where Git cannot place ``root`` -- no
    checkout, or ``CORCO_REPO_ROOT`` naming a folder that is not a checkout's top level --
    ``root`` is read as its own main checkout, as before Git was asked.
    """
    root = root.resolve()
    try:
        layout = CheckoutLayout.read(root)
    except ValueError:
        layout = None
    if layout is None or layout.checkout != root:
        layout = CheckoutLayout(root, root, root.name if root.name in ESTATE_REPOS else None)
    return layout if layout.siblings() else None


def staged_documents(root: Path, tree: StagedTree) -> list[Path]:
    """The Markdown a staged change can break, as repository paths under ``root``.

    Each staged document, or every tracked one when the commit deletes a path: a
    deletion, or a rename read as one, can break a link in a document the commit leaves
    alone.
    """
    changes = staged_changes(root)
    if any(status == "D" for status, _ in changes):
        names = tree.index.tracked
    else:
        names = {path for _, path in changes}
    return sorted(
        root / name for name in names
        if name.endswith(".md") and PurePosixPath(name).name not in GENERATED and name in tree.index.tracked
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="corco-docs-links",
        description="Resolve every Markdown link in a repository against the estate's "
        "link conventions.",
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help="rewrite cross-repository links whose ../ count is wrong for the file's depth",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail on convention warnings as well as broken links",
    )
    parser.add_argument(
        "--staged",
        action="store_true",
        help="read the index and check the Markdown a staged change can break (pre-commit); "
        "cross-repository targets are checked for their shape only, as in CI",
    )
    args = parser.parse_args(argv)
    if args.fix and args.staged:
        parser.error("--fix rewrites the working tree and --staged reads the index; run --fix, stage the result, then --staged")

    try:
        root = repo_root()
    except RepoRootError as exc:
        print("corco-docs-links: %s" % exc, file=sys.stderr)
        return 2

    if args.staged:
        try:
            tree = StagedTree(root)
            files = staged_documents(root, tree)
            tree.load(files)
        except GitError as exc:
            print("corco-docs-links: did not run: %s" % exc, file=sys.stderr)
            return 2
        if not files:
            print("corco-docs-links: no staged change can break a Markdown link in %s" % root.name)
            return 0
        return report(files, root, None, tree, strict=args.strict, scope="staged ",
                      note="  (cross-repo targets checked for shape only, as in CI)")

    files = sorted(markdown_files(root))
    if not files:
        print("corco-docs-links: no Markdown found under %s, which cannot be right." % root)
        return 2

    if args.fix:
        depths, relatives = [], []
        for path in files:
            depths.extend(fix_depths(path, root))
            relatives.extend(fix_relative(path, root))
        for label, entries in (("cross-repository", depths), ("same-repo relative", relatives)):
            if entries:
                print("\n".join(entries))
            print(
                "rewrote %d %s link%s"
                % (len(entries), label, "" if len(entries) == 1 else "s")
            )
        print()

    workspace = detect_workspace(root)
    return report(files, root, workspace, DiskTree(), strict=args.strict, scope="",
                  note="" if workspace else "  (no sibling checkouts: cross-repo targets checked for shape only)")


def report(
    files: list[Path], root: Path, workspace: CheckoutLayout | None, tree: DiskTree | StagedTree,
    *, strict: bool, scope: str, note: str,
) -> int:
    """Check ``files``, print the findings and return the exit status."""
    findings: list[Finding] = []
    for path in files:
        findings.extend(check_file(path, root, workspace, tree))

    errors = [f for f in findings if f.error]
    warnings = [f for f in findings if not f.error]

    print(
        "checked %d %sdocument%s in %s%s"
        % (
            len(files),
            scope,
            "" if len(files) == 1 else "s",
            root.name,
            note,
        )
    )

    if errors:
        print("\n%d broken link%s" % (len(errors), "" if len(errors) == 1 else "s"))
        for finding in errors:
            print(finding.render())
    if warnings:
        print(
            "\n%d convention warning%s" % (len(warnings), "" if len(warnings) == 1 else "s")
        )
        for finding in warnings:
            print(finding.render())
    if not findings:
        print("no findings")

    if errors:
        return 1
    if warnings and strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
