#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/../setup.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

sed -n '/^parse_bootstrap_arguments() {/,/^parse_bootstrap_arguments "\$@"/p' "$SETUP_SCRIPT" | sed '$d' > "$TEMP_DIR/interfaces.sh"
source "$TEMP_DIR/interfaces.sh"

FAKE_SETUP="$TEMP_DIR/setup.sh"
CAPTURE_FILE="$TEMP_DIR/arguments"
export CAPTURE_FILE
printf '%s\n' \
    '#!/bin/bash' \
    'if false; then' \
    '    case unused in' \
    '        --reuse-saved) ;;' \
    '    esac' \
    'fi' \
    'printf "%s\n" "$@" > "$CAPTURE_FILE"' > "$FAKE_SETUP"
chmod +x "$FAKE_SETUP"

parse_bootstrap_arguments --token=test-token --reuse-saved --unsupported=value
DOMAIN="example.test"
CONSULTANT="support@example.test"
launch_main_setup "$FAKE_SETUP"

printf '%s\n' \
    '--token=test-token' \
    '--domain=example.test' \
    '--consultant=support@example.test' \
    '--reuse-saved' > "$TEMP_DIR/expected"
cmp "$TEMP_DIR/expected" "$CAPTURE_FILE"

parse_bootstrap_arguments --token=second-token --unsupported=value
launch_main_setup "$FAKE_SETUP"
printf '%s\n' \
    '--token=second-token' \
    '--domain=example.test' \
    '--consultant=support@example.test' > "$TEMP_DIR/expected"
cmp "$TEMP_DIR/expected" "$CAPTURE_FILE"

UNSUPPORTED_SETUP="$TEMP_DIR/unsupported-setup.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$UNSUPPORTED_SETUP"
chmod +x "$UNSUPPORTED_SETUP"
parse_bootstrap_arguments --token=test-token --reuse-saved
RED=""
NC=""
RELEASE_VERSION="v1.3.8"
if launch_main_setup "$UNSUPPORTED_SETUP" >/dev/null 2>&1; then
    echo "bootstrap forwarded --reuse-saved to an installer that does not support it" >&2
    exit 1
fi

echo "setup argument forwarding regression test passed"
