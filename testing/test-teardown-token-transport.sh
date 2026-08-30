#!/bin/bash
#
# The teardown token and the tenant's Telegram bot token must never appear in a command
# line. This script runs in Google Cloud Shell, a VM the operator shares with everything
# else they happen to be running, and /proc/<pid>/cmdline is world-readable for as long
# as the process lives -- minutes, for a teardown. There are two surfaces:
#
#   curl's argv       -- a request body given as `-d "{...}"`, or a credential inside the
#                        URL, as the Telegram Bot API's path segment is
#   this script's own -- `./teardown.sh <domain> --token=<value>`, which is also written
#                        to the operator's shell history
#
# Both halves are asserted for every credential: that it LEFT argv, and that it is STILL
# SENT. An absence assertion alone passes on a script that stopped authenticating at all,
# which would leave a tenant recorded as active after it was destroyed, and a live
# Telegram webhook pointing at a deleted project.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_TEARDOWN="$SCRIPT_DIR/../teardown.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

DOMAIN="example.test"
PROJECT_ID="example-project"

# The value that authorizes deleting a whole tenant. Every assertion below is keyed to
# it, so a run that carried a different token would fail rather than pass quietly.
TEARDOWN_TOKEN_SENTINEL="teardown-token-that-must-never-reach-argv"  # noqa - fixture
# The tenant's LIVE Telegram bot token, which the pre-deletion cleanup reads out of
# Secret Manager to deregister the webhook. It is the one credential here that cannot be
# moved into a body or a header: the Telegram Bot API authenticates by URL PATH alone, so
# the URL itself is what has to leave argv.
TELEGRAM_TOKEN_SENTINEL="111:telegram-token-that-must-never-reach-argv"  # noqa - fixture

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Static shape. The executed proof is further down; these refuse the shapes so a
# reintroduction is named here rather than inferred from a log that stopped matching.
# -----------------------------------------------------------------------------

if grep -Eq '^[[:space:]]*-d "' "$SOURCE_TEARDOWN"; then
    fail "a teardown callback body must not be a curl command-line argument"
fi

if grep -Eq 'curl[^|]*https://api\.telegram\.org' "$SOURCE_TEARDOWN"; then
    fail "the Telegram bot token must not reach curl as a URL argument"
fi

# Two callbacks and two webhook deregistrations. A count, because every
# credential-bearing call site must keep the -q that stops a personal ~/.curlrc from
# redirecting the request.
if [ "$(grep -Fc 'curl -q --config -' "$SOURCE_TEARDOWN")" -ne 4 ]; then
    fail "every credential-bearing curl call must read its configuration from stdin"
fi

# The routes that do not use argv have to be reachable, and named where an operator
# looks. A safe route nobody is shown is a safe route nobody takes.
grep -Fq 'CORCO_TEARDOWN_TOKEN' "$SOURCE_TEARDOWN" \
    || fail "the environment route is missing"
grep -Fq -- '--token-stdin' "$SOURCE_TEARDOWN" \
    || fail "the stdin route is missing"
grep -Fq -- '--token' "$SOURCE_TEARDOWN" \
    || fail "--token must keep working for operators holding older instructions"

# The customer-facing tutorial is what a customer actually copies, and the teardown
# landing page promises them a prompt. Neither may hand out the argv form.
TUTORIAL="$SCRIPT_DIR/../TEARDOWN.md"
if grep -Fq -- './teardown.sh --token=' "$TUTORIAL"; then
    fail "the teardown tutorial still teaches the argv form"
fi

# -----------------------------------------------------------------------------
# Fakes
# -----------------------------------------------------------------------------

FAKE_BIN="$TEMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"

CALL_LOG="$TEMP_DIR/calls.log"
CURL_CONFIG_LOG="$TEMP_DIR/curl-config.log"

# curl records what it was given on its command line, what it was given on standard
# input, and whether it inherited the token in its environment. The three logs are what
# separate "moved off argv" from "stopped sending".
printf '%s\n' \
    '#!/bin/bash' \
    'CURL_CONFIG_LOG="${CURL_CONFIG_LOG:-/dev/null}"' \
    'printf "curl-env CORCO_TEARDOWN_TOKEN=<%s>\n" "${CORCO_TEARDOWN_TOKEN:-}" >> "$CALL_LOG"' \
    'printf "curl" >> "$CALL_LOG"' \
    'printf " <%s>" "$@" >> "$CALL_LOG"' \
    'printf "\n" >> "$CALL_LOG"' \
    'if [ "${1:-}" = "-q" ]; then' \
    '    cat >> "$CURL_CONFIG_LOG"' \
    'fi' \
    'printf "{\"status\": \"ok\"}\n"' \
    > "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "gcloud" >> "$CALL_LOG"' \
    'printf " <%s>" "$@" >> "$CALL_LOG"' \
    'printf "\n" >> "$CALL_LOG"' \
    'case "${1:-}:${2:-}" in' \
    '  config:get-value) printf "%s\n" "operator@example.test" ;;' \
    '  secrets:versions)' \
    '    if [ "${3:-}" = "access" ]; then' \
    "      printf '%s\\n' '$TELEGRAM_TOKEN_SENTINEL'" \
    '    fi' \
    '    ;;' \
    '  secrets:list) : ;;' \
    '  functions:list|run:services|scheduler:jobs) : ;;' \
    'esac' \
    'exit 0' \
    > "$FAKE_BIN/gcloud"
chmod +x "$FAKE_BIN/gcloud"

# Never reached, because CORCO_PLATFORM_ROOT below points at a tree with no
# deployment/terraform. Present so that a change which did reach it fails loudly here
# rather than initializing a real backend on the machine running the tests.
printf '%s\n' \
    '#!/bin/bash' \
    'printf "terraform" >> "$CALL_LOG"' \
    'printf " <%s>" "$@" >> "$CALL_LOG"' \
    'printf "\n" >> "$CALL_LOG"' \
    'exit 1' \
    > "$FAKE_BIN/terraform"
chmod +x "$FAKE_BIN/terraform"

# No deployment/terraform underneath, so the partial-teardown branch reports the missing
# directory and continues instead of running terraform against this checkout.
EMPTY_PLATFORM="$TEMP_DIR/platform"
mkdir -p "$EMPTY_PLATFORM"

run_teardown() {
    # usage: run_teardown <output-file> [env NAME=VALUE ...] -- <script args...>
    local out_file=$1
    shift
    local -a extra_env=()
    while [ "$1" != "--" ]; do
        extra_env+=("$1")
        shift
    done
    shift

    : > "$CALL_LOG"
    : > "$CURL_CONFIG_LOG"
    set +e
    env -i \
        HOME="$TEMP_DIR/home" \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        CALL_LOG="$CALL_LOG" \
        CURL_CONFIG_LOG="$CURL_CONFIG_LOG" \
        CLOUD_SHELL=1 \
        CORCO_PLATFORM_ROOT="$EMPTY_PLATFORM" \
        TEARDOWN_CALLBACK_URL="https://callback.invalid/api/teardown" \
        ${extra_env[@]+"${extra_env[@]}"} \
        bash "$SOURCE_TEARDOWN" "$@" > "$out_file" 2>&1
    local status=$?
    set -e
    return "$status"
}

assert_token_left_argv() {
    local what=$1
    if grep -Fq "$TEARDOWN_TOKEN_SENTINEL" "$CALL_LOG"; then
        fail "$what: the teardown token reached a command line"
    fi
}

# -----------------------------------------------------------------------------
# 1. The environment route. Read once and unset, so the gcloud, terraform and curl
#    children this script spawns do not inherit the credential -- the empty report from
#    the fake curl is what says the unset happened.
# -----------------------------------------------------------------------------

run_teardown "$TEMP_DIR/env-route.out" \
    CORCO_TEARDOWN_TOKEN="$TEARDOWN_TOKEN_SENTINEL" \
    -- "$DOMAIN" "--project=$PROJECT_ID" --force || true

# Sent, and sent on standard input: the start callback and the completion callback.
if [ "$(grep -Fc "$TEARDOWN_TOKEN_SENTINEL" "$CURL_CONFIG_LOG")" -ne 2 ]; then
    fail "environment route: both teardown callbacks must still carry the token"
fi
assert_token_left_argv "environment route"
if ! grep -Fq 'curl-env CORCO_TEARDOWN_TOKEN=<>' "$CALL_LOG"; then
    fail "the teardown token was inherited by a child process's environment"
fi
grep -Fq 'callback.invalid/api/teardown/start' "$CALL_LOG" \
    || fail "the start callback URL is no longer sent"
grep -Fq 'callback.invalid/api/teardown/complete' "$CALL_LOG" \
    || fail "the completion callback URL is no longer sent"

# -----------------------------------------------------------------------------
# 2. The stdin route.
# -----------------------------------------------------------------------------

: > "$CALL_LOG"
: > "$CURL_CONFIG_LOG"
set +e
printf '%s\n' "$TEARDOWN_TOKEN_SENTINEL" | env -i \
    HOME="$TEMP_DIR/home" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    CALL_LOG="$CALL_LOG" \
    CURL_CONFIG_LOG="$CURL_CONFIG_LOG" \
    CLOUD_SHELL=1 \
    CORCO_PLATFORM_ROOT="$EMPTY_PLATFORM" \
    TEARDOWN_CALLBACK_URL="https://callback.invalid/api/teardown" \
    bash "$SOURCE_TEARDOWN" "$DOMAIN" "--project=$PROJECT_ID" --force --token-stdin \
    > "$TEMP_DIR/stdin-route.out" 2>&1
set -e

if [ "$(grep -Fc "$TEARDOWN_TOKEN_SENTINEL" "$CURL_CONFIG_LOG")" -ne 2 ]; then
    fail "stdin route: both teardown callbacks must still carry the token"
fi
assert_token_left_argv "stdin route"

# -----------------------------------------------------------------------------
# 3. --token still works, because operators hold instructions that use it, and the run
#    says why it is the wrong form rather than accepting it silently. The value itself is
#    never echoed back: naming the flag is enough to identify what leaked.
# -----------------------------------------------------------------------------

run_teardown "$TEMP_DIR/argv-route.out" \
    -- "$DOMAIN" "--project=$PROJECT_ID" --force "--token=$TEARDOWN_TOKEN_SENTINEL" || true

if [ "$(grep -Fc "$TEARDOWN_TOKEN_SENTINEL" "$CURL_CONFIG_LOG")" -ne 2 ]; then
    fail "--token must keep authenticating the callbacks"
fi
grep -Fq -- '--token puts the teardown token in this process' "$TEMP_DIR/argv-route.out" \
    || fail "--token was accepted without saying what it costs"
if grep -Fq "$TEARDOWN_TOKEN_SENTINEL" "$TEMP_DIR/argv-route.out"; then
    fail "the warning echoed the token it was warning about"
fi

# -----------------------------------------------------------------------------
# 4. The webhook deregistration in --keep-project mode. The bot token is the tenant's
#    live credential and the URL is the only place it can go, so it must still be SENT.
# -----------------------------------------------------------------------------

run_teardown "$TEMP_DIR/keep-project.out" \
    CORCO_TEARDOWN_TOKEN="$TEARDOWN_TOKEN_SENTINEL" \
    -- "$DOMAIN" "--project=$PROJECT_ID" --all --keep-project --force || true

if ! grep -Fq 'deleteWebhook' "$CURL_CONFIG_LOG"; then
    fail "--keep-project left the tenant webhook pointing at a dead function"
fi
if grep -Fq "$TELEGRAM_TOKEN_SENTINEL" "$CALL_LOG"; then
    fail "--keep-project: the tenant Telegram bot token reached curl's argv"
fi
if ! grep -Fq "$TELEGRAM_TOKEN_SENTINEL" "$CURL_CONFIG_LOG"; then
    fail "--keep-project: the deregistration no longer authenticates as the tenant's bot"
fi
assert_token_left_argv "--keep-project"
# -q on this call site too: a personal ~/.curlrc could otherwise redirect a request whose
# URL is itself the credential.
grep -Fq 'curl <-q> <--config> <->' "$CALL_LOG" \
    || fail "--keep-project: the webhook deregistration dropped -q"

# -----------------------------------------------------------------------------
# 5. The webhook deregistration on the path that deletes the whole project. A separate
#    call site from the one above, so it is exercised separately.
# -----------------------------------------------------------------------------

run_teardown "$TEMP_DIR/delete-project.out" \
    CORCO_TEARDOWN_TOKEN="$TEARDOWN_TOKEN_SENTINEL" \
    -- "$DOMAIN" "--project=$PROJECT_ID" --all --force || true

grep -Fq 'gcloud <projects> <delete>' "$CALL_LOG" \
    || fail "the full-teardown path no longer deletes the project"
if ! grep -Fq 'deleteWebhook' "$CURL_CONFIG_LOG"; then
    fail "full project deletion left the tenant webhook pointing at a deleted project"
fi
if grep -Fq "$TELEGRAM_TOKEN_SENTINEL" "$CALL_LOG"; then
    fail "full teardown: the tenant Telegram bot token reached curl's argv"
fi
if ! grep -Fq "$TELEGRAM_TOKEN_SENTINEL" "$CURL_CONFIG_LOG"; then
    fail "full teardown: the deregistration no longer authenticates as the tenant's bot"
fi
assert_token_left_argv "full teardown"

# -----------------------------------------------------------------------------
# 6. The prompt. This is the route the teardown landing page tells customers to use and
#    the one the tutorial teaches, so it is exercised on a real terminal rather than
#    asserted from the source. It only exists when stdin is a terminal, which is why this
#    slice needs a pty where the five above do not.
# -----------------------------------------------------------------------------

: > "$CALL_LOG"
: > "$CURL_CONFIG_LOG"
PROMPT_DRIVER="$TEMP_DIR/run-prompted-teardown.sh"
printf '%s\n' \
    '#!/bin/bash' \
    'exec env -i \' \
    '    HOME="$TEST_TEMP_DIR/home" \' \
    '    PATH="$TEST_FAKE_BIN:/usr/bin:/bin" \' \
    '    CALL_LOG="$TEST_CALL_LOG" \' \
    '    CURL_CONFIG_LOG="$TEST_CURL_CONFIG_LOG" \' \
    '    CLOUD_SHELL=1 \' \
    '    CORCO_PLATFORM_ROOT="$TEST_EMPTY_PLATFORM" \' \
    '    TEARDOWN_CALLBACK_URL="https://callback.invalid/api/teardown" \' \
    '    bash "$TEST_SOURCE_TEARDOWN" "$TEST_DOMAIN" "--project=$TEST_PROJECT_ID" --force' \
    > "$PROMPT_DRIVER"
chmod +x "$PROMPT_DRIVER"

export TEST_CALL_LOG="$CALL_LOG"
export TEST_CURL_CONFIG_LOG="$CURL_CONFIG_LOG"
export TEST_DOMAIN="$DOMAIN"
export TEST_EMPTY_PLATFORM="$EMPTY_PLATFORM"
export TEST_FAKE_BIN="$FAKE_BIN"
export TEST_PROJECT_ID="$PROJECT_ID"
export TEST_SOURCE_TEARDOWN="$SOURCE_TEARDOWN"
export TEST_TEMP_DIR="$TEMP_DIR"

run_with_controlling_terminal() {
    case "$(uname -s)" in
        Darwin) script -q /dev/null "$PROMPT_DRIVER" ;;
        Linux) script -q -e -c "$PROMPT_DRIVER" /dev/null ;;
        *) fail "unsupported platform for the teardown prompt test" ;;
    esac
}

# The token is typed only once the prompt is on screen. `read -rs` turns the terminal's
# echo off before it writes the prompt, so anything sent earlier is echoed by the tty
# driver and would fail the no-echo assertion below for a reason that is the harness's
# rather than the script's.
PROMPT_OUTPUT="$TEMP_DIR/prompt-route.out"
: > "$PROMPT_OUTPUT"
FEEDER="$TEMP_DIR/feed-terminal-token.sh"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'for _ in $(seq 1 1000); do' \
    '    if grep -Fq "Teardown token" "$TEST_PROMPT_OUTPUT" 2>/dev/null; then' \
    '        printf "%s\n" "$TEST_TEARDOWN_TOKEN_SENTINEL"' \
    '        exit 0' \
    '    fi' \
    '    sleep 0.01' \
    'done' \
    'echo "the teardown script never asked for the token" >&2' \
    'exit 72' \
    > "$FEEDER"
chmod +x "$FEEDER"
export TEST_PROMPT_OUTPUT="$PROMPT_OUTPUT"
export TEST_TEARDOWN_TOKEN_SENTINEL="$TEARDOWN_TOKEN_SENTINEL"

set +e
"$FEEDER" | run_with_controlling_terminal >> "$PROMPT_OUTPUT" 2>&1
prompt_exit_codes=("${PIPESTATUS[@]}")
set -e
if [ "${prompt_exit_codes[0]}" -ne 0 ]; then
    sed -n '1,80p' "$PROMPT_OUTPUT" >&2
    fail "the teardown script never reached the token prompt"
fi

grep -Fq "Teardown token" "$PROMPT_OUTPUT" \
    || fail "the script did not ask for the token on a terminal"
# Unechoed: read -rs is what keeps the value off the screen and out of any transcript,
# terminal scrollback or session recording the customer's Cloud Shell keeps.
if grep -Fq "$TEARDOWN_TOKEN_SENTINEL" "$PROMPT_OUTPUT"; then
    fail "the token prompt echoed the token"
fi
if [ "$(grep -Fc "$TEARDOWN_TOKEN_SENTINEL" "$CURL_CONFIG_LOG")" -ne 2 ]; then
    fail "prompt route: both teardown callbacks must still carry the token"
fi
assert_token_left_argv "prompt route"

echo "teardown token transport regression test passed"
