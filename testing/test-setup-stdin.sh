#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/../setup.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

MOCK_BIN="$TEMP_DIR/mock-bin"
PACKAGE_DIR="$TEMP_DIR/package"
RELEASE_ARCHIVE="$TEMP_DIR/release.tar.gz"
INPUT_CAPTURE="$TEMP_DIR/input"
ARGUMENT_CAPTURE="$TEMP_DIR/arguments"
READY_FILE="$TEMP_DIR/main-setup-ready"
mkdir -p "$MOCK_BIN" "$PACKAGE_DIR/deployment/scripts"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'output_file=""' \
    'url=""' \
    'while [ "$#" -gt 0 ]; do' \
    '    case "$1" in' \
    '        -o) output_file=$2; shift 2 ;;' \
    '        https://*) url=$1; shift ;;' \
    '        *) shift ;;' \
    '    esac' \
    'done' \
    'case "$url" in' \
    '    */api/download/*)' \
    '        printf "{\"download_url\":\"https://download.example/release.tar.gz\",\"sha256\":\"%s\",\"version\":\"v-test\"}" "$TEST_RELEASE_SHA256"' \
    '        ;;' \
    '    */api/client/*)' \
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

printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    ': > "$TEST_READY_FILE"' \
    'if ! IFS= read -r response; then' \
    '    echo "MAIN_SETUP_EOF" >&2' \
    '    exit 70' \
    'fi' \
    'printf "%s\n" "$response" > "$TEST_INPUT_CAPTURE"' \
    'printf "%s\n" "$@" > "$TEST_ARGUMENT_CAPTURE"' \
    > "$PACKAGE_DIR/deployment/scripts/setup.sh"
chmod +x "$PACKAGE_DIR/deployment/scripts/setup.sh"
tar -czf "$RELEASE_ARCHIVE" -C "$PACKAGE_DIR" deployment

if command -v sha256sum >/dev/null 2>&1; then
    RELEASE_SHA256=$(sha256sum "$RELEASE_ARCHIVE" | awk '{print $1}')
else
    RELEASE_SHA256=$(shasum -a 256 "$RELEASE_ARCHIVE" | awk '{print $1}')
fi

DRIVER="$TEMP_DIR/run-piped-bootstrap.sh"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'run_dir=$(mktemp -d "$TEST_TEMP_DIR/run.XXXXXX")' \
    'cd "$run_dir"' \
    'cat "$TEST_SETUP_SCRIPT" | env -u TERM \
        TEST_RELEASE_ARCHIVE="$TEST_RELEASE_ARCHIVE" \
        TEST_RELEASE_SHA256="$TEST_RELEASE_SHA256" \
        TEST_INPUT_CAPTURE="$TEST_INPUT_CAPTURE" \
        TEST_ARGUMENT_CAPTURE="$TEST_ARGUMENT_CAPTURE" \
        PATH="$TEST_MOCK_BIN:/usr/bin:/bin" \
        bash -s -- --token=test-token' \
    > "$DRIVER"
chmod +x "$DRIVER"

export TEST_ARGUMENT_CAPTURE="$ARGUMENT_CAPTURE"
export TEST_INPUT_CAPTURE="$INPUT_CAPTURE"
export TEST_MOCK_BIN="$MOCK_BIN"
export TEST_READY_FILE="$READY_FILE"
export TEST_RELEASE_ARCHIVE="$RELEASE_ARCHIVE"
export TEST_RELEASE_SHA256="$RELEASE_SHA256"
export TEST_SETUP_SCRIPT="$SETUP_SCRIPT"
export TEST_TEMP_DIR="$TEMP_DIR"

run_with_controlling_terminal() {
    case "$(uname -s)" in
        Darwin) script -q -e /dev/null "$DRIVER" ;;
        Linux) script -q -e -c "$DRIVER" /dev/null ;;
        *) fail "unsupported platform for controlling-terminal regression test" ;;
    esac
}

FEEDER="$TEMP_DIR/feed-terminal-input.sh"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'for _ in $(seq 1 500); do' \
    '    if [ -e "$TEST_READY_FILE" ]; then' \
    '        printf "%s\n" "interactive-response"' \
    '        exit 0' \
    '    fi' \
    '    sleep 0.01' \
    'done' \
    'echo "main setup did not become ready for terminal input" >&2' \
    'exit 72' \
    > "$FEEDER"
chmod +x "$FEEDER"

PTY_OUTPUT="$TEMP_DIR/pty-output"
set +e
"$FEEDER" | run_with_controlling_terminal > "$PTY_OUTPUT" 2>&1
pipeline_exit_codes=("${PIPESTATUS[@]}")
set -e
if [ "${pipeline_exit_codes[0]}" -ne 0 ] || [ "${pipeline_exit_codes[1]}" -ne 0 ]; then
    sed -n '1,200p' "$PTY_OUTPUT" >&2
    fail "piped bootstrap did not give the main setup its controlling terminal"
fi

printf '%s\n' 'interactive-response' > "$TEMP_DIR/expected-input"
cmp "$TEMP_DIR/expected-input" "$INPUT_CAPTURE" \
    || fail "main setup did not receive input from the controlling terminal"

printf '%s\n' \
    '--token=test-token' \
    '--domain=example.test' \
    '--consultant=support@example.test' > "$TEMP_DIR/expected-arguments"
cmp "$TEMP_DIR/expected-arguments" "$ARGUMENT_CAPTURE" \
    || fail "stdin routing changed setup argument forwarding"

# CI and other detached runners have no controlling terminal. In that state the
# bootstrap must preserve inherited EOF instead of blocking or failing to launch.
if ! ( : </dev/tty ) 2>/dev/null; then
    NO_TTY_OUTPUT="$TEMP_DIR/no-tty-output"
    set +e
    "$DRIVER" </dev/null > "$NO_TTY_OUTPUT" 2>&1
    no_tty_exit_code=$?
    set -e
    [ "$no_tty_exit_code" -eq 70 ] \
        || fail "no-TTY bootstrap did not preserve the main setup exit status"
    grep -Fq 'MAIN_SETUP_EOF' "$NO_TTY_OUTPUT" \
        || fail "no-TTY bootstrap did not preserve deterministic EOF"
fi

echo "setup stdin routing regression test passed"
