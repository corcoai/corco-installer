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
checked out -- an operator's workspace -- the target's existence is checked as well.

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
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

from .repo import RepoRootError, repo_root

#: The repositories of the corcoai estate, as the workspace CLAUDE.md lists them. A ../
#: target whose first segment is one of these is a cross-repository link and is measured
#: against the sibling-relative convention; anything else beginning with ../ is a file
#: reaching outside its own repository for something that is not a sibling checkout,
#: which is reported rather than guessed at.
ESTATE_REPOS = frozenset(
    {
        "corco-platform",
        "corco-voyages",
        "corco-installer",
        "corco-tools",
        "corco-gtm",
        "corco-web",
        "corco-corporate",
        "corco-sheets-ai",
        "corco-prod",
    }
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

# Any inline link, split so the target alone can be replaced.
LINK_TARGET = re.compile(r"(\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")

FENCE = re.compile(r"^\s*(?:```|~~~)")

# Targets that name something other than a path in this filesystem.
EXTERNAL = ("http://", "https://", "mailto:", "tel:", "ftp://", "#")


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


def check_file(path: Path, root: Path, workspace: Path | None) -> list[Finding]:
    """Every convention violation in one document."""
    rel = str(path.relative_to(root))
    try:
        raw = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError) as exc:
        return [Finding(rel, 1, "<unreadable>", str(exc), error=True)]

    text = strip_code(raw)
    depth = depth_of(path, root)
    findings: list[Finding] = []

    # A raw space ends a link target for CommonMark, so GitHub renders the whole link as
    # literal text, and LINK below never matches it. Report it here, or nothing will.
    linked = {match.start() for match in LINK.finditer(text)}
    for match in LINK_SHAPED.finditer(text):
        if match.start() in linked or not re.search(r"\s", match.group(1)):
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
        bare = unquote(target.split("#", 1)[0])
        if not bare:
            continue

        if bare.startswith("/"):
            # Repo-root-absolute: the in-repository convention, checkable here in full.
            if not (root / bare.lstrip("/")).exists():
                findings.append(
                    Finding(rel, line, target, "repo-absolute target does not exist", error=True)
                )
            continue

        if bare.startswith("../"):
            prefix = re.match(r"(?:\.\./)+", bare).group(0)
            rest = bare[len(prefix) :]
            head = rest.split("/", 1)[0]
            if head not in ESTATE_REPOS:
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
                        "cross-repo link is %s; expected %s%s" % (how, "../" * expected, rest),
                        error=True,
                    )
                )
                continue
            # The depth is right. Existence is only knowable when the sibling is
            # checked out, which CI never is and a workspace usually is.
            if workspace is not None and not (path.parent / bare).exists():
                findings.append(
                    Finding(rel, line, target, "sibling checkout has no such file", error=True)
                )
            continue

        # Anything else is same-repo relative. Resolving is the point of the check: a
        # link that does not resolve is broken regardless of convention, and one that
        # does is style drift that breaks when the file moves.
        resolved = (path.parent / bare).resolve()
        if not resolved.exists():
            findings.append(Finding(rel, line, target, "relative target does not exist", error=True))
        else:
            try:
                canonical = "/" + str(resolved.relative_to(root.resolve()))
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
        if target.startswith(EXTERNAL) or target.startswith(("/", "../")):
            return match.group(0)
        bare, _, fragment = target.partition("#")
        if not bare:
            return match.group(0)
        try:
            resolved = (path.parent / bare).resolve()
            canonical = "/" + str(resolved.relative_to(resolved_root))
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


def detect_workspace(root: Path) -> Path | None:
    """The estate workspace, if this repository is checked out inside one.

    A sibling checkout of any other estate repository is the evidence. Without one,
    cross-repository targets are unresolvable and only their shape is checked.
    """
    parent = root.parent
    for name in ESTATE_REPOS:
        if name != root.name and (parent / name).is_dir():
            return parent
    return None


def main() -> int:
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
    args = parser.parse_args()

    try:
        root = repo_root()
    except RepoRootError as exc:
        print("corco-docs-links: %s" % exc, file=sys.stderr)
        return 2

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
    findings: list[Finding] = []
    for path in files:
        findings.extend(check_file(path, root, workspace))

    errors = [f for f in findings if f.error]
    warnings = [f for f in findings if not f.error]

    print(
        "checked %d document%s in %s%s"
        % (
            len(files),
            "" if len(files) == 1 else "s",
            root.name,
            "" if workspace else "  (no sibling checkouts: cross-repo targets checked for shape only)",
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
    if warnings and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
