#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/../setup.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

VALID_HASH="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
CUTOVER_URL="https://telegram-webhook-old.example.test"
MOCK_BIN="$TEMP_DIR/mock-bin"
PACKAGE_DIR="$TEMP_DIR/package"
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
    '        printf "{\"download_url\":\"https://download.example/release.tar.gz\",\"sha256\":\"%s\",\"version\":\"%s\"}" "$TEST_RELEASE_SHA256" "$TEST_RELEASE_VERSION"' \
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

build_release() {
    local name=$1
    shift
    local archive="$TEMP_DIR/${name}.tar.gz"
    printf '%s\n' "$@" > "$PACKAGE_DIR/deployment/scripts/setup.sh"
    tar -czf "$archive" -C "$PACKAGE_DIR" deployment
    printf '%s\n' "$archive"
}

SUPPORTED_RELEASE=$(build_release supported \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'if false; then' \
    '    case unused in' \
    '        --resume) ;;' \
    '        --reuse-saved) ;;' \
    '        --upgrade) ;;' \
    '        --approve-destructive-plan=*) ;;' \
    '        --allow-destructive-plan=*) ;;' \
    '        --telegram-webhook-cutover-from=*) ;;' \
    '    esac' \
    'fi' \
    'printf "%s\n" "$@" > "$CAPTURE_FILE"')

UNSUPPORTED_RELEASE=$(build_release unsupported \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'printf "invoked\n" > "$CAPTURE_FILE"')

RESUME_ONLY_RELEASE=$(build_release resume-only \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'if false; then' \
    '    case unused in' \
    '        --resume) ;;' \
    '    esac' \
    'fi' \
    'printf "invoked\n" > "$CAPTURE_FILE"')

STRICT_HASH_RELEASE=$(build_release strict-hash \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'if false; then' \
    '    case unused in' \
    '        --approve-destructive-plan=*) ;;' \
    '        --allow-destructive-plan=*) ;;' \
    '    esac' \
    'fi' \
    'for argument in "$@"; do' \
    '    case "$argument" in' \
    '        --approve-destructive-plan=*|--allow-destructive-plan=*)' \
    '            hash=${argument#*=}' \
    '            [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || exit 64' \
    '            ;;' \
    '    esac' \
    'done' \
    'printf "%s\n" "$@" > "$CAPTURE_FILE"')

CANONICAL_HASH_RELEASE=$(build_release canonical-hash \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'if false; then' \
    '    case unused in' \
    '        --approve-destructive-plan=*) ;;' \
    '    esac' \
    'fi' \
    'printf "%s\n" "$@" > "$CAPTURE_FILE"')

release_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

run_bootstrap() {
    local label=$1
    local archive=$2
    local version=$3
    shift 3
    local run_dir="$TEMP_DIR/run-$label"
    local output_file="$TEMP_DIR/output-$label"
    local capture_file="$TEMP_DIR/capture-$label"
    mkdir -p "$run_dir"
    rm -f "$capture_file"

    (
        cd "$run_dir"
        TEST_RELEASE_ARCHIVE="$archive" \
        TEST_RELEASE_SHA256="$(release_sha256 "$archive")" \
        TEST_RELEASE_VERSION="$version" \
        CAPTURE_FILE="$capture_file" \
        PATH="$MOCK_BIN:/usr/bin:/bin" \
        bash "$SETUP_SCRIPT" "$@"
    ) > "$output_file" 2>&1
}

assert_forwarded() {
    local label=$1
    local version=$2
    shift 2
    local capture_file="$TEMP_DIR/capture-$label"
    local expected_file="$TEMP_DIR/expected-$label"

    if ! run_bootstrap "$label" "$SUPPORTED_RELEASE" "$version" --token=test-token "$@"; then
        sed -n '1,200p' "$TEMP_DIR/output-$label" >&2
        fail "$label was rejected"
    fi
    {
        printf '%s\n' \
            '--token=test-token' \
            '--domain=example.test' \
            '--consultant=support@example.test'
        if [ "$#" -gt 0 ]; then
            printf '%s\n' "$@"
        fi
    } > "$expected_file"
    cmp "$expected_file" "$capture_file" || fail "$label was not forwarded exactly"
}

assert_rejected_before_release() {
    local label=$1
    shift
    if run_bootstrap "$label" "$SUPPORTED_RELEASE" "v1.4.0" --token=test-token "$@"; then
        fail "$label unexpectedly passed"
    fi
    [ ! -e "$TEMP_DIR/capture-$label" ] || fail "$label invoked the downloaded release"
}

assert_release_rejected() {
    local label=$1
    local archive=$2
    local version=$3
    local expected_message=$4
    shift 4
    if run_bootstrap "$label" "$archive" "$version" --token=test-token "$@"; then
        fail "$label unexpectedly reached the downloaded release"
    fi
    grep -Fq -- "$expected_message" "$TEMP_DIR/output-$label" \
        || fail "$label did not explain the release incompatibility"
    [ ! -e "$TEMP_DIR/capture-$label" ] || fail "$label invoked an incompatible release"
}

# Every public forwarding path is asserted independently so removing any one case fails.
assert_forwarded token-only "v0.0.1"
assert_forwarded resume "v0.0.1" --resume
assert_forwarded reuse-saved "v0.0.1" --reuse-saved
assert_forwarded upgrade "v0.0.1" --upgrade
assert_forwarded approve-hash "v0.0.1" --approve-destructive-plan="$VALID_HASH"
assert_forwarded upgrade-approved "v0.0.1" --upgrade --approve-destructive-plan="$VALID_HASH"
assert_forwarded telegram-cutover "v0.0.1" --upgrade --telegram-webhook-cutover-from="$CUTOVER_URL"

if ! run_bootstrap allow-hash-alias "$CANONICAL_HASH_RELEASE" "v0.0.1" \
    --token=test-token --allow-destructive-plan="$VALID_HASH"; then
    sed -n '1,200p' "$TEMP_DIR/output-allow-hash-alias" >&2
    fail "allow-hash-alias was rejected by a canonical-only release"
fi
printf '%s\n' \
    '--token=test-token' \
    '--domain=example.test' \
    '--consultant=support@example.test' \
    "--approve-destructive-plan=$VALID_HASH" > "$TEMP_DIR/expected-allow-hash-alias"
cmp "$TEMP_DIR/expected-allow-hash-alias" "$TEMP_DIR/capture-allow-hash-alias" \
    || fail "allow-hash-alias was not normalized to the canonical flag"

# Syntax outside the public interface is rejected before a release is downloaded or run.
assert_rejected_before_release unknown-flag --unsupported=value
assert_rejected_before_release resume-value --resume=true
assert_rejected_before_release bare-approve --approve-destructive-plan
assert_rejected_before_release bare-allow --allow-destructive-plan
assert_rejected_before_release bare-telegram-cutover --telegram-webhook-cutover-from
assert_rejected_before_release insecure-telegram-cutover --telegram-webhook-cutover-from=http://old.example.test
assert_rejected_before_release split-token --token test-token
assert_rejected_before_release internal-domain --domain=example.test

# Capability detection, not the reported SemVer, controls forwarding.
assert_release_rejected future-version-resume "$UNSUPPORTED_RELEASE" "v99.0.0" \
    "downloaded release v99.0.0 does not support --resume" --resume
assert_release_rejected future-version-reuse "$UNSUPPORTED_RELEASE" "v99.0.0" \
    "downloaded release v99.0.0 does not support --reuse-saved" --reuse-saved
assert_release_rejected future-version-upgrade "$UNSUPPORTED_RELEASE" "v99.0.0" \
    "downloaded release v99.0.0 does not support --upgrade" --upgrade
assert_release_rejected future-version-approve "$UNSUPPORTED_RELEASE" "v99.0.0" \
    "downloaded release v99.0.0 does not support destructive-plan hashes" \
    --approve-destructive-plan="$VALID_HASH"
assert_release_rejected future-version-alias "$UNSUPPORTED_RELEASE" "v99.0.0" \
    "downloaded release v99.0.0 does not support destructive-plan hashes" \
    --allow-destructive-plan="$VALID_HASH"
assert_release_rejected future-version-telegram-cutover "$UNSUPPORTED_RELEASE" "v99.0.0" \
    "downloaded release v99.0.0 does not support Telegram webhook cutover gates" \
    --telegram-webhook-cutover-from="$CUTOVER_URL"
assert_release_rejected mixed-release-capabilities "$RESUME_ONLY_RELEASE" "v1.3.8" \
    "downloaded release v1.3.8 does not support --upgrade" --resume --upgrade

# Hash shape is enforced by the downloaded installer. The bootstrap forwards the public
# option unchanged, and a compatible release remains the final authority on its value.
for hash_option in approve-destructive-plan allow-destructive-plan; do
    for invalid_hash in "" "abc123" "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"; do
        label="invalid-${hash_option}-${#invalid_hash}"
        if run_bootstrap "$label" "$STRICT_HASH_RELEASE" "v1.4.0" \
            --token=test-token --"$hash_option"="$invalid_hash"; then
            fail "$label unexpectedly passed release hash validation"
        fi
        [ ! -e "$TEMP_DIR/capture-$label" ] || fail "$label completed the downloaded release"
    done
done

echo "setup argument forwarding regression test passed"
