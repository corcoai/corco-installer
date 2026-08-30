#!/bin/bash
#
# The token PROMPT route, which TUTORIAL.md now teaches in preference to --token=.
#
# It is exercised on a real terminal rather than asserted from the source, for the reason
# the teardown prompt test gives: the prompt only behaves like a prompt when stdin is a
# terminal, so reading the source tells you what was intended and not what happens.
#
# Three properties, and the second is the one that made this test necessary. Until
# 2026-08-30 the prompt used `read -r` without -s, so it ECHOED the token to the screen --
# into the terminal scrollback and into whatever session recording the environment keeps,
# and Cloud Shell keeps one. Teaching this route in the tutorial while it did that would
# have moved the token from the customer's shell history to their screen, which is worse:
# scrollback is read by anyone glancing at the display and outlives the process.
#
# What this route does NOT remove is stated plainly here so nobody reads a stronger claim
# into it. `launch_main_setup` still passes --token=<value> to the release's own
# deployment/scripts/setup.sh, so the token is in THAT process's argv either way. The
# prompt removes it from the customer's shell history and from this bootstrap's argv,
# which is the persistent half; the inner script's argv is a corco-platform contract and
# is not this script's to change.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/../setup.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

MOCK_BIN="$TEMP_DIR/mock-bin"
PACKAGE_DIR="$TEMP_DIR/package"
RELEASE_ARCHIVE="$TEMP_DIR/release.tar.gz"
ARGUMENT_CAPTURE="$TEMP_DIR/arguments"
READY_FILE="$TEMP_DIR/main-setup-ready"
mkdir -p "$MOCK_BIN" "$PACKAGE_DIR/deployment/scripts"

# Distinctive enough that finding it in the pty transcript cannot be a coincidence, and
# not a substring of anything the script prints on its own. Deliberately low-entropy and
# self-describing rather than random-looking: a high-entropy fixture trips the repository's
# own gitleaks hook as a generic-api-key, and the right answer to that is a string nobody
# could mistake for a credential, not an allowlist entry that teaches the scanner to skip
# a line.
PROMPT_TOKEN="not-a-real-token-only-typed-at-the-prompt"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The same stub the other two suites use: it refuses the token in argv or in the URL, so
# this suite inherits those guarantees on the prompt route rather than restating them.
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'output_file=""' \
    'url=""' \
    'config_source=""' \
    'argv_seen="$*"' \
    'while [ "$#" -gt 0 ]; do' \
    '    case "$1" in' \
    '        -o) output_file=$2; shift 2 ;;' \
    '        --config) config_source=$2; shift 2 ;;' \
    '        https://*) url=$1; shift ;;' \
    '        *) shift ;;' \
    '    esac' \
    'done' \
    'case "$argv_seen" in' \
    '    *"$TEST_PROMPT_TOKEN"*)' \
    '        echo "setup token found in curl argv: $argv_seen" >&2' \
    '        exit 1' \
    '        ;;' \
    'esac' \
    'if [ "$config_source" = "-" ]; then' \
    '    while IFS= read -r config_line; do' \
    '        case "$config_line" in' \
    '            url\ =\ *)' \
    '                url=${config_line#url = \"}' \
    '                url=${url%\"}' \
    '                ;;' \
    '        esac' \
    '    done' \
    'fi' \
    'case "$url" in' \
    '    *"$TEST_PROMPT_TOKEN"*)' \
    '        echo "setup token found in the URL: $url" >&2' \
    '        exit 1' \
    '        ;;' \
    'esac' \
    'case "$url" in' \
    '    */api/download)' \
    '        printf "{\"download_url\":\"https://download.example/release.tar.gz\",\"sha256\":\"%s\",\"version\":\"v-test\"}" "$TEST_RELEASE_SHA256"' \
    '        ;;' \
    '    */api/client)' \
    '        printf "%s" "{\"domain\":\"example.test\",\"company_name\":\"Example\",\"consultant_email\":\"support@example.test\"}"' \
    '        ;;' \
    '    https://download.example/release.tar.gz)' \
    '        cp "$TEST_RELEASE_ARCHIVE" "$output_file"' \
    '        ;;' \
    '    *)' \
    '        echo "unexpected curl URL: $url" >&2' \
    '        exit 1' \
    '        ;;' \
    'esac' > "$MOCK_BIN/curl"
chmod +x "$MOCK_BIN/curl"

printf '%s\n' '#!/bin/bash' 'exit 0' > "$MOCK_BIN/clear"
chmod +x "$MOCK_BIN/clear"

# The `--resume)` arm is not decoration. launch_main_setup greps the DOWNLOADED script for
# an arm matching each forwarded option and refuses the run when it finds none, so a
# release that predates a flag cannot be handed one. A fixture without it never reaches
# the launch, and this suite would then report a prompt failure for a capability reason.
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$@" > "$TEST_ARGUMENT_CAPTURE"' \
    ': > "$TEST_READY_FILE"' \
    'exit 0' \
    '# Never executed. It exists because the capability check is a grep over this file' \
    '# rather than a call into it, so the arm has to be present as TEXT.' \
    'case "$1" in' \
    '        --resume)' \
    '            ;;' \
    'esac' \
    > "$PACKAGE_DIR/deployment/scripts/setup.sh"
chmod +x "$PACKAGE_DIR/deployment/scripts/setup.sh"
tar -czf "$RELEASE_ARCHIVE" -C "$PACKAGE_DIR" deployment

if command -v sha256sum >/dev/null 2>&1; then
    RELEASE_SHA256=$(sha256sum "$RELEASE_ARCHIVE" | awk '{print $1}')
else
    RELEASE_SHA256=$(shasum -a 256 "$RELEASE_ARCHIVE" | awk '{print $1}')
fi

# Invoked as ./setup.sh with a forwarding flag and NO --token, which is exactly the shape
# TUTORIAL.md teaches for resume, reuse and upgrade.
DRIVER="$TEMP_DIR/run-prompted-bootstrap.sh"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'run_dir=$(mktemp -d "$TEST_TEMP_DIR/run.XXXXXX")' \
    'cd "$run_dir"' \
    'exec env -u TERM \' \
    '    TEST_ARGUMENT_CAPTURE="$TEST_ARGUMENT_CAPTURE" \' \
    '    TEST_PROMPT_TOKEN="$TEST_PROMPT_TOKEN" \' \
    '    TEST_READY_FILE="$TEST_READY_FILE" \' \
    '    TEST_RELEASE_ARCHIVE="$TEST_RELEASE_ARCHIVE" \' \
    '    TEST_RELEASE_SHA256="$TEST_RELEASE_SHA256" \' \
    '    PATH="$TEST_MOCK_BIN:/usr/bin:/bin" \' \
    '    bash "$TEST_SETUP_SCRIPT" --resume' \
    > "$DRIVER"
chmod +x "$DRIVER"

export TEST_ARGUMENT_CAPTURE="$ARGUMENT_CAPTURE"
export TEST_MOCK_BIN="$MOCK_BIN"
export TEST_PROMPT_TOKEN="$PROMPT_TOKEN"
export TEST_READY_FILE="$READY_FILE"
export TEST_RELEASE_ARCHIVE="$RELEASE_ARCHIVE"
export TEST_RELEASE_SHA256="$RELEASE_SHA256"
export TEST_SETUP_SCRIPT="$SETUP_SCRIPT"
export TEST_TEMP_DIR="$TEMP_DIR"

run_with_controlling_terminal() {
    case "$(uname -s)" in
        Darwin) script -q -e /dev/null "$DRIVER" ;;
        Linux) script -q -e -c "$DRIVER" /dev/null ;;
        *) fail "unsupported platform for the setup prompt test" ;;
    esac
}

PTY_OUTPUT="$TEMP_DIR/pty-output"
: > "$PTY_OUTPUT"

# The token is typed only once the prompt is on screen. read -rs turns the terminal's echo
# off before it writes the prompt, so anything sent earlier is echoed by the tty driver
# and would fail the no-echo assertion for a reason that is the harness's rather than the
# script's.
FEEDER="$TEMP_DIR/feed-terminal-token.sh"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'for _ in $(seq 1 1000); do' \
    '    if grep -Fq "Setup Token" "$TEST_PTY_OUTPUT" 2>/dev/null; then' \
    '        printf "%s\n" "$TEST_PROMPT_TOKEN"' \
    '        exit 0' \
    '    fi' \
    '    sleep 0.01' \
    'done' \
    'echo "the setup script never asked for the token" >&2' \
    'exit 72' \
    > "$FEEDER"
chmod +x "$FEEDER"
export TEST_PTY_OUTPUT="$PTY_OUTPUT"

set +e
"$FEEDER" | run_with_controlling_terminal >> "$PTY_OUTPUT" 2>&1
prompt_exit_codes=("${PIPESTATUS[@]}")
set -e
if [ "${prompt_exit_codes[0]}" -ne 0 ]; then
    sed -n '1,120p' "$PTY_OUTPUT" >&2
    fail "the setup script never reached the token prompt"
fi

# 1. The route exists at all. Without this the two assertions below pass vacuously on a
#    run that errored out before ever asking.
grep -Fq "Setup Token" "$PTY_OUTPUT" \
    || fail "the script did not ask for the token on a terminal"

# 2. The token is not echoed. This is what -s buys, and it is the whole reason the
#    tutorial can prefer this route to --token=.
if grep -Fq "$PROMPT_TOKEN" "$PTY_OUTPUT"; then
    fail "the token prompt echoed the token into the terminal transcript"
fi

# 3. Taking the token by prompt did not cost the forwarding the tutorial documents
#    alongside it. A prompt that silently dropped --resume would be a worse trade than
#    the exposure it closes.
if [ ! -f "$ARGUMENT_CAPTURE" ]; then
    # The transcript, not just the verdict: everything after the prompt happens on the
    # pty and is otherwise discarded with the temp directory.
    sed -n '1,120p' "$PTY_OUTPUT" | tr -d '\r' >&2
    fail "the release setup script was never launched"
fi
grep -Fxq -- "--resume" "$ARGUMENT_CAPTURE" \
    || fail "the prompt route dropped --resume on the way to the release setup script"
grep -Fxq -- "--token=$PROMPT_TOKEN" "$ARGUMENT_CAPTURE" \
    || fail "the release setup script did not receive the prompted token"

echo "setup token prompt regression test passed"
