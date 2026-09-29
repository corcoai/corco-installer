"""Which repository the tooling is operating on.

In the monorepo a tool could infer this from its own location: `tools/` sat one
level below the only repository there was. That accident is gone. corco-tools is
now installed into a venv, so there are two unrelated paths and confusing them
is the whole class of bug this module exists to prevent:

  * where the tooling lives    - `Path(__file__).parent`, for the tool's own
                                 assets (the mermaid configs, the shell scripts)
  * which repository it acts on - this module, resolved from the environment or
                                 from the current directory

Nothing here may look at the package's own location.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

#: Per-repository documentation manifest: section order, section titles and the
#: combined output path. It lives in the consuming repository, not here, because
#: the sections are that tier's structure and shared tooling must not encode it.
DOC_ORDER_FILENAME = "doc-order.json"


class RepoRootError(RuntimeError):
    """The repository to operate on could not be determined."""


def repo_root() -> Path:
    """Return the root of the repository this invocation should operate on.

    `CORCO_REPO_ROOT` wins, so a caller (the console wrappers, a CI job, a cron
    entry) can be explicit. Otherwise the enclosing git checkout of the current
    directory, which is what a person running the command in a repo means.
    """
    explicit = os.environ.get("CORCO_REPO_ROOT")
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_dir():
            raise RepoRootError(f"CORCO_REPO_ROOT is not a directory: {path}")
        return path.resolve()

    try:
        completed = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],  # noqa: S607  git intentionally resolved from PATH
            capture_output=True,
            text=True,
            check=True,
        )
        toplevel = completed.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        toplevel = ""

    if not toplevel:
        raise RepoRootError(
            "cannot tell which repository to operate on. Run this from inside a "
            "repository checkout, or set CORCO_REPO_ROOT to its root."
        )
    return Path(toplevel).resolve()


def doc_order_path() -> Path:
    """Return the path to the current repository's documentation manifest."""
    return repo_root() / DOC_ORDER_FILENAME
