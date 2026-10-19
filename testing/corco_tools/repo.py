"""Which repository the tooling is operating on.

In the monorepo a tool could infer this from its own location: `tools/` sat one
level below the only repository there was. That accident is gone. corco-tools is
now installed into a venv, so there are two unrelated paths and confusing them
is the whole class of bug this module exists to prevent:

  * where the tooling lives    - `Path(__file__).parent`, for the tool's own
                                 assets (the mermaid configs, the shell scripts)
  * which repository it acts on - this module, resolved from the environment,
                                 from the target the caller names, or from the
                                 current directory

Nothing here may look at the package's own location.

The second question is where that repository's checkout sits in the estate, the
one folder that holds the main checkout of every repository side by side. A
sibling-relative link such as ../corco-gtm/sales/docs/SALES.md means something
only from a main checkout; a linked worktree sits at <repo>/.claude/worktrees/<name>,
at <repo>/.claude/worktrees/<id>/<repo>, or outside the repository altogether,
and the folder beside it is not the estate. `CheckoutLayout` answers it from Git,
never from folder names: the main checkout is the parent of the common Git
directory, and the estate is the main checkout's parent. The PDF link repair and
the link check both read it here (CORCO-2828, CORCO-2833, CORCO-2841), so a
worktree accepts and refuses exactly the links its main checkout does.

The third question is what the commit being made holds. `StagedIndex` and
`staged_changes` read it from the index for the pre-commit checks, the render
check and the link check alike, so neither keeps its own reader (CORCO-3188).

Standard library only: the doc-links action and the copy vendored in
corco-installer run check_doc_links, which imports this module, without
installing anything.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

#: Per-repository documentation manifest: section order, section titles and the
#: combined output path. It lives in the consuming repository, not here, because
#: the sections are that tier's structure and shared tooling must not encode it.
DOC_ORDER_FILENAME = "doc-order.json"

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


class RepoRootError(RuntimeError):
    """The repository to operate on could not be determined."""


def repo_root(start: Path | None = None) -> Path:
    """Return the root of the repository this invocation should operate on.

    `CORCO_REPO_ROOT` wins, so a caller (the console wrappers, a CI job, a cron
    entry) can be explicit. Otherwise the enclosing git checkout of ``start``,
    a folder or a file in it. A caller that knows its target names it here, so
    the answer does not depend on where the command was run from (CORCO-3106).
    Without ``start``, the current directory, which is what a person running
    the command in a repo means.
    """
    explicit = os.environ.get("CORCO_REPO_ROOT")
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_dir():
            raise RepoRootError(f"CORCO_REPO_ROOT is not a directory: {path}")
        return path.resolve()

    folder = Path.cwd() if start is None else Path(start).resolve()
    if not folder.is_dir():
        folder = folder.parent
    try:
        toplevel = run_git(folder, "rev-parse", "--show-toplevel").stdout.strip()
    except OSError:
        toplevel = ""

    if not toplevel:
        if start is not None:
            raise RepoRootError(
                f"{Path(start).resolve()} is in no Git repository checkout, so there is "
                "no repository to operate on. Name a file inside a checkout, or set "
                "CORCO_REPO_ROOT to the repository's root."
            )
        raise RepoRootError(
            "cannot tell which repository to operate on. Run this from inside a "
            "repository checkout, or set CORCO_REPO_ROOT to its root."
        )
    return Path(toplevel).resolve()


def doc_order_path() -> Path:
    """Return the path to the current repository's documentation manifest."""
    return repo_root() / DOC_ORDER_FILENAME


def run_git(checkout: Path, *arguments: str) -> subprocess.CompletedProcess:
    """Run one git command in ``checkout`` and return it; the caller reads the exit status."""
    return subprocess.run(  # noqa: S603  fixed argv, no shell; checkout is a path this process resolved
        ["git", "-C", str(checkout), *arguments],  # noqa: S607  git intentionally resolved from PATH
        capture_output=True, text=True, check=False,
    )


class GitError(RuntimeError):
    """A git command could not run or failed, so what it would have said is unknown: never a pass."""


def git_output(checkout: Path, *arguments: str, stdin: bytes | None = None) -> bytes:
    """Run one git command in ``checkout`` and return its standard output; GitError when it fails."""
    try:
        completed = subprocess.run(  # noqa: S603  fixed argv, no shell; paths come from git itself
            ["git", "-C", str(checkout), *arguments],  # noqa: S607  git intentionally resolved from PATH
            input=stdin, capture_output=True, check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = (getattr(error, "stderr", b"") or b"").decode(errors="replace").strip()
        raise GitError(f"git {arguments[0]} failed in {checkout}: {detail or error}") from error
    return completed.stdout


def split_z(output: bytes) -> list[str]:
    """The paths of NUL-separated git output (-z), in order."""
    return [item.decode("utf-8", errors="surrogateescape") for item in output.split(b"\0") if item]


class StagedIndex:
    """Tracked paths and their staged contents, read from the index: what the commit being made will hold.

    The pre-commit checks read this, never the disk, so a fix made on disk and not staged
    still fails (corco-docs-exports --staged, corco-docs-links --staged).
    """

    def __init__(self, root: Path) -> None:
        self.root = root
        self.tracked = set(split_z(git_output(root, "ls-files", "-z", "--cached")))

    def read(self, paths: list[str]) -> dict[str, bytes | None]:
        """The staged bytes of each path, None for a path the index does not hold."""
        wanted = [path for path in paths if path in self.tracked]
        contents: dict[str, bytes | None] = {path: None for path in paths}
        if not wanted:
            return contents
        if any("\n" in path for path in wanted):
            raise GitError("a staged path contains a newline, which git cat-file --batch cannot address")
        # One process for every blob rather than one per file: a re-export commit
        # stages hundreds of renders.
        output = git_output(self.root, "cat-file", "--batch", stdin="".join(f":{path}\n" for path in wanted).encode())
        position = 0
        for path in wanted:
            end = output.index(b"\n", position)
            header = output[position:end].split()
            position = end + 1
            if header[-1] == b"missing":
                continue
            size = int(header[2])
            contents[path] = output[position:position + size]
            position += size + 1
        return contents


def staged_changes(root: Path) -> list[tuple[str, str]]:
    """(status letter, path) of every staged change; a rename reads as a deletion plus an addition."""
    fields = split_z(git_output(root, "diff", "--cached", "--name-status", "-z", "--no-renames"))
    return list(zip(fields[0::2], fields[1::2], strict=True))


def remote_name(url: str) -> str | None:
    """Name the estate repository an origin URL points at, or None."""
    name = url.strip().rstrip("/").replace(":", "/").rsplit("/", 1)[-1]
    name = name.removesuffix(".git")
    return name if name in ESTATE_REPOS else None


@dataclass(frozen=True)
class CheckoutLayout:
    """Where a checkout sits in the estate, read from Git itself.

    ``checkout`` is the working tree a tool runs in: the main checkout or any linked
    worktree, wherever it sits and whatever its folder is called. ``main`` is the main
    checkout of the same repository, the folder that sits in the estate beside its
    siblings. ``name`` is the repository's estate name, from the origin remote, else
    from the main checkout's folder name, else None.

    A relative link is read as the link it was written as, replayed from ``main``
    (``logical``), so a worktree accepts and refuses exactly the links its main checkout
    does. A target inside ``main`` is then looked up in ``checkout`` (``on_disk``),
    because the worktree holds the branch under test; a target in a sibling is looked
    up in that sibling's main checkout beside ``main``.
    """

    checkout: Path
    main: Path
    name: str | None

    @property
    def estate(self) -> Path:
        """The folder that holds the main checkout and its siblings."""
        return self.main.parent

    @classmethod
    def read(cls, repo: Path) -> "CheckoutLayout":
        """Read the layout of the Git checkout at ``repo``.

        Raises ValueError when ``repo`` is in no Git checkout, or when its common Git
        directory is not a ``.git`` folder inside a main checkout (a submodule or a
        bare repository), so that no main checkout can be placed in the estate.
        """
        checkout = repo.resolve()
        try:
            result = run_git(checkout, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir")
        except OSError as error:
            raise ValueError(f"cannot run git, so {checkout} cannot be placed in the estate: {error}") from None
        lines = result.stdout.splitlines()
        if result.returncode != 0 or len(lines) != 2:
            raise ValueError(f"not a Git checkout, so it cannot be placed in the estate: {checkout}")
        checkout, common = (Path(line).resolve() for line in lines)
        if common.name != ".git":
            raise ValueError(f"Git checkout {checkout} has no main checkout beside its siblings (common Git directory {common})")
        main = common.parent
        origin = run_git(main, "config", "--get", "remote.origin.url")
        name = remote_name(origin.stdout) if origin.returncode == 0 else None
        if name is None and main.name in ESTATE_REPOS:
            name = main.name
        return cls(checkout, main, name)

    def logical(self, path: Path) -> Path:
        """Return where ``path``, a path under ``checkout``, points when the same link is followed from ``main``."""
        return Path(os.path.normpath(self.main / os.path.relpath(path, self.checkout)))

    def on_disk(self, logical: Path) -> Path:
        """Return where to look ``logical`` up: in ``checkout`` for a target inside ``main``, else unchanged."""
        if logical.is_relative_to(self.main):
            return self.checkout / logical.relative_to(self.main)
        return logical

    def siblings(self) -> list[Path]:
        """The other estate repositories that are checked out beside ``main``."""
        return [self.estate / name for name in sorted(ESTATE_REPOS)
                if name != self.main.name and (self.estate / name).is_dir()]

    def place(self, logical: Path, uri: str) -> tuple[Path, Path, str | None] | None:
        """Return the checkout that tracks ``logical``, its path there and its repository name.

        None means the target is in no estate repository. A target in a sibling whose
        main checkout is not a Git checkout is a ValueError that names the folder.
        """
        if logical.is_relative_to(self.main):
            return self.checkout, self.on_disk(logical), self.name
        if not logical.is_relative_to(self.estate):
            return None
        parts = logical.relative_to(self.estate).parts
        if len(parts) < 2 or parts[0] not in ESTATE_REPOS:
            return None
        sibling = self.estate / parts[0]
        result = run_git(sibling, "rev-parse", "--path-format=absolute", "--show-toplevel")
        if result.returncode != 0 or Path(result.stdout.strip()).resolve() != sibling.resolve():
            raise ValueError(f"local link points into {parts[0]}, but {sibling} is not a Git checkout: {uri}")
        return sibling, logical, parts[0]
