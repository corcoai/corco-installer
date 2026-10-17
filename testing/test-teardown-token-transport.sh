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
#
# The behaviour runs where customers run it. The teardown button clones this repository
# and runs ./teardown.sh from the clone root, often in a Cloud Shell where setup never
# unpacked the release beside it. So every slice below runs a copy of teardown.sh alone
# in an empty directory, from that directory, with no CORCO_PLATFORM_ROOT: the layout of
# a fresh clone. In that layout only the whole-project deletion can proceed, and the
# other two modes must stop before they change anything or tell Corco anything.

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

# grep -q under set -e ends the script silently on a miss, so every presence check goes
# through these two and names what it looked for.
require_in() {
    local file=$1 needle=$2 message=$3
    grep -Fq -- "$needle" "$file" || fail "$message"
}

refuse_in() {
    local file=$1 needle=$2 message=$3
    if grep -Fq -- "$needle" "$file"; then
        fail "$message"
    fi
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

# One callback sender, one webhook deregistration and one operator-state query that
# carries a Google access token. A count, because every credential-bearing call site
# must keep the -q that stops a personal ~/.curlrc from redirecting the request.
if [ "$(grep -Fc 'curl -q --config -' "$SOURCE_TEARDOWN")" -ne 3 ]; then
    fail "every credential-bearing curl call must read its configuration from stdin"
fi

# The routes that do not use argv have to be reachable, and named where an operator
# looks. A safe route nobody is shown is a safe route nobody takes.
require_in "$SOURCE_TEARDOWN" 'CORCO_TEARDOWN_TOKEN' "the environment route is missing"
require_in "$SOURCE_TEARDOWN" '--token-stdin' "the stdin route is missing"
require_in "$SOURCE_TEARDOWN" '--token' "--token must keep working for operators holding older instructions"

# The customer-facing tutorial is what a customer actually copies, and the teardown
# landing page promises them a prompt. Neither may hand out the argv form.
TUTORIAL="$SCRIPT_DIR/../TEARDOWN.md"
refuse_in "$TUTORIAL" './teardown.sh --token=' "the teardown tutorial still teaches the argv form"

# -----------------------------------------------------------------------------
# The fresh-clone layout and the fakes
# -----------------------------------------------------------------------------

CLONE_DIR="$TEMP_DIR/fresh-clone"
mkdir -p "$CLONE_DIR"
cp "$SOURCE_TEARDOWN" "$CLONE_DIR/teardown.sh"
chmod +x "$CLONE_DIR/teardown.sh"

FAKE_BIN="$TEMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
OBJECT_DIR="$TEMP_DIR/objects"
CALL_LOG="$TEMP_DIR/calls.log"
CURL_CONFIG_LOG="$TEMP_DIR/curl-config.log"

# curl records what it was given on its command line, what it was given on standard
# input, and whether it inherited the token in its environment. The three logs are what
# separate "moved off argv" from "stopped sending". Standard input is read only for
# --config, because the script's own standard input carries the operator's typed
# confirmations, and a fake that consumed it unconditionally would eat them.
printf '%s\n' \
    '#!/bin/bash' \
    'printf "curl-env CORCO_TEARDOWN_TOKEN=<%s>\n" "${CORCO_TEARDOWN_TOKEN:-}" >> "$CALL_LOG"' \
    'printf "curl" >> "$CALL_LOG"' \
    'printf " <%s>" "$@" >> "$CALL_LOG"' \
    'printf "\n" >> "$CALL_LOG"' \
    'config=""' \
    'for arg in "$@"; do' \
    '  [ "$arg" = "--config" ] || continue' \
    '  config=$(cat)' \
    '  printf "curl-config-begin\n%s\ncurl-config-end\n" "$config" >> "$CURL_CONFIG_LOG"' \
    '  break' \
    'done' \
    'case "$config" in' \
    '  */deleteWebhook*) printf "%s\n" "curl-telegram deleteWebhook" >> "$CALL_LOG"; printf "%s\n" "{\"ok\":true}"; exit 0 ;;' \
    'esac' \
    'printf "%s\n" "{\"status\":\"ok\"}"' \
    > "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

# gcloud answers as Google does. The project probe answers ACTIVE unless PROJECT_PROBE
# names a failure; the lease is a generation-checked object in OBJECT_DIR, so the
# compare-and-swap the script relies on is exercised rather than assumed.
printf '%s\n' \
    '#!/bin/bash' \
    'printf "gcloud" >> "$CALL_LOG"' \
    'printf " <%s>" "$@" >> "$CALL_LOG"' \
    'printf "\n" >> "$CALL_LOG"' \
    'object_paths() {' \
    '  case "$1" in' \
    '    *.lease) OBJECT_DATA="$OBJECT_DIR/lease.data"; OBJECT_GENERATION="$OBJECT_DIR/lease.generation" ;;' \
    '    *) return 1 ;;' \
    '  esac' \
    '}' \
    'case "${1:-}:${2:-}" in' \
    '  projects:describe)' \
    '    case "${PROJECT_PROBE:-present}" in' \
    '      present) printf "%s\t%s\n" "$3" "ACTIVE" ;;' \
    '      auth) echo "ERROR: (gcloud.projects.describe) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution." >&2; exit 1 ;;' \
    '      denied) echo "ERROR: (gcloud.projects.describe) [operator@example.test] does not have permission to access projects instance [$3] (or it may not exist): The caller does not have permission" >&2; exit 1 ;;' \
    '      *) exit 1 ;;' \
    '    esac' \
    '    ;;' \
    '  projects:delete) rm -f "$OBJECT_DIR/lease.data" "$OBJECT_DIR/lease.generation" ;;' \
    '  config:configurations) : ;;' \
    '  config:set) : ;;' \
    '  config:get-value) printf "%s\n" "operator@example.test" ;;' \
    '  auth:print-access-token) printf "%s\n" "fake-teardown-access-token" ;;' \
    '  secrets:versions)' \
    '    if [ "${3:-}" = "access" ]; then' \
    "      printf '%s\\n' '$TELEGRAM_TOKEN_SENTINEL'" \
    '    fi' \
    '    ;;' \
    '  secrets:list) : ;;' \
    '  storage:objects)' \
    '    [ "${3:-}" = "describe" ] || exit 1' \
    '    object_paths "$4" || exit 1' \
    '    [ -f "$OBJECT_DATA" ] || { printf "%s\n" "404 not found" >&2; exit 1; }' \
    '    cat "$OBJECT_GENERATION"' \
    '    ;;' \
    '  storage:buckets) echo "ERROR: (gcloud.storage.buckets.describe) HTTPError 404: The specified bucket does not exist." >&2; exit 1 ;;' \
    '  storage:cp)' \
    '    if [[ "$3" == gs://* ]]; then' \
    '      object_paths "$3" || exit 1' \
    '      [ -f "$OBJECT_DATA" ] || exit 1' \
    '      cp "$OBJECT_DATA" "$4"' \
    '    else' \
    '      object_paths "$4" || exit 1' \
    '      expected=""' \
    '      for arg in "$@"; do case "$arg" in --if-generation-match=*) expected=${arg#*=} ;; esac; done' \
    '      current=0' \
    '      [ ! -f "$OBJECT_GENERATION" ] || current=$(cat "$OBJECT_GENERATION")' \
    '      [ "$expected" = "$current" ] || exit 1' \
    '      cp "$3" "$OBJECT_DATA"' \
    '      printf "%s\n" "$((current + 1))" > "$OBJECT_GENERATION"' \
    '    fi' \
    '    ;;' \
    '  storage:rm)' \
    '    object_paths "$3" || exit 1' \
    '    expected=""' \
    '    for arg in "$@"; do case "$arg" in --if-generation-match=*) expected=${arg#*=} ;; esac; done' \
    '    current=$(cat "$OBJECT_GENERATION" 2>/dev/null || printf 0)' \
    '    [ "$expected" = "$current" ] || exit 1' \
    '    rm -f "$OBJECT_DATA" "$OBJECT_GENERATION"' \
    '    ;;' \
    '  *) : ;;' \
    'esac' \
    > "$FAKE_BIN/gcloud"
chmod +x "$FAKE_BIN/gcloud"

# Tripwires. A fresh clone has no deployment files, so nothing below may reach
# Terraform, and no slice has any business with gsutil, bq or gh. Each logs its name, so
# a change that did reach one fails here instead of touching the machine running the
# tests.
for tool in terraform gsutil bq gh; do
    printf '%s\n' \
        '#!/bin/bash' \
        "printf 'tripwire $tool' >> \"\$CALL_LOG\"" \
        'printf " <%s>" "$@" >> "$CALL_LOG"' \
        'printf "\n" >> "$CALL_LOG"' \
        'exit 127' \
        > "$FAKE_BIN/$tool"
    chmod +x "$FAKE_BIN/$tool"
done

reset_run() {
    : > "$CALL_LOG"
    : > "$CURL_CONFIG_LOG"
    rm -rf "$OBJECT_DIR" "$TEMP_DIR/home"
    mkdir -p "$OBJECT_DIR" "$TEMP_DIR/home"
}

run_teardown() {
    # usage: run_teardown <output-file> <stdin-file> [NAME=VALUE ...] -- <script args...>
    local out_file=$1
    local stdin_file=$2
    shift 2
    local -a extra_env=()
    while [ "$1" != "--" ]; do
        extra_env+=("$1")
        shift
    done
    shift

    reset_run
    set +e
    (
        cd "$CLONE_DIR" || exit 99
        env -i \
            HOME="$TEMP_DIR/home" \
            PATH="$FAKE_BIN:/usr/bin:/bin" \
            CALL_LOG="$CALL_LOG" \
            CURL_CONFIG_LOG="$CURL_CONFIG_LOG" \
            OBJECT_DIR="$OBJECT_DIR" \
            CLOUD_SHELL=1 \
            TEARDOWN_CALLBACK_URL="https://callback.invalid/api/teardown" \
            ${extra_env[@]+"${extra_env[@]}"} \
            bash ./teardown.sh "$@"
    ) < "$stdin_file" > "$out_file" 2>&1
    RUN_STATUS=$?
    set -e
}

PROJECT_ANSWER="$TEMP_DIR/project-answer.txt"
printf '%s\n' "$PROJECT_ID" > "$PROJECT_ANSWER"

assert_token_left_argv() {
    refuse_in "$CALL_LOG" "$TEARDOWN_TOKEN_SENTINEL" "$1: the teardown token reached a command line"
}

assert_callbacks_carry_token() {
    if [ "$(grep -Fc "$TEARDOWN_TOKEN_SENTINEL" "$CURL_CONFIG_LOG")" -ne 2 ]; then
        fail "$1: the start and the completion callback must both carry the token"
    fi
}

assert_completed() {
    local what=$1 out_file=$2
    if [ "$RUN_STATUS" -ne 0 ]; then
        sed -n '1,60p' "$out_file" >&2
        fail "$what: the whole-project teardown exited $RUN_STATUS"
    fi
    require_in "$CALL_LOG" 'callback.invalid/api/teardown/start' "$what: the start callback URL is no longer sent"
    require_in "$CALL_LOG" 'callback.invalid/api/teardown/complete' "$what: the completion callback URL is no longer sent"
    refuse_in "$CALL_LOG" 'callback.invalid/api/teardown/failed' "$what: a successful teardown reported failure"
    refuse_in "$CALL_LOG" 'tripwire' "$what: the teardown reached Terraform, gsutil, bq or gh"
}

# Nothing changed and nothing was told: no curl call at all, so no callback and no
# webhook deregistration, no lease written and no project deleted.
assert_nothing_happened() {
    local what=$1 out_file=$2
    if [ "$RUN_STATUS" -eq 0 ]; then
        sed -n '1,60p' "$out_file" >&2
        fail "$what: the teardown exited 0"
    fi
    refuse_in "$CALL_LOG" 'curl' "$what: the teardown called curl before it stopped"
    refuse_in "$CALL_LOG" 'gcloud <storage> <cp>' "$what: the teardown wrote the lease before it stopped"
    refuse_in "$CALL_LOG" 'gcloud <projects> <delete>' "$what: the teardown deleted the project"
    refuse_in "$CALL_LOG" 'tripwire' "$what: the teardown reached Terraform, gsutil, bq or gh"
}

# -----------------------------------------------------------------------------
# 1. The environment route, on the whole-project deletion. The token is read once and
#    unset, so the gcloud and curl children this script spawns do not inherit it -- the
#    empty report from the fake curl is what says the unset happened. The same run
#    proves the webhook deregistration: the bot token is the tenant's live credential
#    and the URL is the only place it can go, so it must still be SENT.
# -----------------------------------------------------------------------------

run_teardown "$TEMP_DIR/env-route.out" "$PROJECT_ANSWER" \
    CORCO_TEARDOWN_TOKEN="$TEARDOWN_TOKEN_SENTINEL" \
    -- "$DOMAIN" "--project=$PROJECT_ID" --all --force

assert_completed "environment route" "$TEMP_DIR/env-route.out"
assert_callbacks_carry_token "environment route"
assert_token_left_argv "environment route"
require_in "$CALL_LOG" 'curl-env CORCO_TEARDOWN_TOKEN=<>' "the teardown token was inherited by a child process's environment"
refuse_in "$CALL_LOG" "curl-env CORCO_TEARDOWN_TOKEN=<$TEARDOWN_TOKEN_SENTINEL>" "the teardown token was inherited by a child process's environment"
require_in "$CALL_LOG" 'gcloud <projects> <delete>' "the whole-project teardown no longer deletes the project"
require_in "$CALL_LOG" 'curl-telegram deleteWebhook' "the whole-project teardown left the tenant webhook pointing at a deleted project"
refuse_in "$CALL_LOG" "$TELEGRAM_TOKEN_SENTINEL" "the tenant Telegram bot token reached curl's argv"
require_in "$CURL_CONFIG_LOG" "$TELEGRAM_TOKEN_SENTINEL" "the webhook deregistration no longer authenticates as the tenant's bot"
# -q on the deregistration too: a personal ~/.curlrc could otherwise redirect a request
# whose URL is itself the credential.
require_in "$CALL_LOG" 'curl <-q> <--config> <->' "the webhook deregistration dropped -q"

# Corco hears "complete" only after the project deletion has succeeded.
delete_line=$(grep -nF 'gcloud <projects> <delete>' "$CALL_LOG" | head -n 1 | cut -d: -f1)
complete_line=$(grep -nF 'callback.invalid/api/teardown/complete' "$CALL_LOG" | head -n 1 | cut -d: -f1)
if [ "$complete_line" -le "$delete_line" ]; then
    fail "the completion callback was sent before the project was deleted"
fi

# -----------------------------------------------------------------------------
# 2. The stdin route. The token is the first line of standard input and the typed
#    project ID the second, as a pipe from a password manager would deliver them.
# -----------------------------------------------------------------------------

STDIN_ANSWERS="$TEMP_DIR/stdin-answers.txt"
printf '%s\n' "$TEARDOWN_TOKEN_SENTINEL" "$PROJECT_ID" > "$STDIN_ANSWERS"
run_teardown "$TEMP_DIR/stdin-route.out" "$STDIN_ANSWERS" \
    -- "$DOMAIN" "--project=$PROJECT_ID" --all --force --token-stdin

assert_completed "stdin route" "$TEMP_DIR/stdin-route.out"
assert_callbacks_carry_token "stdin route"
assert_token_left_argv "stdin route"

# -----------------------------------------------------------------------------
# 3. --token still works, because operators hold instructions that use it, and the run
#    says why it is the wrong form rather than accepting it silently. The value itself is
#    never echoed back: naming the flag is enough to identify what leaked. Its own argv
#    is the leak it warns about, so the curl and gcloud children are what is checked.
# -----------------------------------------------------------------------------

run_teardown "$TEMP_DIR/argv-route.out" "$PROJECT_ANSWER" \
    -- "$DOMAIN" "--project=$PROJECT_ID" --all --force "--token=$TEARDOWN_TOKEN_SENTINEL"

assert_completed "--token route" "$TEMP_DIR/argv-route.out"
assert_callbacks_carry_token "--token route"
assert_token_left_argv "--token route"
require_in "$TEMP_DIR/argv-route.out" '--token puts the teardown token in this process' "--token was accepted without saying what it costs"
refuse_in "$TEMP_DIR/argv-route.out" "$TEARDOWN_TOKEN_SENTINEL" "the warning echoed the token it was warning about"

# -----------------------------------------------------------------------------
# 4. A declined confirmation. The whole-project deletion asks for the typed project ID
#    even under --force, and an operator who types anything else must leave the
#    deployment exactly as they found it: the start callback would move the registry
#    entry to a teardown nobody agreed to, and the webhook deregistration would silently
#    stop Telegram ingestion.
# -----------------------------------------------------------------------------

WRONG_ANSWER="$TEMP_DIR/wrong-answer.txt"
printf '%s\n' "not-the-project" > "$WRONG_ANSWER"
run_teardown "$TEMP_DIR/declined.out" "$WRONG_ANSWER" \
    CORCO_TEARDOWN_TOKEN="$TEARDOWN_TOKEN_SENTINEL" \
    -- "$DOMAIN" "--project=$PROJECT_ID" --all --force

assert_nothing_happened "declined confirmation" "$TEMP_DIR/declined.out"
require_in "$TEMP_DIR/declined.out" 'Project confirmation failed' "a declined confirmation did not say why it stopped"

# -----------------------------------------------------------------------------
# 5. A failed project probe is not an absent project. When gcloud cannot answer whether
#    the project exists, the teardown must stop before it tells Corco anything, instead
#    of reporting a deletion it could not check.
# -----------------------------------------------------------------------------

for probe in denied auth; do
    run_teardown "$TEMP_DIR/probe-$probe.out" "$PROJECT_ANSWER" \
        CORCO_TEARDOWN_TOKEN="$TEARDOWN_TOKEN_SENTINEL" PROJECT_PROBE="$probe" \
        -- "$DOMAIN" "--project=$PROJECT_ID" --all --force
    assert_nothing_happened "project probe $probe" "$TEMP_DIR/probe-$probe.out"
    require_in "$TEMP_DIR/probe-$probe.out" 'Nothing has been deleted' "project probe $probe: the stop did not say that nothing was deleted"
done

# -----------------------------------------------------------------------------
# 6. The two modes that keep the project need the deployment files that setup unpacks,
#    and a fresh clone has none. They must stop before any effect, and say so, rather
#    than tell Corco a teardown completed that removed nothing.
# -----------------------------------------------------------------------------

run_teardown "$TEMP_DIR/default-mode.out" "$PROJECT_ANSWER" \
    CORCO_TEARDOWN_TOKEN="$TEARDOWN_TOKEN_SENTINEL" \
    -- "$DOMAIN" "--project=$PROJECT_ID" --force
assert_nothing_happened "default teardown in a fresh clone" "$TEMP_DIR/default-mode.out"
require_in "$TEMP_DIR/default-mode.out" 'Nothing has been deleted' "the default teardown in a fresh clone did not say that nothing was deleted"

run_teardown "$TEMP_DIR/keep-project.out" "$PROJECT_ANSWER" \
    CORCO_TEARDOWN_TOKEN="$TEARDOWN_TOKEN_SENTINEL" \
    -- "$DOMAIN" "--project=$PROJECT_ID" --all --keep-project --force
assert_nothing_happened "--keep-project in a fresh clone" "$TEMP_DIR/keep-project.out"
require_in "$TEMP_DIR/keep-project.out" 'Nothing has been deleted' "--keep-project in a fresh clone did not say that nothing was deleted"

# -----------------------------------------------------------------------------
# 7. The prompt. This is the route the teardown landing page tells customers to use and
#    the one the tutorial teaches, so it is exercised on a real terminal rather than
#    asserted from the source. It only exists when stdin is a terminal, which is why this
#    slice needs a pty where the others do not.
# -----------------------------------------------------------------------------

reset_run
PROMPT_DRIVER="$TEMP_DIR/run-prompted-teardown.sh"
printf '%s\n' \
    '#!/bin/bash' \
    'cd "$TEST_CLONE_DIR" || exit 99' \
    'exec env -i \' \
    '    HOME="$TEST_TEMP_DIR/home" \' \
    '    PATH="$TEST_FAKE_BIN:/usr/bin:/bin" \' \
    '    CALL_LOG="$TEST_CALL_LOG" \' \
    '    CURL_CONFIG_LOG="$TEST_CURL_CONFIG_LOG" \' \
    '    OBJECT_DIR="$TEST_OBJECT_DIR" \' \
    '    CLOUD_SHELL=1 \' \
    '    TEARDOWN_CALLBACK_URL="https://callback.invalid/api/teardown" \' \
    '    bash ./teardown.sh "$TEST_DOMAIN" "--project=$TEST_PROJECT_ID" --all --force' \
    > "$PROMPT_DRIVER"
chmod +x "$PROMPT_DRIVER"

export TEST_CALL_LOG="$CALL_LOG"
export TEST_CURL_CONFIG_LOG="$CURL_CONFIG_LOG"
export TEST_CLONE_DIR="$CLONE_DIR"
export TEST_DOMAIN="$DOMAIN"
export TEST_FAKE_BIN="$FAKE_BIN"
export TEST_OBJECT_DIR="$OBJECT_DIR"
export TEST_PROJECT_ID="$PROJECT_ID"
export TEST_TEMP_DIR="$TEMP_DIR"

run_with_controlling_terminal() {
    case "$(uname -s)" in
        Darwin) script -q /dev/null "$PROMPT_DRIVER" ;;
        Linux) script -q -e -c "$PROMPT_DRIVER" /dev/null ;;
        *) fail "unsupported platform for the teardown prompt test" ;;
    esac
}

# Each answer is typed only once its prompt is on screen. `read -rs` turns the
# terminal's echo off before it writes the prompt, so a token sent earlier is echoed by
# the tty driver and would fail the no-echo assertion below for a reason that is the
# harness's rather than the script's.
PROMPT_OUTPUT="$TEMP_DIR/prompt-route.out"
: > "$PROMPT_OUTPUT"
FEEDER="$TEMP_DIR/feed-terminal-answers.sh"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'answer_when_asked() {' \
    '    for _ in $(seq 1 1000); do' \
    '        if grep -Fq "$1" "$TEST_PROMPT_OUTPUT" 2>/dev/null; then' \
    '            printf "%s\n" "$2"' \
    '            return 0' \
    '        fi' \
    '        sleep 0.01' \
    '    done' \
    '    echo "the teardown script never asked: $1" >&2' \
    '    exit 72' \
    '}' \
    'answer_when_asked "Teardown token" "$TEST_TEARDOWN_TOKEN_SENTINEL"' \
    'answer_when_asked "Type the project ID" "$TEST_PROJECT_ID"' \
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
    fail "the teardown script never reached the token prompt or the project prompt"
fi

require_in "$PROMPT_OUTPUT" "Teardown token" "the script did not ask for the token on a terminal"
# Unechoed: read -rs is what keeps the value off the screen and out of any transcript,
# terminal scrollback or session recording the customer's Cloud Shell keeps.
refuse_in "$PROMPT_OUTPUT" "$TEARDOWN_TOKEN_SENTINEL" "the token prompt echoed the token"
assert_callbacks_carry_token "prompt route"
assert_token_left_argv "prompt route"
require_in "$CALL_LOG" 'callback.invalid/api/teardown/complete' "prompt route: the completion callback URL is no longer sent"

echo "teardown token transport regression test passed"
