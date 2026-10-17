#!/bin/bash
# =============================================================================
# AI Ingestion Platform - Teardown Script
# 
# Completely removes an AI Ingestion deployment for:
#   - Testing reinstall scenarios
#   - Cleaning up failed deployments
#   - Client offboarding
#
# Usage:
#   ./teardown.sh <domain> [options]   # Safe teardown: keeps data and secrets
#   ./teardown.sh --help               # Every option
#
# What this does, in this order:
#   1. Proves that the GCP project, the teardown lease and the Terraform state
#      bucket can be read. Every resource probe goes through gcloud_probe: only
#      gcloud's own not-found answer counts as "absent", and any other failure
#      stops the run before anything is deleted.
#   2. Notifies Corco teardown started
#   3. Runs terraform destroy (removes all GCP resources), or with --all
#      deletes the whole GCP project
#   4. Optionally deletes CORCO_* secrets, restores the org policy, deletes the
#      Terraform state bucket and the local configuration, and updates the
#      local registry (if present)
#   5. Notifies Corco teardown completed -- only after every step above has
#      succeeded. A run that fails after step 2 notifies Corco that the
#      teardown failed, and at which step, instead.
#   6. Provides instructions for manual cleanup (DWD, etc.)
#
# =============================================================================

# Don't use set -e globally - we handle errors gracefully to ensure cleanup completes

# One script, two places. This file is owned here, in corco-platform, and
# corco-installer carries a byte-identical copy at its root for the Cloud Shell teardown
# button; testing/test-installer-teardown-copy.py fails CI when the two differ. So the
# platform tree is found from this file's own path, never from the working directory and
# never from a file that may or may not sit near it:
#   - in deployment/scripts/ of the release tarball or of a corco-platform checkout, the
#     tree is two levels up;
#   - anywhere else, this is the copy at the root of a corco-installer clone, and the tree
#     is the corco-installer/ folder that setup.sh extracts beside it, present or not.
# deployment/config/config.sh is not sourced: the copy at the root of a corco-installer
# clone finds one only inside the release that setup.sh extracts, and must still run, and
# say what it cannot do, before that. CORCO_PLATFORM_ROOT overrides both.
#
# The directory the operator ran this from is kept too, for the commands the summary prints.
INVOCATION_DIR="$(pwd -P)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEARDOWN_SCRIPT="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
PLATFORM_ROOT="${CORCO_PLATFORM_ROOT:-}"
if [ -z "$PLATFORM_ROOT" ]; then
    case "$SCRIPT_DIR" in
        */deployment/scripts) PLATFORM_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)" ;;
        *) PLATFORM_ROOT="$SCRIPT_DIR/corco-installer" ;;
    esac
fi
TERRAFORM_DIR="$PLATFORM_ROOT/deployment/terraform"
REGISTRY_FILE="$PLATFORM_ROOT/deployment/registry.json"
IAM_ADMINISTRATOR_GATE="$PLATFORM_ROOT/deployment/scripts/iam-administrator-gate.sh"

# Corco callback endpoint
TEARDOWN_CALLBACK_URL="${TEARDOWN_CALLBACK_URL:-https://setup.corco.ai/api/teardown}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
BOLD=$'\033[1m'
TERRAFORM_BIN=""
TEARDOWN_RUN_DIR=""
DESTROY_PLAN_FILE=""
DESTROY_PLAN_CHANGES_FILE=""
DESTROY_PLAN_SHA256=""
TEARDOWN_LEASE_URI=""
TEARDOWN_LEASE_OWNER=""
TEARDOWN_LEASE_GENERATION=""
TEARDOWN_LEASE_EXPIRES_EPOCH=""
TEARDOWN_LEASE_HELD="false"
TEARDOWN_LEASE_TTL_SECONDS=3600
GCS_OBJECT_GENERATION=""
GCLOUD_PROBE_OUTPUT=""
GCLOUD_PROBE_ERROR=""
GCP_PROJECT_LIFECYCLE_STATE=""
TEARDOWN_CURRENT_STEP="Starting"
TEARDOWN_STARTED="false"
TEARDOWN_COMPLETE_SENT="false"
TEARDOWN_CALLBACK_RESPONSE=""

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

log_step() {
    TEARDOWN_CURRENT_STEP=$1
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

resolve_terraform_binary() {
    local candidate
    candidate=$(command -v terraform 2>/dev/null || true)
    case "$candidate" in
        /*) ;;
        *) log_error "Terraform is unavailable or did not resolve to an absolute path"; return 1 ;;
    esac
    if [ ! -x "$candidate" ]; then
        log_error "Terraform is not executable: $candidate"
        return 1
    fi
    TERRAFORM_BIN="$candidate"
    if ! "$TERRAFORM_BIN" version >/dev/null 2>&1; then
        log_error "Terraform failed its executable verification"
        TERRAFORM_BIN=""
        return 1
    fi
}

terraform_cli() {
    [ -n "$TERRAFORM_BIN" ] && [ -x "$TERRAFORM_BIN" ] || return 127
    "$TERRAFORM_BIN" "$@"
}

sha256_file() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        log_error "No SHA-256 utility is available"
        return 1
    fi
}

# The deployment operator role cannot edit IAM, and a teardown destroy removes IAM
# bindings. Refuse before the destroy starts unless the active gcloud identity holds
# the IAM administrator contract; iam-administrator-gate.sh prints the deliberate
# route. The token reaches the gate on stdin, never in a process listing.
teardown_iam_administrator_gate() {
    local changes_file=$1
    local account
    local member

    account=${CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT:-}
    if [ -z "$account" ]; then
        account=$(gcloud config get-value auth/impersonate_service_account 2>/dev/null || true)
    fi
    case "$account" in
        ''|'(unset)') account=$(gcloud config get-value account 2>/dev/null || true) ;;
    esac
    case "$account" in
        *.gserviceaccount.com) member="serviceAccount:$account" ;;
        *@*) member="user:$account" ;;
        *)
            log_error "Could not represent the active gcloud identity as an IAM member"
            return 1
            ;;
    esac
    { gcloud auth print-access-token 2>/dev/null || true; } | "$IAM_ADMINISTRATOR_GATE" \
        --project="$PROJECT_ID" --member="$member" --plan-json="$changes_file" \
        --reason="This teardown removes IAM bindings."
}

verify_destroy_plan_integrity() {
    local current_sha256
    [ -n "$DESTROY_PLAN_SHA256" ] || {
        log_error "Terraform destroy plan has no recorded SHA-256"
        return 1
    }
    current_sha256=$(sha256_file "$DESTROY_PLAN_FILE") || return 1
    if [ "$current_sha256" != "$DESTROY_PLAN_SHA256" ]; then
        log_error "Terraform destroy plan changed after approval gating"
        return 1
    fi
}

# The one definition of "gcloud says it is not there", spelled exactly as setup.sh's.
# teardown.sh and setup.sh operate the same lease object and the same state bucket, so a
# response one reads as absent the other must read as absent too;
# testing/test-setup-lifecycle-contracts.sh holds every copy to setup.sh's spelling. Loose
# prose such as "not found" is deliberately not matched: "credential file not found after
# connection reset" is a failure, and reading a failure as absence is how teardown used to
# leave a state bucket in place and report it deleted.
gcloud_output_is_not_found() {
    printf '%s\n' "$1" | grep -Eq '(^|[^[:alnum:]_])404([^[:alnum:]_]|$)|(^|[^[:alnum:]_])NOT_FOUND([^[:alnum:]_]|$)|(^|[[:space:]])Not found:|Requested entity was not found'
}

# The one resource probe. Every gcloud call that asks whether a resource exists, reads a
# resource or deletes one goes through it, so the next resource cannot repeat the defect
# that was found three times, each time in one more place: a probe that read
# every failure -- no credentials, no permission, no network -- as "absent" and carried on
# to delete or to report success. Usage: gcloud_probe "<failure message>" <command...>
#   0: the command succeeded; its standard output is in GCLOUD_PROBE_OUTPUT.
#   1: it failed and gcloud answered not-found (gcloud_output_is_not_found). Only this
#      may be read as "absent" or "already deleted".
#   2: it failed any other way. The failure message and gcloud's own error output are
#      printed, and the caller must stop rather than guess.
# GCLOUD_PROBE_ERROR holds the command's standard error either way. Standard output is
# never printed, because a secrets read returns the secret there; copy what you need out
# of GCLOUD_PROBE_OUTPUT and unset it.
gcloud_probe_report() {
    log_error "$1"
    if [ -n "$GCLOUD_PROBE_ERROR" ]; then
        printf '%s\n' "$GCLOUD_PROBE_ERROR" | sed 's/^/  /'
    else
        echo "  gcloud printed no error message"
    fi
}

gcloud_probe() {
    local failure_message=$1
    local error_file
    local rc
    shift
    GCLOUD_PROBE_OUTPUT=""
    GCLOUD_PROBE_ERROR=""
    error_file=$(mktemp "${TMPDIR:-/tmp}/corco-teardown-gcloud.XXXXXX") || {
        log_error "$failure_message"
        echo "  Could not create a temporary file for gcloud's error output"
        return 2
    }
    GCLOUD_PROBE_OUTPUT=$("$@" 2>"$error_file" </dev/null)
    rc=$?
    GCLOUD_PROBE_ERROR=$(cat "$error_file")
    rm -f "$error_file"
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    if gcloud_output_is_not_found "$GCLOUD_PROBE_ERROR"; then
        return 1
    fi
    gcloud_probe_report "$failure_message"
    return 2
}

# The same probe for a call that must succeed, such as a list or a token read, where a
# not-found answer is a failure too. 0: it succeeded, output in GCLOUD_PROBE_OUTPUT.
# 2: it failed any way at all, and the failure is printed.
gcloud_require() {
    local failure_message=$1
    local rc
    gcloud_probe "$@"
    rc=$?
    if [ "$rc" -eq 1 ]; then
        gcloud_probe_report "$failure_message"
        return 2
    fi
    return "$rc"
}

describe_gcs_object_generation() {
    local uri=$1
    local rc
    gcloud_probe "Could not determine GCS object generation for $uri" gcloud storage objects describe "$uri" --format='value(generation)'
    rc=$?
    if [ "$rc" -eq 0 ]; then
        if printf '%s\n' "$GCLOUD_PROBE_OUTPUT" | grep -Eq '^[1-9][0-9]*$'; then
            GCS_OBJECT_GENERATION="$GCLOUD_PROBE_OUTPUT"
            return 0
        fi
        log_error "Could not determine GCS object generation for $uri"
        printf '  gcloud answered a generation that is not a positive integer: %s\n' "${GCLOUD_PROBE_OUTPUT:-nothing}"
        return 2
    fi
    return "$rc"
}

# 0: the bucket exists. 1: gcloud answered that it does not. 2: anything else -- no
# gcloud, no credentials, no permission, no network. Only 1 may be read as "already
# deleted"; the probe this replaced sent every failure to that branch.
describe_state_bucket_presence() {
    local bucket=$1
    local rc
    gcloud_probe "Could not determine whether Terraform state bucket gs://${bucket} exists; it may still exist" gcloud storage buckets describe "gs://${bucket}" --format='value(name)'
    rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$GCLOUD_PROBE_OUTPUT" ]; then
        log_error "Could not determine whether Terraform state bucket gs://${bucket} exists; it may still exist"
        echo "  gcloud succeeded but answered no bucket name"
        return 2
    fi
    return "$rc"
}

# 0: the project exists. 1: gcloud answered that it does not, or the project is already
# DELETE_REQUESTED or DELETE_IN_PROGRESS (GCP_PROJECT_LIFECYCLE_STATE records which).
# 2: anything else. GCP answers a permission error both for a project the caller cannot
# see and for one purged more than 30 days ago, so a 403 never proves a project gone:
# only 1 may take the local-cleanup-only path, which deletes the tfvars and the local
# state file.
describe_gcp_project_presence() {
    local project=$1
    local rc
    local answered_id=""
    local lifecycle_state=""
    GCP_PROJECT_LIFECYCLE_STATE=""
    gcloud_probe "Could not determine whether GCP project $project exists; it may still exist" gcloud projects describe "$project" --format='value(projectId,lifecycleState)'
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    read -r answered_id lifecycle_state <<< "$GCLOUD_PROBE_OUTPUT"
    if [ "$answered_id" != "$project" ]; then
        log_error "Could not determine whether GCP project $project exists; it may still exist"
        printf '  gcloud projects describe answered for a different project: %s\n' "${answered_id:-nothing}"
        return 2
    fi
    GCP_PROJECT_LIFECYCLE_STATE=${lifecycle_state:-ACTIVE}
    case "$GCP_PROJECT_LIFECYCLE_STATE" in
        DELETE_REQUESTED|DELETE_IN_PROGRESS) return 1 ;;
    esac
    return 0
}

read_stable_gcs_object() {
    local uri=$1
    local destination=$2
    local expected_generation=$3
    if ! gcloud storage cp "$uri" "$destination" --quiet; then
        return 1
    fi
    if ! describe_gcs_object_generation "$uri" || [ "$GCS_OBJECT_GENERATION" != "$expected_generation" ]; then
        return 1
    fi
}

lease_file_owner() {
    awk -F= '$1 == "owner" { print $2; exit }' "$1"
}

lease_file_expires_epoch() {
    awk -F= '$1 == "expires_epoch" { print $2; exit }' "$1"
}

validate_teardown_lease_file() {
    awk -F= '
        $1 == "owner" && $2 != "" && !seen_owner++ { next }
        $1 == "expires_epoch" && $2 ~ /^[0-9]+$/ && !seen_expires++ { next }
        { exit 1 }
        END { if (seen_owner != 1 || seen_expires != 1) exit 1 }
    ' "$1"
}

write_lease_candidate() {
    local destination=$1
    local expires_epoch=$2
    printf 'owner=%s\nexpires_epoch=%s\n' "$TEARDOWN_LEASE_OWNER" "$expires_epoch" > "$destination"
}

acquire_teardown_lease() {
    local now_epoch
    local existing_owner
    local existing_expires
    local expected_generation
    local lease_file
    local describe_rc
    local hostname_value
    local expires_epoch

    hostname_value=$(hostname 2>/dev/null || printf unknown-host)
    now_epoch=$(date +%s)
    TEARDOWN_LEASE_URI="gs://${PROJECT_ID}-tfstate/corco-setup/${DOMAIN}.lease"
    TEARDOWN_LEASE_OWNER="${hostname_value}:$$:${now_epoch}:${RANDOM:-0}"
    lease_file=$(mktemp "${TMPDIR:-/tmp}/corco-teardown-lease.XXXXXX") || return 1

    if describe_gcs_object_generation "$TEARDOWN_LEASE_URI"; then
        expected_generation="$GCS_OBJECT_GENERATION"
        if ! read_stable_gcs_object "$TEARDOWN_LEASE_URI" "$lease_file" "$expected_generation"; then
            rm -f "$lease_file"
            log_error "Could not read the existing teardown lease consistently"
            return 1
        fi
        if ! validate_teardown_lease_file "$lease_file"; then
            rm -f "$lease_file"
            log_error "Existing teardown lease is malformed"
            return 1
        fi
        existing_owner=$(lease_file_owner "$lease_file")
        existing_expires=$(lease_file_expires_epoch "$lease_file")
        if [ "$existing_owner" != "$TEARDOWN_LEASE_OWNER" ] && [ "$existing_expires" -gt "$now_epoch" ]; then
            rm -f "$lease_file"
            log_error "Another deployment operation owns the lease for $DOMAIN"
            echo "  Owner: $existing_owner"
            echo "  Expires epoch: $existing_expires"
            return 1
        fi
    else
        describe_rc=$?
        if [ "$describe_rc" -ne 1 ]; then
            rm -f "$lease_file"
            return 1
        fi
        expected_generation=0
    fi

    expires_epoch=$((now_epoch + TEARDOWN_LEASE_TTL_SECONDS))
    write_lease_candidate "$lease_file" "$expires_epoch" || {
        rm -f "$lease_file"
        return 1
    }
    if ! gcloud storage cp "$lease_file" "$TEARDOWN_LEASE_URI" --if-generation-match="$expected_generation" --quiet; then
        rm -f "$lease_file"
        log_error "Could not acquire the teardown lease; its generation changed"
        return 1
    fi
    if ! describe_gcs_object_generation "$TEARDOWN_LEASE_URI"; then
        rm -f "$lease_file"
        log_error "Could not confirm the acquired teardown lease"
        return 1
    fi
    TEARDOWN_LEASE_GENERATION="$GCS_OBJECT_GENERATION"
    if ! read_stable_gcs_object "$TEARDOWN_LEASE_URI" "$lease_file" "$TEARDOWN_LEASE_GENERATION" || \
       ! validate_teardown_lease_file "$lease_file" || \
       [ "$(lease_file_owner "$lease_file")" != "$TEARDOWN_LEASE_OWNER" ] || \
       [ "$(lease_file_expires_epoch "$lease_file")" != "$expires_epoch" ]; then
        rm -f "$lease_file"
        log_error "Could not verify ownership of the acquired teardown lease"
        return 1
    fi
    rm -f "$lease_file"
    TEARDOWN_LEASE_EXPIRES_EPOCH="$expires_epoch"
    TEARDOWN_LEASE_HELD="true"
    return 0
}

renew_teardown_lease() {
    local now_epoch
    local current_generation
    local current_owner
    local lease_file
    local expires_epoch

    [ "$TEARDOWN_LEASE_HELD" = "true" ] || {
        log_error "Cannot renew an unowned teardown lease"
        return 1
    }
    if ! describe_gcs_object_generation "$TEARDOWN_LEASE_URI"; then
        log_error "The teardown lease disappeared before renewal"
        return 1
    fi
    current_generation="$GCS_OBJECT_GENERATION"
    lease_file=$(mktemp "${TMPDIR:-/tmp}/corco-teardown-lease.XXXXXX") || return 1
    if ! read_stable_gcs_object "$TEARDOWN_LEASE_URI" "$lease_file" "$current_generation"; then
        rm -f "$lease_file"
        log_error "Could not read the teardown lease before renewal"
        return 1
    fi
    if ! validate_teardown_lease_file "$lease_file"; then
        rm -f "$lease_file"
        log_error "Teardown lease is malformed before renewal"
        return 1
    fi
    current_owner=$(lease_file_owner "$lease_file")
    if [ "$current_owner" != "$TEARDOWN_LEASE_OWNER" ]; then
        rm -f "$lease_file"
        log_error "Teardown lease ownership changed before renewal"
        return 1
    fi
    now_epoch=$(date +%s)
    expires_epoch=$((now_epoch + TEARDOWN_LEASE_TTL_SECONDS))
    write_lease_candidate "$lease_file" "$expires_epoch" || {
        rm -f "$lease_file"
        return 1
    }
    if ! gcloud storage cp "$lease_file" "$TEARDOWN_LEASE_URI" --if-generation-match="$current_generation" --quiet; then
        rm -f "$lease_file"
        log_error "Could not renew the teardown lease with generation CAS"
        return 1
    fi
    if ! describe_gcs_object_generation "$TEARDOWN_LEASE_URI"; then
        rm -f "$lease_file"
        return 1
    fi
    TEARDOWN_LEASE_GENERATION="$GCS_OBJECT_GENERATION"
    if ! read_stable_gcs_object "$TEARDOWN_LEASE_URI" "$lease_file" "$TEARDOWN_LEASE_GENERATION" || \
       ! validate_teardown_lease_file "$lease_file" || \
       [ "$(lease_file_owner "$lease_file")" != "$TEARDOWN_LEASE_OWNER" ] || \
       [ "$(lease_file_expires_epoch "$lease_file")" != "$expires_epoch" ]; then
        rm -f "$lease_file"
        log_error "Could not verify the renewed teardown lease"
        return 1
    fi
    rm -f "$lease_file"
    TEARDOWN_LEASE_EXPIRES_EPOCH="$expires_epoch"
    return 0
}

release_teardown_lease() {
    local current_generation
    local current_owner
    local lease_file
    local describe_rc

    [ "$TEARDOWN_LEASE_HELD" = "true" ] || return 0
    if describe_gcs_object_generation "$TEARDOWN_LEASE_URI"; then
        current_generation="$GCS_OBJECT_GENERATION"
    else
        describe_rc=$?
        if [ "$describe_rc" -eq 1 ]; then
            TEARDOWN_LEASE_HELD="false"
            TEARDOWN_LEASE_GENERATION=""
            TEARDOWN_LEASE_EXPIRES_EPOCH=""
            return 0
        fi
        return 1
    fi
    lease_file=$(mktemp "${TMPDIR:-/tmp}/corco-teardown-lease.XXXXXX") || return 1
    if ! read_stable_gcs_object "$TEARDOWN_LEASE_URI" "$lease_file" "$current_generation"; then
        rm -f "$lease_file"
        return 1
    fi
    if ! validate_teardown_lease_file "$lease_file"; then
        rm -f "$lease_file"
        log_error "Refusing to release a malformed teardown lease"
        return 1
    fi
    current_owner=$(lease_file_owner "$lease_file")
    rm -f "$lease_file"
    if [ "$current_owner" != "$TEARDOWN_LEASE_OWNER" ]; then
        log_error "Refusing to release a teardown lease owned by another run"
        return 1
    fi
    if ! gcloud storage rm "$TEARDOWN_LEASE_URI" --if-generation-match="$current_generation" --quiet; then
        log_error "Could not release the teardown lease with generation CAS"
        return 1
    fi
    TEARDOWN_LEASE_HELD="false"
    TEARDOWN_LEASE_GENERATION=""
    TEARDOWN_LEASE_EXPIRES_EPOCH=""
    return 0
}

validate_setup_state_file() {
    awk -F= '
        !/^[A-Za-z_][A-Za-z0-9_]*=/ { exit 1 }
        {
            key = $0
            sub(/=.*/, "", key)
            if (seen[key]++) exit 1
            if (key == "STATE_REVISION" && $2 !~ /^[0-9]+$/) exit 1
            if (key == "STATE_BASE_GENERATION" && $2 !~ /^(0|[1-9][0-9]*)$/) exit 1
        }
    ' "$1"
}

setup_state_revision() {
    local revision
    revision=$(awk -F= '$1 == "STATE_REVISION" { print $2; exit }' "$1" 2>/dev/null)
    case "$revision" in
        '') printf '%s\n' 0 ;;
        0|[1-9]|[1-9][0-9]*) printf '%s\n' "$revision" ;;
        *) return 1 ;;
    esac
}

write_teardown_tombstone_candidate() {
    local destination=$1
    local revision=$2
    local base_generation=$3
    printf '%s\n' \
        'setup_completed=false' \
        'step_terraform=false' \
        "PROJECT_ID=$PROJECT_ID" \
        "DOMAIN=$DOMAIN" \
        'TEARDOWN_TOMBSTONE=true' \
        "STATE_REVISION=$revision" \
        "STATE_BASE_GENERATION=$base_generation" \
        > "$destination"
}

commit_partial_teardown_tombstone() {
    local state_dir="$HOME/.corco-setup"
    local state_file="$state_dir/${DOMAIN}.state"
    local state_uri="gs://${PROJECT_ID}-tfstate/corco-setup/${DOMAIN}.state"
    local expected_generation
    local current_revision
    local candidate_file
    local snapshot_file
    local verified_generation
    local describe_rc

    umask 077
    mkdir -p "$state_dir" || return 1
    chmod 700 "$state_dir" || return 1
    snapshot_file=$(mktemp "$state_dir/.teardown-state.read.XXXXXX") || return 1

    if describe_gcs_object_generation "$state_uri"; then
        expected_generation="$GCS_OBJECT_GENERATION"
        if ! read_stable_gcs_object "$state_uri" "$snapshot_file" "$expected_generation" || \
           ! validate_setup_state_file "$snapshot_file"; then
            rm -f "$snapshot_file"
            log_error "Could not read a valid stable setup-state ancestor"
            return 1
        fi
        current_revision=$(setup_state_revision "$snapshot_file") || {
            rm -f "$snapshot_file"
            return 1
        }
    else
        describe_rc=$?
        if [ "$describe_rc" -ne 1 ]; then
            rm -f "$snapshot_file"
            return 1
        fi
        expected_generation=0
        if [ -f "$state_file" ]; then
            if ! validate_setup_state_file "$state_file"; then
                rm -f "$snapshot_file"
                log_error "Local setup state is invalid"
                return 1
            fi
            current_revision=$(setup_state_revision "$state_file") || {
                rm -f "$snapshot_file"
                return 1
            }
        else
            current_revision=0
        fi
    fi
    rm -f "$snapshot_file"

    candidate_file=$(mktemp "$state_dir/.teardown-state.write.XXXXXX") || return 1
    if ! write_teardown_tombstone_candidate "$candidate_file" "$((current_revision + 1))" "$expected_generation"; then
        rm -f "$candidate_file"
        return 1
    fi

    renew_teardown_lease || {
        rm -f "$candidate_file"
        return 1
    }
    if ! gcloud storage cp "$candidate_file" "$state_uri" \
        --if-generation-match="$expected_generation" --quiet; then
        rm -f "$candidate_file"
        log_error "Could not CAS-write the teardown setup-state tombstone"
        echo "  Local setup state was not changed."
        return 1
    fi
    if ! describe_gcs_object_generation "$state_uri"; then
        rm -f "$candidate_file"
        log_error "Could not verify the remote teardown tombstone generation"
        return 1
    fi
    verified_generation="$GCS_OBJECT_GENERATION"
    snapshot_file=$(mktemp "$state_dir/.teardown-state.verify.XXXXXX") || {
        rm -f "$candidate_file"
        return 1
    }
    if ! read_stable_gcs_object "$state_uri" "$snapshot_file" "$verified_generation" || \
       ! validate_setup_state_file "$snapshot_file" || \
       ! cmp -s "$candidate_file" "$snapshot_file"; then
        rm -f "$snapshot_file" "$candidate_file"
        log_error "Remote teardown tombstone did not verify after CAS"
        return 1
    fi
    rm -f "$snapshot_file"

    if ! mv "$candidate_file" "$state_file"; then
        log_error "Remote teardown tombstone advanced, but local atomic commit failed"
        echo "  The verified candidate remains at $candidate_file."
        return 1
    fi
    return 0
}

# Every Corco callback goes through this one sender: send_teardown_callback <route> <fields>,
# where <fields> is the JSON members after "domain" and "token", for example
# '"delete_data": true, "timestamp": "..."'. The sender adds the domain and the token that
# authorizes this tenant's teardown itself, so no caller handles the token and the one
# line that writes it sits inside the group piped to curl. It reaches curl on standard
# input rather than in argv. A -d argument stands in /proc/<pid>/cmdline for the
# life of the request, and this script runs in a Cloud Shell VM shared with whatever else
# the operator is running -- any of which can read it. setup.sh:3466 and :6570 were closed
# the same way, and the operator-access state check further down this file already uses
# the form. A curl config value is one line, so the body is emitted compact; the URL stays
# an argument because it carries no credential. Returns 0 only when Corco answered
# {"status": "ok"}; its answer is in TEARDOWN_CALLBACK_RESPONSE either way.
send_teardown_callback() {
    local route=$1
    local fields=$2
    local domain=$DOMAIN
    local CALLBACK_TOKEN
    TEARDOWN_CALLBACK_RESPONSE=""
    if ! command -v curl >/dev/null 2>&1; then
        TEARDOWN_CALLBACK_RESPONSE="curl is not available"
        return 1
    fi
    # A curl config value is one double-quoted string, so each backslash and quote in it
    # is escaped for the config file.
    fields=${fields//\\/\\\\}
    fields=${fields//\"/\\\"}
    domain=${domain//\\/\\\\}
    domain=${domain//\"/\\\"}
    CALLBACK_TOKEN=${TEARDOWN_TOKEN//\\/\\\\}
    CALLBACK_TOKEN=${CALLBACK_TOKEN//\"/\\\"}
    if ! TEARDOWN_CALLBACK_RESPONSE=$(
        {
            printf '%s\n' 'silent' 'request = "POST"'
            printf '%s\n' 'header = "Content-Type: application/json"'
            printf 'data = "{\\"domain\\": \\"%s\\", \\"token\\": \\"%s\\", %s}"\n' "$domain" "$CALLBACK_TOKEN" "$fields"
        } | curl -q --config - "$TEARDOWN_CALLBACK_URL/$route" 2>&1
    ); then
        TEARDOWN_CALLBACK_RESPONSE="curl failed: ${TEARDOWN_CALLBACK_RESPONSE:-no output}"
        return 1
    fi
    printf '%s\n' "$TEARDOWN_CALLBACK_RESPONSE" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'
}

# A teardown that told Corco it started and then fails tells Corco that it failed, and at
# which step, so the record does not stay "in progress" while the operator fixes the cause
# and Corco is never told a teardown completed that did not. It runs from the
# EXIT trap, so it covers every exit path after the start callback, including an exit
# inside a helper, and it never changes the exit status.
report_teardown_failure_to_corco() {
    local exit_status=$1
    local failed_step
    failed_step=$(printf '%s' "$TEARDOWN_CURRENT_STEP" | LC_ALL=C tr -cd '[:alnum:] :._()-' | cut -c1-120)
    if send_teardown_callback failed "$(printf '"failed_step": "%s", "exit_status": %d, "timestamp": "%s"' "$failed_step" "$exit_status" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")")"; then
        log_warning "Corco was told the teardown failed at: $failed_step"
    else
        log_error "Could not tell Corco that the teardown failed at: $failed_step"
        echo "  Response: $TEARDOWN_CALLBACK_RESPONSE"
    fi
}

cleanup_teardown_runtime() {
    local original_status=$1
    local cleanup_status=0
    local final_status

    if ! release_teardown_lease; then
        cleanup_status=1
    fi
    if [ -n "$DESTROY_PLAN_FILE" ] && [ -f "$DESTROY_PLAN_FILE" ]; then
        rm -f "$DESTROY_PLAN_FILE"
    fi
    if [ -n "$DESTROY_PLAN_CHANGES_FILE" ] && [ -f "$DESTROY_PLAN_CHANGES_FILE" ]; then
        rm -f "$DESTROY_PLAN_CHANGES_FILE"
    fi
    if [ -n "$TEARDOWN_RUN_DIR" ] && [ -d "$TEARDOWN_RUN_DIR" ]; then
        rmdir "$TEARDOWN_RUN_DIR" 2>/dev/null || true
    fi
    trap - EXIT
    final_status=$original_status
    if [ "$final_status" -eq 0 ]; then
        final_status=$cleanup_status
    fi
    if [ "$final_status" -ne 0 ] && [ "$TEARDOWN_STARTED" = "true" ] && [ "$TEARDOWN_COMPLETE_SENT" != "true" ]; then
        report_teardown_failure_to_corco "$final_status"
    fi
    exit "$final_status"
}

trap 'cleanup_teardown_runtime $?' EXIT

prompt_yes_no() {
    local prompt_text=$1
    local default=$2
    
    if [ "$default" == "y" ]; then
        read -p "$prompt_text [Y/n]: " response
        response="${response:-y}"
    else
        read -p "$prompt_text [y/N]: " response
        response="${response:-n}"
    fi
    
    [[ "$response" =~ ^[Yy] ]]
}

# Remove the tenant's Telegram webhook before the function it points at is destroyed,
# so Telegram does not keep calling a dead URL. Both destructive paths call it: the
# project deletion, and the Terraform destroy, which removes the Telegram function while
# the bot token stays in Secret Manager. Before, only the project deletion did, so a
# partial or --keep-project teardown left the webhook pointing at nothing.
#
# A secret gcloud answers not-found for means no bot and no webhook, and returns 0. Any
# other failure to read it returns 1, and the caller stops before it destroys anything:
# a failed read is not an absent bot. Telegram's answer is checked, and anything but
# "ok":true is a warning, not a stop, because the destroy is still what the operator
# asked for and the webhook can be removed later with the token that stays behind.
deregister_telegram_webhook() {
    local telegram_token=""
    local telegram_token_probe
    local escaped_telegram_token
    local webhook_answer
    gcloud_probe "Could not read CORCO_TELEGRAM_BOT_TOKEN to remove the Telegram webhook" gcloud secrets versions access latest --secret="CORCO_TELEGRAM_BOT_TOKEN" --project="$PROJECT_ID"
    telegram_token_probe=$?
    if [ "$telegram_token_probe" -eq 0 ]; then
        telegram_token=$GCLOUD_PROBE_OUTPUT
    fi
    GCLOUD_PROBE_OUTPUT=""
    if [ "$telegram_token_probe" -eq 2 ]; then
        return 1
    fi
    if [ -z "$telegram_token" ]; then
        echo "No Telegram bot token found - skipping webhook cleanup"
        return 0
    fi
    echo "Removing Telegram webhook..."
    # The tenant's live bot token, so it reaches curl on standard input like the Corco
    # callbacks -- an argument stands in /proc/<pid>/cmdline for the life of the
    # request, readable by anything else sharing this Cloud Shell VM. What moves here is
    # the WHOLE URL rather than a body, because the Telegram API authenticates by URL
    # PATH alone: there is no body and no header to put the credential in, so the only
    # way it leaves argv is for the URL to leave with it. A config value is one line and
    # is unescaped by curl, so a backslash or a quote in the token would otherwise change
    # the URL; a bot token contains neither, and escaping them costs nothing.
    escaped_telegram_token=${telegram_token//\\/\\\\}
    escaped_telegram_token=${escaped_telegram_token//\"/\\\"}
    webhook_answer=$(
        {
            printf '%s\n' 'silent'
            printf 'url = "https://api.telegram.org/bot%s/deleteWebhook"\n' "$escaped_telegram_token"
        } | curl -q --config - 2>/dev/null || echo ""
    )
    unset escaped_telegram_token telegram_token
    # deleteWebhook answers ok even when no webhook is set, so any other answer is a
    # failure, not an absent webhook.
    if echo "$webhook_answer" | grep -q '"ok":true'; then
        log_success "Telegram webhook removed"
    else
        log_warning "Could not remove the Telegram webhook; Telegram may keep calling the removed deployment"
        echo "  Telegram answered: ${webhook_answer:-nothing}"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------

DOMAIN=""
# The teardown token authorises deleting a whole tenant, so it has three routes that keep
# it out of this process's command line and one, kept for compatibility, that does not:
#
#   CORCO_TEARDOWN_TOKEN in the environment  -- unattended callers
#   --token-stdin                            -- one line on standard input, for pipelines
#   the prompt below                         -- nothing supplied and a terminal to ask on
#   --token / --token=<value>                -- still accepted, and warned about
#
# /proc/<pid>/cmdline is world-readable and holds a process's arguments for its whole
# life, which for a teardown is minutes; the same argument is written to the operator's
# shell history besides. This variable used to be reset unconditionally right here, so
# --token was the ONLY route in and the printed operator instructions could not teach
# anything else. The environment is read once and immediately unset, so the gcloud,
# terraform and curl children this script spawns do not inherit the credential.
TEARDOWN_TOKEN="${CORCO_TEARDOWN_TOKEN:-}"
unset CORCO_TEARDOWN_TOKEN
TEARDOWN_TOKEN_FROM_ARGV=false
DELETE_DATA=false
DELETE_SECRETS=false
DELETE_CONFIG=false
RESTORE_ORG_POLICY=false
FORCE=false
KEEP_PROJECT=false
PROJECT_OVERRIDE=""
GCLOUD_CONFIG_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --token=*)
            TEARDOWN_TOKEN="${1#*=}"
            TEARDOWN_TOKEN_FROM_ARGV=true
            shift
            ;;
        --token)
            TEARDOWN_TOKEN="$2"
            TEARDOWN_TOKEN_FROM_ARGV=true
            shift 2
            ;;
        # One line, unechoed, and gone from the pipe once read. The flag names the route
        # so a caller cannot supply a token this way by accident: a script's own stdin
        # otherwise carries the operator's typed confirmations further down.
        --token-stdin)
            IFS= read -r TEARDOWN_TOKEN || true
            shift
            ;;
        --delete-data)
            DELETE_DATA=true
            shift
            ;;
        # setup.sh's reuse-project path has always passed these two; the parser
        # rejecting them meant its "clean up and reuse this project" menu option
        # aborted on the first line, every time.
        --project=*)
            PROJECT_OVERRIDE="${1#*=}"
            shift
            ;;
        --project)
            PROJECT_OVERRIDE="$2"
            shift 2
            ;;
        --gcloud-config=*)
            GCLOUD_CONFIG_OVERRIDE="${1#*=}"
            shift
            ;;
        --gcloud-config)
            GCLOUD_CONFIG_OVERRIDE="$2"
            shift 2
            ;;
        --keep-project)
            KEEP_PROJECT=true
            shift
            ;;
        --delete-secrets)
            DELETE_SECRETS=true
            shift
            ;;
        --delete-config)
            DELETE_CONFIG=true
            shift
            ;;
        --all)
            DELETE_DATA=true
            DELETE_SECRETS=true
            DELETE_CONFIG=true
            shift
            ;;
        --force|-f)
            FORCE=true
            shift
            ;;
        --restore-org-policy)
            RESTORE_ORG_POLICY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 <domain> [options]"
            echo ""
            echo "By default, teardown removes ONLY infrastructure (functions, schedulers,"
            echo "service accounts) but PRESERVES data that cannot be easily restored:"
            echo "  • BigQuery tables (all communications data)"
            echo "  • Secrets (API keys, credentials)"  
            echo "  • Configuration files (tfvars)"
            echo ""
            echo "Supplying the teardown token (it authorizes the two Corco callbacks):"
            echo "  CORCO_TEARDOWN_TOKEN=<token> $0 <domain>   Read from the environment"
            echo "  $0 <domain> --token-stdin                   Read one line from stdin"
            echo "  $0 <domain>                                 Prompted for, unechoed"
            echo "  --token=<token>      Accepted, but DISCOURAGED: an argument stands in"
            echo "                       /proc/<pid>/cmdline for the whole teardown and is"
            echo "                       written to your shell history"
            echo ""
            echo "Options:"
            echo "  --delete-data        Also delete BigQuery dataset (IRREVERSIBLE)"
            echo "  --keep-project       With --delete-data: never include the GCP project"
            echo "                       in the destroy plan (setup.sh's reuse path)"
            echo "  --project=<id>       Use this project id instead of tfvars/registry"
            echo "  --gcloud-config=<name>  Off Cloud Shell: run every gcloud call of this"
            echo "                       teardown in this gcloud configuration. Without it:"
            echo "                       CLOUDSDK_ACTIVE_CONFIG_NAME if set, else the"
            echo "                       configuration named like the domain's second-to-last"
            echo "                       label (example for example.com) if it exists, else"
            echo "                       the active one. Nothing is written to gcloud's files."
            echo "  --delete-secrets     Also delete CORCO_* secrets"
            echo "  --delete-config      Also delete the tfvars configuration file, the local"
            echo "                       setup checkpoint, the local Terraform cache, and --"
            echo "                       when no operator-access state remains in it -- the"
            echo "                       whole gs://<project>-tfstate Terraform state bucket,"
            echo "                       including the portable corco-setup/<domain>.state"
            echo "                       checkpoint that a fresh Cloud Shell restores from."
            echo "                       Asks for the project ID first, because BigQuery"
            echo "                       and the secrets survive it and nothing about the"
            echo "                       aftermath announces the loss. --force does NOT"
            echo "                       skip that confirmation."
            echo "  --all                Delete everything (data + secrets + config) AND"
            echo "                       run 'gcloud projects delete' on the whole GCP"
            echo "                       project, including anything Corco never created"
            echo "                       in it. Add --keep-project to destroy only the"
            echo "                       Corco resources and leave the project standing."
            echo "  --restore-org-policy Reinstate iam.allowedPolicyMemberDomains restriction"
            echo "  --force, -f          Skip confirmation prompts. It does NOT skip either"
            echo "                       typed project-ID confirmation: the one guarding"
            echo "                       'gcloud projects delete', or the one guarding"
            echo "                       --delete-config's destruction of the state bucket."
            echo "  --help, -h           Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 example.com                    # Safe teardown (keeps data)"
            echo "  $0 example.com --delete-secrets   # Teardown + remove secrets"
            echo "  $0 example.com --all              # Complete wipe, deletes the project"
            echo "  $0 example.com --all --keep-project  # Complete wipe, project stays"
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [ -z "$DOMAIN" ]; then
                DOMAIN="$1"
            else
                log_error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Validate inputs
# -----------------------------------------------------------------------------

if [ -z "$DOMAIN" ]; then
    echo "Available deployments:"
    echo ""
    if [ -f "$REGISTRY_FILE" ]; then
        jq -r '.deployments | keys[]' "$REGISTRY_FILE" 2>/dev/null | while read domain; do
            project=$(jq -r ".deployments[\"$domain\"].gcp.project_id // \"unknown\"" "$REGISTRY_FILE")
            echo "  • $domain → $project"
        done
    fi
    echo ""
    read -p "Enter domain to teardown: " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
    log_error "No domain specified"
    exit 1
fi

# Said once, on the run that did it, rather than left to a document nobody re-reads. The
# value is never echoed back -- naming the flag is enough to identify what leaked.
if [ "$TEARDOWN_TOKEN_FROM_ARGV" == "true" ]; then
    log_warning "--token puts the teardown token in this process's command line"
    echo "  /proc/<pid>/cmdline is readable by everything else running on this machine"
    echo "  for as long as the teardown runs, and the argument is in your shell history."
    echo "  Next time: CORCO_TEARDOWN_TOKEN=<token> $0 $DOMAIN, or omit --token and"
    echo "  paste it at the prompt."
fi

# Nothing supplied and a terminal to ask on. Unechoed, and never an argument.
#
# Empty stays allowed, deliberately. The token authenticates the two Corco callbacks and
# nothing else -- it gates no destructive step here -- and an administrator tearing down
# a project they own may legitimately not hold one, which is how the administrator
# rewind tool has always invoked this script.
if [ -z "$TEARDOWN_TOKEN" ] && [ -t 0 ]; then
    read -rs -p "Teardown token (paste it, or press Enter to skip): " TEARDOWN_TOKEN
    echo ""
fi

# Select the gcloud configuration before the first gcloud call, because the derived
# project ID below is probed through it. The project and the configuration are selected
# for THIS PROCESS, never written into the operator's machine. gcloud maps every property
# to CLOUDSDK_<SECTION>_<NAME> (core/properties.py) and reads CLOUDSDK_ACTIVE_CONFIG_NAME
# for the active configuration, so exporting them scopes the choice to this run and its
# children -- which bq and gsutil inherit too. `gcloud config set project` and
# `gcloud config configurations activate` both write to disk and outlive the script: a
# teardown used to leave the torn-down tenant's project as the default of whatever
# configuration happened to be active, so every later command in that configuration,
# including an unrelated session against another tenant, targeted the client's project.
if [ -z "$CLOUD_SHELL" ] && [ -z "$GOOGLE_CLOUD_SHELL" ]; then
    # Local machine: select the gcloud configuration, first match wins, and say which:
    #   1. --gcloud-config=<name>, the operator's explicit choice;
    #   2. CLOUDSDK_ACTIVE_CONFIG_NAME already in the environment, which gcloud itself
    #      honours, so a caller such as setup.sh that exported it keeps it;
    #   3. the configuration named like the domain's second-to-last label (example for
    #      example.com and for app.example.com), used only when one of exactly that name
    #      exists, so no tenant or operator name is written into this script;
    #   4. otherwise the configuration the operator already has active. The first name
    #      `gcloud config configurations list` prints is alphabetical and has nothing to
    #      do with the tenant, and activating it was how an unrelated configuration
    #      acquired the client's project.
    CONFIG_NAME=""
    CONFIG_SOURCE=""
    if [ -n "$GCLOUD_CONFIG_OVERRIDE" ]; then
        CONFIG_NAME="$GCLOUD_CONFIG_OVERRIDE"
        CONFIG_SOURCE="--gcloud-config"
    elif [ -n "${CLOUDSDK_ACTIVE_CONFIG_NAME:-}" ]; then
        CONFIG_NAME="$CLOUDSDK_ACTIVE_CONFIG_NAME"
        CONFIG_SOURCE="CLOUDSDK_ACTIVE_CONFIG_NAME"
    else
        DOMAIN_LABEL=""
        case "$DOMAIN" in
            *.*)
                DOMAIN_LABEL="${DOMAIN%.*}"
                DOMAIN_LABEL="${DOMAIN_LABEL##*.}"
                ;;
        esac
        # A list that fails is not a list without a match: the run would go on in the
        # active configuration, which can belong to another tenant. So it stops here,
        # before the lease, the start callback and any deletion.
        if [ -n "$DOMAIN_LABEL" ]; then
            if ! gcloud_require "Could not list the gcloud configurations" gcloud config configurations list --format='value(name)'; then
                echo "  Nothing has been deleted. Fix gcloud and run the teardown again, or name the"
                echo "  configuration with --gcloud-config=<name>."
                exit 1
            fi
            if printf '%s\n' "$GCLOUD_PROBE_OUTPUT" | grep -Fqx -- "$DOMAIN_LABEL"; then
                CONFIG_NAME="$DOMAIN_LABEL"
                CONFIG_SOURCE="the configuration named like $DOMAIN"
            fi
        fi
    fi

    if [ -n "$CONFIG_NAME" ]; then
        echo "Using gcloud configuration: $CONFIG_NAME (from $CONFIG_SOURCE)"
        export CLOUDSDK_ACTIVE_CONFIG_NAME="$CONFIG_NAME"
    else
        echo "No gcloud configuration is named for $DOMAIN - using the active one"
        echo "  (choose one with --gcloud-config=<name>)"
    fi
fi

# Check tfvars file exists
TFVARS_FILE="$TERRAFORM_DIR/environments/${DOMAIN}.tfvars"
TFVARS_EXISTS=true

if [ ! -f "$TFVARS_FILE" ]; then
    log_warning "No configuration found for domain: $DOMAIN"
    echo "Expected file: $TFVARS_FILE"
    echo ""
    echo "Will attempt cleanup using domain name and registry..."
    TFVARS_EXISTS=false
fi

# Parse tfvars for project info
parse_tfvar() {
    local file=$1
    local key=$2
    grep "^${key}[[:space:]]*=" "$file" 2>/dev/null | sed 's/.*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | head -1
}

PROJECT_ID="$PROJECT_OVERRIDE"
REGION=""
DATASET=""
WORKSPACE_ADMIN=""

if [ "$TFVARS_EXISTS" == "true" ]; then
    # --project wins over the tfvars: the caller (setup.sh's reuse path) knows
    # which project it is about to install into better than a possibly stale file.
    if [ -z "$PROJECT_ID" ]; then
        PROJECT_ID=$(parse_tfvar "$TFVARS_FILE" "gcp_project_id")
    fi
    REGION=$(parse_tfvar "$TFVARS_FILE" "region")
    DATASET=$(parse_tfvar "$TFVARS_FILE" "bigquery_dataset")
    WORKSPACE_ADMIN=$(parse_tfvar "$TFVARS_FILE" "workspace_admin_email")
fi

# Fallback: try to get project_id from registry
if [ -z "$PROJECT_ID" ] && [ -f "$REGISTRY_FILE" ]; then
    PROJECT_ID=$(jq -r ".deployments[\"$DOMAIN\"].gcp.project_id // empty" "$REGISTRY_FILE" 2>/dev/null || echo "")
    REGION=$(jq -r ".deployments[\"$DOMAIN\"].gcp.region // empty" "$REGISTRY_FILE" 2>/dev/null || echo "")
    if [ -n "$PROJECT_ID" ]; then
        log_warning "Using project ID from registry: $PROJECT_ID"
    fi
fi

if [ -z "$PROJECT_ID" ]; then
    # Last resort: derive project ID from domain (same convention as setup.sh)
    SAFE_DOMAIN=$(echo "$DOMAIN" | tr '.' '-' | tr '[:upper:]' '[:lower:]')
    DERIVED_ID="${SAFE_DOMAIN}-ingestion"
    
    # Verify the derived project actually exists. Only gcloud's own not-found answer may
    # send the run to local cleanup, which deletes the local configuration: a probe that
    # failed for any other reason stops here, before anything is deleted.
    describe_gcp_project_presence "$DERIVED_ID"
    DERIVED_PROJECT_PROBE=$?
    if [ "$DERIVED_PROJECT_PROBE" -eq 0 ]; then
        PROJECT_ID="$DERIVED_ID"
        REGION="${REGION:-us-central1}"
        log_warning "Derived project ID from domain: $PROJECT_ID"
    elif [ "$DERIVED_PROJECT_PROBE" -eq 1 ]; then
        log_warning "Could not determine project ID - will only clean up local files"
        echo "  No tfvars file, no registry entry, and gcloud answered that the derived"
        echo "  project $DERIVED_ID does not exist or is already being deleted."
        echo "  Skipping GCP resource deletion."
    else
        echo "  No tfvars file and no registry entry name the project, and the derived"
        echo "  project $DERIVED_ID could not be checked. Nothing has been deleted."
        echo "  Fix the cause above and run the teardown again, or name the project with"
        echo "  --project=<id>."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Header & Confirmation
# -----------------------------------------------------------------------------

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    AI INGESTION - TEARDOWN                               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${RED}This will DESTROY the following resources:${NC}"
echo ""
echo "  Domain:     $DOMAIN"
echo "  Project:    ${PROJECT_ID:-"(not found - local cleanup only)"}"
echo "  Region:     ${REGION:-"(unknown)"}"
echo ""
echo "  ${GREEN}WILL BE DELETED:${NC}"
echo "    • Cloud Functions (gmail-sync, telegram-webhook, etc.)"
echo "    • Cloud Run services"
echo "    • Cloud Scheduler jobs"
echo "    • GCS buckets (recordings, voice samples)"
echo "    • Service accounts"
echo ""
echo "  ${YELLOW}PRESERVED (unless explicitly requested):${NC}"
if [ "$DELETE_DATA" == "true" ]; then
    echo -e "    • BigQuery dataset: ${RED}WILL DELETE${NC} (--delete-data)"
else
    echo "    • BigQuery dataset: $DATASET (use --delete-data to remove)"
fi
if [ "$DELETE_SECRETS" == "true" ]; then
    echo -e "    • Secrets (CORCO_*): ${RED}WILL DELETE${NC} (--delete-secrets)"
else
    echo "    • Secrets (CORCO_*): KEPT (use --delete-secrets to remove)"
fi
if [ "$DELETE_CONFIG" == "true" ]; then
    echo -e "    • Config ($TFVARS_FILE): ${RED}WILL DELETE${NC} (--delete-config)"
    echo -e "    • Terraform state bucket (gs://${PROJECT_ID}-tfstate), including the"
    echo -e "      portable corco-setup/${DOMAIN}.state checkpoint: ${RED}WILL DELETE${NC}"
    echo -e "      unless operator-access state remains in it (--delete-config)"
else
    echo "    • Config: KEPT (use --delete-config to remove)"
fi
# The banner promised "Cloud Functions, Cloud Run services, Cloud Scheduler jobs, GCS
# buckets, Service accounts" and never named the one effect that reaches past them.
# setup.sh explicitly supports installing into a project the customer already uses
# ("Use this project as-is, keeping its data"), so on that shape `gcloud projects
# delete` takes their unrelated workloads with it. An operator cannot weigh a
# consequence nothing tells them about.
if [ "$DELETE_DATA" == "true" ] && [ "$DELETE_SECRETS" == "true" ] && \
   [ "$DELETE_CONFIG" == "true" ] && [ "$KEEP_PROJECT" != "true" ]; then
    echo ""
    echo -e "  ${RED}THE WHOLE GCP PROJECT WILL BE DELETED:${NC}"
    echo -e "    • ${RED}gcloud projects delete ${PROJECT_ID:-"(project id unknown)"}${NC}"
    echo "      This removes EVERYTHING in the project, including any resource"
    echo "      Corco never created. Re-run with --keep-project to destroy only"
    echo "      the Corco resources and leave the project standing."
fi
echo ""

if [ "$FORCE" != "true" ]; then
    echo -e "${YELLOW}Type the domain name to confirm:${NC} $DOMAIN"
    read -p "> " confirm
    if [ "$confirm" != "$DOMAIN" ]; then
        log_error "Confirmation failed. Aborting."
        exit 1
    fi
    echo ""
fi

# The typed-project-id confirmation for a full teardown belongs HERE, ahead of every
# effect, and not beside the `gcloud projects delete` it guards. Two things happen
# between this point and that call and neither is reversible by an abort: the start
# callback moves the registry entry to teardown_in_progress and nothing moves it back,
# and the pre-deletion block deregisters the tenant's Telegram webhook. An operator who
# mistyped the id, or pressed Enter to back out, exited 1 having destroyed nothing --
# except the webhook registration, on a deployment they had explicitly declined to tear
# down, with the run aborted before the summary that would have said so. The project is
# not probed first: this asks before authentication has even run, so an already-deleted
# project is still confirmed rather than guessed at.
#
# `--force` does NOT skip it, and that is the whole point of the prompt. The comment
# further down this file calls project deletion "a deliberate, separate act" and names
# this prompt as what makes it one -- but every automated caller passes --force, so the
# act was never separate from an ordinary teardown for any caller that mattered:
# the two administrator rewind tools both invoke `--all --force`.
# Both are interactive admin tools that already stop for two typed confirmations of
# their own, so the third costs them nothing. A non-interactive caller gets an empty
# read and aborts, which is the safe direction for an irreversible project deletion.
# --keep-project remains the way to run a full teardown unattended.
FULL_PROJECT_TEARDOWN=false
if [ "$DELETE_DATA" == "true" ] && [ "$DELETE_SECRETS" == "true" ] && \
   [ "$DELETE_CONFIG" == "true" ] && [ "$KEEP_PROJECT" != "true" ] && \
   [ -n "$PROJECT_ID" ]; then
    FULL_PROJECT_TEARDOWN=true
fi

if [ "$FULL_PROJECT_TEARDOWN" == "true" ]; then
    echo ""
    echo -e "${RED}⚠️  FULL TEARDOWN: Deleting entire GCP project${NC}"
    echo "   Project: $PROJECT_ID"
    echo "   This will delete ALL resources, data, and configurations."
    echo ""
    echo -e "${YELLOW}Type the project ID to confirm deletion:${NC} $PROJECT_ID"
    read -p "> " confirm_project
    if [ "$confirm_project" != "$PROJECT_ID" ]; then
        log_error "Project confirmation failed. Aborting."
        exit 1
    fi
    echo ""
fi

# The same instrument for --delete-config, for the same reason and in the same place.
#
# The flag's SCOPE is deliberately unchanged: it really does delete the whole
# gs://<project>-tfstate bucket, and narrowing it would leave a tenant's Terraform state
# standing after a config teardown, which is the worse failure. What was missing is a
# confirmation proportionate to that. `teardown.sh <domain> --delete-config` destroys a
# deployment's ENTIRE Terraform state -- the state itself and the portable
# corco-setup/<domain>.state checkpoint a fresh Cloud Shell restores from -- while its
# BigQuery dataset and every one of its secrets survive untouched.
#
# That asymmetry is the whole hazard, and it is why the banner below names both halves
# rather than only the destruction. Everything an operator would look for afterwards is
# still there; the only thing missing is the record that ties it together, and nothing
# about the aftermath announces the loss. A typed domain is consent to "tear this
# deployment down". It is not consent to this.
#
# Not skipped by --force, for the reason given above the project prompt: --force is what
# every automated caller passes, so a prompt it skips is a prompt that never ran for the
# callers that mattered. The two automated callers reach the FULL teardown branch instead
# and are unaffected, and setup.sh's reuse path is an operator sitting at a menu.
#
# Mutually exclusive with the prompt above rather than additional to it: deleting the
# project subsumes the bucket, so the full teardown's own confirmation already covers
# this and asking twice would train the operator to type the id without reading.
if [ "$DELETE_CONFIG" == "true" ] && [ "$FULL_PROJECT_TEARDOWN" != "true" ] && \
   [ -n "$PROJECT_ID" ]; then
    echo ""
    echo -e "${RED}⚠️  --delete-config DESTROYS THIS DEPLOYMENT'S ENTIRE TERRAFORM STATE${NC}"
    echo "   Project: $PROJECT_ID"
    echo ""
    echo -e "   ${RED}DESTROYED, and not rebuildable from what is left:${NC}"
    echo "     - gs://${PROJECT_ID}-tfstate, the whole bucket"
    echo "     - corco-setup/${DOMAIN}.state in it, the portable checkpoint a fresh"
    echo "       Cloud Shell restores this deployment from"
    echo "     - $TFVARS_FILE and the local checkpoint and Terraform cache"
    echo "   (The bucket is kept only if operator-access state remains in it.)"
    echo ""
    echo -e "   ${GREEN}SURVIVES, which is what makes the loss easy to miss:${NC}"
    if [ "$DELETE_DATA" == "true" ]; then
        echo "     - BigQuery: being deleted too (--delete-data)"
    else
        echo "     - BigQuery dataset $DATASET, with all of its data"
    fi
    if [ "$DELETE_SECRETS" == "true" ]; then
        echo "     - Secrets: being deleted too (--delete-secrets)"
    else
        echo "     - Every CORCO_* secret"
    fi
    echo "     - The GCP project itself"
    echo ""
    echo "   So afterwards the data is all still there and nothing can be planned,"
    echo "   upgraded or torn down against it from this state."
    echo ""
    echo -e "${YELLOW}Type the project ID to confirm:${NC} $PROJECT_ID"
    read -p "> " confirm_delete_config
    if [ "$confirm_delete_config" != "$PROJECT_ID" ]; then
        log_error "Project confirmation failed. Aborting."
        exit 1
    fi
    echo ""
fi

# -----------------------------------------------------------------------------
# Verify and fix authentication
# -----------------------------------------------------------------------------

log_step "Verifying Authentication"

# The project for THIS PROCESS only; the configuration was selected the same way above.
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

PROJECT_DELETED="false"
PROJECT_EXISTS="true"

# One decisive project probe. Only gcloud's not-found answer, or a project already
# DELETE_REQUESTED, may send the run to local cleanup only -- which, with --delete-config,
# deletes the tfvars and the local state file. Every other failure stops the run here,
# before the start callback and before anything is deleted.
if [ -z "$PROJECT_ID" ]; then
    PROJECT_EXISTS="false"
    PROJECT_DELETED="true"  # Treat as already deleted for later logic
    log_warning "No project ID - skipping GCP resource deletion"
else
    if [ -n "$CLOUD_SHELL" ] || [ -n "$GOOGLE_CLOUD_SHELL" ]; then
        echo "Running in Cloud Shell - using existing authentication"
    fi
    describe_gcp_project_presence "$PROJECT_ID"
    PROJECT_PRESENCE=$?
    if [ "$PROJECT_PRESENCE" -eq 2 ] && [ -z "$CLOUD_SHELL" ] && [ -z "$GOOGLE_CLOUD_SHELL" ]; then
        echo ""
        echo -e "${YELLOW}Cannot access project. Re-authenticating...${NC}"
        echo ""
        gcloud auth login

        # Also refresh application default credentials (used by Terraform)
        echo ""
        echo "Refreshing Terraform credentials..."
        gcloud auth application-default login
        describe_gcp_project_presence "$PROJECT_ID"
        PROJECT_PRESENCE=$?
    fi
    case "$PROJECT_PRESENCE" in
        0)
            log_success "Authenticated and project accessible: $PROJECT_ID"
            ;;
        1)
            PROJECT_EXISTS="false"
            if [ -n "$GCP_PROJECT_LIFECYCLE_STATE" ]; then
                log_warning "Project $PROJECT_ID is already $GCP_PROJECT_LIFECYCLE_STATE"
            else
                log_warning "gcloud answered that project $PROJECT_ID does not exist"
            fi
            echo "  Continuing with local cleanup only..."
            ;;
        *)
            echo ""
            echo "  GCP answers a permission error both for a project you cannot see and for"
            echo "  one deleted more than 30 days ago, so only a not-found answer proves the"
            echo "  project gone. Nothing has been deleted."
            echo "  Fix the cause above, then run the teardown again. If the project is gone"
            echo "  for good, remove $TFVARS_FILE"
            echo "  and $HOME/.corco-setup/${DOMAIN}.state by hand."
            exit 1
            ;;
    esac
fi

# A teardown that keeps the project removes the deployment with Terraform, and that needs
# the release's deployment/terraform and this deployment's tfvars. A fresh clone of
# corco-installer holds neither unless setup.sh extracted the release into it. Without
# them, the old installer copy printed "nothing was changed", went on, and told Corco the
# teardown was complete over a deployment still running. Stop here instead,
# before the lease and the start callback, while nothing is deleted.
if [ "$PROJECT_EXISTS" == "true" ] && [ "$FULL_PROJECT_TEARDOWN" != "true" ]; then
    if [ ! -d "$TERRAFORM_DIR" ] || [ "$TFVARS_EXISTS" != "true" ]; then
        log_error "This teardown keeps the project, so it needs Terraform and this deployment's configuration"
        if [ ! -d "$TERRAFORM_DIR" ]; then
            echo "  Missing: $TERRAFORM_DIR"
        fi
        if [ "$TFVARS_EXISTS" != "true" ]; then
            echo "  Missing: $TFVARS_FILE"
        fi
        echo "  Nothing has been deleted, and Corco has not been told the teardown started."
        echo "  Run it from the release that installed this deployment (the corco-installer/"
        echo "  folder that setup.sh extracted beside this script, or set CORCO_PLATFORM_ROOT),"
        echo "  or delete the whole project with: --all"
        exit 1
    fi
fi

# Serialize every live-project teardown before either branch changes remote state.
# Local-only cleanup has no resolved project and therefore no valid lease bucket.
if [ "$PROJECT_EXISTS" == "true" ]; then
    acquire_teardown_lease || exit 1
fi

# --delete-config without project deletion removes the Terraform state bucket, and only
# gcloud's answer about that bucket can say whether it is still there. Ask now, while
# nothing is deleted: a login or a permission that cannot read the bucket stops the run
# here, not after the configuration is gone. The cleanup step asks again,
# because a long destroy can outlive the login.
if [ "$PROJECT_EXISTS" == "true" ] && [ "$DELETE_CONFIG" == "true" ] && [ "$FULL_PROJECT_TEARDOWN" != "true" ]; then
    describe_state_bucket_presence "${PROJECT_ID}-tfstate"
    STATE_BUCKET_PREFLIGHT=$?
    if [ "$STATE_BUCKET_PREFLIGHT" -eq 2 ]; then
        echo "  --delete-config deletes this bucket and needs that answer. Nothing has been deleted yet."
        echo "  Fix the cause above, then run the teardown again."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Notify Corco: Teardown Started
# -----------------------------------------------------------------------------

log_step "Notifying Corco: Teardown Started"

DEPLOYER=$(gcloud config get-value account 2>/dev/null || echo "unknown")

# From here on, a run that ends in failure tells Corco so from the EXIT trap
# (report_teardown_failure_to_corco), whatever this callback answered.
TEARDOWN_STARTED="true"
if send_teardown_callback start "$(printf '"initiated_by": "%s", "timestamp": "%s"' "$DEPLOYER" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")")"; then
    log_success "Corco notified of teardown start"
else
    log_warning "Could not notify Corco (proceeding with teardown anyway)"
    echo "  Response: $TEARDOWN_CALLBACK_RESPONSE"
fi

# -----------------------------------------------------------------------------
# Delete Resources
# -----------------------------------------------------------------------------

# For --all teardowns, simply delete the entire GCP project
# This is simpler and more reliable than Terraform (no billing/state issues)
# --keep-project forces the Terraform path below: a run invoked with it must
# never be able to delete the project, whatever else was requested.
if [ "$DELETE_DATA" == "true" ] && [ "$DELETE_SECRETS" == "true" ] && [ "$DELETE_CONFIG" == "true" ] && [ "$KEEP_PROJECT" != "true" ]; then
    
    # -- Pre-deletion cleanup: deregister Telegram webhook --
    if [ "$PROJECT_EXISTS" == "true" ]; then
        log_step "Pre-deletion Cleanup"
        
        # Telegram would otherwise keep calling a deleted project. A failed read of the bot
        # token stops the run before the project is deleted, because nothing could remove
        # the webhook afterwards.
        if ! deregister_telegram_webhook; then
            echo "  The project has not been deleted. Fix the cause above, then run the teardown again."
            exit 1
        fi
    fi
    
    log_step "Deleting GCP Project"
    
    if [ "$PROJECT_EXISTS" == "false" ]; then
        echo "Project already deleted: gcloud answered that it is gone or being deleted."
        PROJECT_DELETED="true"
    else
        # The typed-project-id confirmation was taken before the start callback and the
        # pre-deletion webhook cleanup, because both of those are effects an abort here
        # could not undo. Nothing between that prompt and this line asks the operator
        # anything, so reaching here means it was answered.
        echo ""
        echo "Deleting project $PROJECT_ID..."
        gcloud_probe "Could not delete project $PROJECT_ID via gcloud" gcloud projects delete "$PROJECT_ID" --quiet
        PROJECT_DELETE_PROBE=$?
        if [ "$PROJECT_DELETE_PROBE" -eq 0 ]; then
            log_success "GCP project deleted"
            PROJECT_DELETED="true"
        elif [ "$PROJECT_DELETE_PROBE" -eq 1 ]; then
            echo "Project already deleted."
            PROJECT_DELETED="true"
        else
            # A delete can fail because the project is already DELETE_REQUESTED; only
            # gcloud's answer about the project can say so.
            describe_gcp_project_presence "$PROJECT_ID"
            if [ "$?" -eq 1 ]; then
                echo "Project already deleted."
                PROJECT_DELETED="true"
            else
                log_error "The GCP project $PROJECT_ID was not deleted"
                echo "  Delete it manually, or fix the cause above and run the teardown again:"
                echo "  https://console.cloud.google.com/iam-admin/settings?project=$PROJECT_ID"
                exit 1
            fi
        fi
        # The lease object lived in the project's state bucket and went with it.
        TEARDOWN_LEASE_HELD="false"
    fi

else
    # Partial teardown - use Terraform to selectively destroy resources
    log_step "Running Terraform Destroy (Partial)"
    
    if [ "$PROJECT_EXISTS" == "false" ]; then
        echo "Project doesn't exist - skipping Terraform destroy."
        echo "Resources were likely already deleted."
    else
        resolve_terraform_binary || exit 1
        
        # Initialize Terraform with correct backend config
        echo "Initializing Terraform..."
        TFSTATE_BUCKET="${PROJECT_ID}-tfstate"
        
        # Suspend errexit for this one command and restore WHAT WAS IN FORCE, not a
        # guess at it. These blocks used to end in a bare `set -e`, written as if they
        # were restoring; errexit is never on in this script (see the note at the top),
        # so that turned it on for the whole tail of the run -- and only when this
        # branch had been taken, giving the two teardown paths two different error
        # policies, neither documented.
        TF_INIT_ERREXIT_STATE=$(set +o | grep errexit)
        set +e  # Don't exit on error - handle gracefully
        terraform_cli -chdir="$TERRAFORM_DIR" init \
            -backend-config="bucket=${TFSTATE_BUCKET}" \
            -backend-config="prefix=ai-ingestion" \
            -input=false \
            -reconfigure 2>&1
        TF_INIT_EXIT=$?
        eval "$TF_INIT_ERREXIT_STATE"
        
        if [ $TF_INIT_EXIT -ne 0 ]; then
            log_error "Could not initialize Terraform"
            echo "  No teardown cleanup or checkpoint state was changed."
            exit "$TF_INIT_EXIT"
        else
            renew_teardown_lease || exit 1
            # Build the Terraform arguments as an array so values cannot be
            # re-split by the shell. Telegram-enabled configurations require the
            # same exact numeric secret version as every other Terraform entrypoint.
            TF_VARS=("-var-file=environments/${DOMAIN}.tfvars")

            if [ "$(parse_tfvar "$TFVARS_FILE" "enable_telegram")" = "true" ]; then
                TELEGRAM_WEBHOOK_SECRET_NAME="$(parse_tfvar "$TFVARS_FILE" "secret_name_telegram_webhook")"
                TELEGRAM_WEBHOOK_SECRET_NAME="${TELEGRAM_WEBHOOK_SECRET_NAME:-CORCO_TELEGRAM_WEBHOOK_SECRET}"
                gcloud_probe "Could not list the enabled versions of $TELEGRAM_WEBHOOK_SECRET_NAME in $PROJECT_ID" gcloud secrets versions list "$TELEGRAM_WEBHOOK_SECRET_NAME" --project="$PROJECT_ID" --filter='state=ENABLED' --sort-by='~createTime' --limit=1 --format='value(name)'
                TELEGRAM_WEBHOOK_SECRET_PROBE=$?
                if [ "$TELEGRAM_WEBHOOK_SECRET_PROBE" -eq 1 ]; then
                    gcloud_probe_report "The secret $TELEGRAM_WEBHOOK_SECRET_NAME does not exist in $PROJECT_ID"
                fi
                if [ "$TELEGRAM_WEBHOOK_SECRET_PROBE" -ne 0 ]; then
                    echo "Terraform cannot evaluate this Telegram-enabled configuration safely."
                    exit 1
                fi
                TELEGRAM_WEBHOOK_SECRET_VERSION=$(printf '%s\n' "$GCLOUD_PROBE_OUTPUT" | awk -F/ 'NR == 1 { print $NF }')
                if ! printf '%s\n' "$TELEGRAM_WEBHOOK_SECRET_VERSION" | grep -Eq '^[1-9][0-9]*$'; then
                    log_error "No enabled numeric version of $TELEGRAM_WEBHOOK_SECRET_NAME exists in $PROJECT_ID"
                    echo "Terraform cannot evaluate this Telegram-enabled configuration safely."
                    exit 1
                fi
                TF_VARS+=("-var=telegram_webhook_secret_version=$TELEGRAM_WEBHOOK_SECRET_VERSION")
            fi
            
            if [ "$DELETE_DATA" == "true" ]; then
                echo ""
                echo -e "${RED}⚠️  WARNING: --delete-data specified${NC}"
                echo "   BigQuery deletion protection will be DISABLED"
                echo "   All communications data will be PERMANENTLY DELETED"
                echo ""
                TF_VARS+=("-var=bigquery_deletion_protection=false")
            else
                echo ""
                echo -e "${GREEN}ℹ️  BigQuery data will be PRESERVED${NC}"
                echo "   (Use --delete-data to also delete BigQuery dataset)"
                echo ""
            fi

            PLAN_TEMP_ROOT="${TMPDIR:-/tmp}"
            case "$PLAN_TEMP_ROOT" in
                /*) ;;
                *) PLAN_TEMP_ROOT=/tmp ;;
            esac
            TEARDOWN_RUN_DIR=$(mktemp -d "$PLAN_TEMP_ROOT/corco-teardown.XXXXXXXX") || {
                log_error "Could not create a private Terraform plan directory"
                exit 1
            }
            chmod 700 "$TEARDOWN_RUN_DIR" || {
                log_error "Could not secure the Terraform plan directory"
                exit 1
            }
            DESTROY_PLAN_FILE="$TEARDOWN_RUN_DIR/destroy.tfplan"
            DESTROY_PLAN_CHANGES_FILE="$TEARDOWN_RUN_DIR/destroy.changes.json"

            renew_teardown_lease || exit 1
            echo "Planning destruction..."
            TF_PLAN_ERREXIT_STATE=$(set +o | grep errexit)
            set +e
            if [ "$DELETE_DATA" == "true" ]; then
                # Same target-list mechanism as the safe path below, plus the
                # bigquery module: the dataset is destroyed, and google_project
                # .metadata is simply never in the plan -- the project cannot be
                # deleted by a plan that never contains it.
                #
                # This arm used to apply only when --keep-project was ALSO given;
                # a plain --delete-data fell through to an UNTARGETED
                # `plan -destroy`, which includes the root module and therefore
                # google_project.metadata. Its lifecycle block sets only
                # ignore_changes, which does nothing on destroy, and no
                # prevent_destroy exists anywhere in deployment/ -- so
                # `teardown.sh <domain> --delete-data` planned the deletion of the
                # entire GCP project while the banner above it promised "Secrets
                # (CORCO_*): KEPT" and "Config: KEPT", behind a typed-DOMAIN
                # prompt rather than the typed-project-ID gate (which is reachable
                # only from --all). The setup-landing teardown page recommends
                # exactly that flag for a "full wipe".
                #
                # Terraform now never destroys the project in ANY arm. Deleting a
                # project remains a deliberate, separate act: the --all branch
                # calls `gcloud projects delete` behind its own typed-project-ID
                # confirmation. --keep-project therefore no longer changes what
                # this plan contains, because the unsafe alternative is gone.
                terraform_cli -chdir="$TERRAFORM_DIR" plan -destroy "${TF_VARS[@]}" \
                    -target=module.functions \
                    -target=module.iam \
                    -target=module.scheduler \
                    -target=module.secrets \
                    -target=module.storage \
                    -target=module.monitoring \
                    -target=module.bigquery \
                    -out="$DESTROY_PLAN_FILE" -input=false 2>&1
            else
                terraform_cli -chdir="$TERRAFORM_DIR" plan -destroy "${TF_VARS[@]}" \
                    -target=module.functions \
                    -target=module.iam \
                    -target=module.scheduler \
                    -target=module.secrets \
                    -target=module.storage \
                    -target=module.monitoring \
                    -out="$DESTROY_PLAN_FILE" -input=false 2>&1
            fi
            TF_PLAN_EXIT=$?
            eval "$TF_PLAN_ERREXIT_STATE"
            
            if [ $TF_PLAN_EXIT -ne 0 ]; then
                log_error "Terraform destroy plan failed"
                echo "  No teardown cleanup or checkpoint state was changed."
                exit "$TF_PLAN_EXIT"
            elif [ -f "$DESTROY_PLAN_FILE" ]; then
                chmod 600 "$DESTROY_PLAN_FILE" || {
                    log_error "Could not secure the Terraform destroy plan"
                    exit 1
                }
                DESTROY_PLAN_SHA256=$(sha256_file "$DESTROY_PLAN_FILE") || exit 1
                if ! printf '%s\n' "$DESTROY_PLAN_SHA256" | grep -Eq '^[0-9a-fA-F]{64}$'; then
                    log_error "Could not record a valid SHA-256 for the Terraform destroy plan"
                    exit 1
                fi
                # Only each change's address, type and actions reach disk: the full
                # plan JSON would also hold the prior state's values in clear.
                terraform_cli -chdir="$TERRAFORM_DIR" show -json "$DESTROY_PLAN_FILE" \
                    | jq '{resource_changes: [.resource_changes[]? | {address, type, change: {actions: .change.actions}}]}' \
                    > "$DESTROY_PLAN_CHANGES_FILE"
                DESTROY_PLAN_SHOW_STATUS=("${PIPESTATUS[@]}")
                if [ "${DESTROY_PLAN_SHOW_STATUS[0]}" -ne 0 ] || [ "${DESTROY_PLAN_SHOW_STATUS[1]}" -ne 0 ]; then
                    log_error "Could not read the changes in the Terraform destroy plan"
                    echo "  No teardown cleanup or checkpoint state was changed."
                    exit 1
                fi
                if ! teardown_iam_administrator_gate "$DESTROY_PLAN_CHANGES_FILE"; then
                    echo "  No teardown cleanup or checkpoint state was changed."
                    exit 1
                fi
                echo ""
                if [ "$FORCE" != "true" ]; then
                    if ! prompt_yes_no "Apply the destruction plan?" "n"; then
                        log_error "Teardown cancelled."
                        exit 1
                    fi
                fi
                
                renew_teardown_lease || exit 1
                echo ""
                echo "Destroying resources..."
                if ! verify_destroy_plan_integrity; then
                    echo "  No teardown cleanup or checkpoint state was changed."
                    exit 1
                fi
                # After the last check and before the destroy: the plan removes the
                # Telegram function, and the bot token is read before the destroy can
                # remove a secret that Terraform created.
                if ! deregister_telegram_webhook; then
                    echo "  Terraform has destroyed nothing. Fix the cause above, then run the teardown again."
                    exit 1
                fi
                if terraform_cli -chdir="$TERRAFORM_DIR" apply -input=false "$DESTROY_PLAN_FILE" 2>&1; then
                    TF_APPLY_EXIT=0
                else
                    TF_APPLY_EXIT=$?
                fi

                if [ "$TF_APPLY_EXIT" -ne 0 ]; then
                    log_error "Terraform destroy apply failed"
                    echo "  No subsequent cleanup or checkpoint state was changed."
                    exit "$TF_APPLY_EXIT"
                fi

                if ! commit_partial_teardown_tombstone; then
                    log_error "Terraform teardown succeeded, but its setup-state tombstone did not commit"
                    echo "  No subsequent cleanup or completion notification was performed."
                    exit 1
                fi
                log_success "Terraform destroy complete"
            else
                log_error "Terraform reported a successful plan but created no plan file"
                exit 1
            fi
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Delete Secrets (if --delete-secrets and the project still exists)
# -----------------------------------------------------------------------------
# Every call goes through the probe: a list or a delete that fails for any
# reason but not-found stops the run, so a secret that may still exist is never reported
# as deleted or as absent. The configuration is still in place at this point, so a run
# that stops here can simply be run again.

if [ -z "$PROJECT_ID" ]; then
    SECRETS_OUTCOME="not checked (no project ID)"
elif [ "$PROJECT_EXISTS" == "false" ]; then
    SECRETS_OUTCOME="gone with the project"
    echo "Secrets went with the project, which gcloud answered is gone or being deleted."
elif [ "$PROJECT_DELETED" == "true" ]; then
    SECRETS_OUTCOME="DELETED with the project"
    echo "Secrets deleted with the project."
elif [ "$DELETE_SECRETS" == "true" ]; then
    log_step "Deleting Secrets"

    echo "Finding CORCO_* secrets..."
    if ! gcloud_require "Could not list the CORCO_* secrets in $PROJECT_ID" gcloud secrets list --project="$PROJECT_ID" --filter="name:CORCO" --format="value(name)"; then
        echo "  No secret has been deleted, and every one may still exist. Fix the cause above, then run the teardown again."
        exit 1
    fi
    SECRET_NAMES=$GCLOUD_PROBE_OUTPUT
    SECRETS_LISTED=0
    SECRETS_NOT_DELETED=0
    while IFS= read -r secret <&3; do
        [ -n "$secret" ] || continue
        SECRETS_LISTED=$((SECRETS_LISTED + 1))
        echo "Deleting: $secret"
        gcloud_probe "Could not delete secret $secret; it may still exist" gcloud secrets delete "$secret" --project="$PROJECT_ID" --quiet
        case $? in
            0) ;;
            1) echo "  (already deleted)" ;;
            *) SECRETS_NOT_DELETED=$((SECRETS_NOT_DELETED + 1)) ;;
        esac
    done 3<<< "$SECRET_NAMES"
    if [ "$SECRETS_NOT_DELETED" -gt 0 ]; then
        log_error "Not every CORCO_* secret was deleted; each one named above may still exist"
        echo "  Fix the cause above, then run the teardown again."
        exit 1
    fi
    if [ "$SECRETS_LISTED" -eq 0 ]; then
        echo "No CORCO_* secrets found (already deleted or none existed)"
    else
        log_success "Secrets deleted"
    fi
    SECRETS_OUTCOME="DELETED"
else
    SECRETS_OUTCOME="PRESERVED"
    log_step "Secrets Preserved"
    echo "Existing secrets were NOT deleted. They can be reused on reinstall."
    echo "Use --delete-secrets flag to also delete secrets."
fi

# -----------------------------------------------------------------------------
# Restore Organization Policy (if --restore-org-policy and the project still exists)
# -----------------------------------------------------------------------------

ORG_POLICY_OUTCOME="not requested"
if [ "$PROJECT_DELETED" == "true" ] || [ "$PROJECT_EXISTS" == "false" ]; then
    ORG_POLICY_OUTCOME="gone with the project"
    echo "Org policy went with the project."
elif [ "$RESTORE_ORG_POLICY" == "true" ]; then
    log_step "Restoring Organization Policy"

    echo "Checking current org policy state..."
    gcloud_probe "Could not read the iam.allowedPolicyMemberDomains policy of $PROJECT_ID" gcloud resource-manager org-policies describe iam.allowedPolicyMemberDomains --project="$PROJECT_ID" --format='value(listPolicy.allValues)'
    case $? in
        0) CURRENT_POLICY=$GCLOUD_PROBE_OUTPUT ;;
        1) CURRENT_POLICY="" ;;
        *)
            echo "  The project may still allow allUsers. Fix the cause above, then run the teardown again."
            exit 1
            ;;
    esac

    if [ "$CURRENT_POLICY" == "ALLOW" ]; then
        echo "Project has an exception allowing allUsers. Removing..."
        gcloud_probe "Could not remove the project-level org policy exception; the project may still allow allUsers" gcloud resource-manager org-policies delete iam.allowedPolicyMemberDomains --project="$PROJECT_ID"
        case $? in
            0)
                ORG_POLICY_OUTCOME="REMOVED (allUsers blocked)"
                log_success "Project-level org policy exception removed"
                ;;
            1)
                ORG_POLICY_OUTCOME="already removed"
                echo "Project-level org policy exception already removed"
                ;;
            *)
                echo "  Fix the cause above, then run the teardown again."
                exit 1
                ;;
        esac
    else
        ORG_POLICY_OUTCOME="none found (already clean)"
        echo "No project-level allUsers exception found (already clean)"
    fi
fi

# -----------------------------------------------------------------------------
# Clean up Terraform state bucket (if --delete-config and the project still exists)
# -----------------------------------------------------------------------------

if [ "$PROJECT_DELETED" == "true" ] || [ "$PROJECT_EXISTS" == "false" ]; then
    echo "Terraform state went with the project."
elif [ "$DELETE_CONFIG" == "true" ]; then
    log_step "Cleaning Up Terraform State"

    # Operator access has its own state so the main stack cannot revoke itself during
    # destroy. A partial teardown must preserve that state and its bucket; an
    # independent administrator removes operator access after the main stack is gone.
    TFSTATE_BUCKET="${PROJECT_ID}-tfstate"
    describe_state_bucket_presence "$TFSTATE_BUCKET"
    STATE_BUCKET_PRESENCE=$?
    if [ "$STATE_BUCKET_PRESENCE" -eq 2 ]; then
        echo "  Fix the cause above, then check the bucket with: gcloud storage buckets describe gs://${TFSTATE_BUCKET}"
        exit 1
    elif [ "$STATE_BUCKET_PRESENCE" -eq 0 ]; then
        if ! gcloud_require "Could not authenticate operator-access state check" gcloud auth print-access-token; then
            exit 1
        fi
        OPERATOR_STATE_ACCESS_TOKEN=$GCLOUD_PROBE_OUTPUT
        GCLOUD_PROBE_OUTPUT=""
        OPERATOR_STATE_HTTP_CODE=$(
            {
                printf '%s\n' 'silent' 'show-error'
                printf 'url = "https://storage.googleapis.com/storage/v1/b/%s/o/operator-access%%2Fdefault.tfstate"\n' "$TFSTATE_BUCKET"
                printf 'header = "Authorization: Bearer %s"\n' "$OPERATOR_STATE_ACCESS_TOKEN"
            } | curl -q --config - --output /dev/null --write-out '%{http_code}'
        )
        OPERATOR_STATE_CURL_EXIT=$?
        unset OPERATOR_STATE_ACCESS_TOKEN
        if [ "$OPERATOR_STATE_CURL_EXIT" -ne 0 ]; then
            log_error "Could not query operator-access state"
            exit 1
        fi
        if [ "$OPERATOR_STATE_HTTP_CODE" = "200" ]; then
            log_warning "Preserving Terraform state bucket because operator-access state remains"
            echo "  Destroy operator access last, as an independent administrator."
        elif [ "$OPERATOR_STATE_HTTP_CODE" = "404" ]; then
            echo "Deleting Terraform state bucket: $TFSTATE_BUCKET"
            if ! gsutil -m rm -r "gs://${TFSTATE_BUCKET}/**"; then
                log_error "Could not delete every Terraform state object"
                exit 1
            fi
            if ! gsutil rb "gs://${TFSTATE_BUCKET}"; then
                log_error "Could not delete Terraform state bucket"
                exit 1
            fi
            log_success "Terraform state bucket deleted"
        else
            log_error "Could not determine whether operator-access state remains"
            echo "  Storage API returned HTTP $OPERATOR_STATE_HTTP_CODE"
            exit 1
        fi
    else
        echo "Terraform state bucket not found (already deleted)"
    fi
fi

# -----------------------------------------------------------------------------
# Update Local Registry (if present)
# -----------------------------------------------------------------------------

log_step "Updating Local Registry"

if [ -f "$REGISTRY_FILE" ]; then
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    if [ "$DELETE_CONFIG" == "true" ]; then
        # Full wipe - remove the deployment entry entirely
        REGISTRY_FILTER='del(.deployments[$domain]) | ._updated = $timestamp'
        REGISTRY_CHANGE="$DOMAIN entry removed"
    else
        # Safe teardown - mark as torn down but keep entry
        REGISTRY_FILTER='.deployments[$domain].deployment.torn_down_at = $timestamp | .deployments[$domain].deployment.torn_down_by = $deployer | .deployments[$domain].deployment.status = "torn_down" | .deployments[$domain].teardown = {"completed_at": $timestamp, "delete_data": $delete_data, "delete_secrets": $delete_secrets} | ._updated = $timestamp'
        REGISTRY_CHANGE="$DOMAIN marked as torn down"
    fi
    if jq --arg domain "$DOMAIN" --arg timestamp "$TIMESTAMP" --arg deployer "$DEPLOYER" --argjson delete_data "$DELETE_DATA" --argjson delete_secrets "$DELETE_SECRETS" "$REGISTRY_FILTER" "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp" && mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"; then
        log_success "Local registry updated: $REGISTRY_CHANGE"
    else
        rm -f "${REGISTRY_FILE}.tmp"
        log_error "Could not update the local registry $REGISTRY_FILE"
        exit 1
    fi
else
    log_warning "Local registry file not found - skipping local update"
fi

# -----------------------------------------------------------------------------
# Clean up local configuration (if --delete-config)
# -----------------------------------------------------------------------------
# After every remote step above succeeded, never before: a run that stops early keeps
# the tfvars and the setup state it needs to run again.

STATE_FILE="$HOME/.corco-setup/${DOMAIN}.state"
if [ "$DELETE_CONFIG" == "true" ]; then
    log_step "Deleting Configuration"
    if ! rm -f "$TFVARS_FILE"; then
        log_error "Could not delete $TFVARS_FILE"
        exit 1
    fi
    log_success "Deleted: $TFVARS_FILE"
    if [ -f "$STATE_FILE" ]; then
        if ! rm -f "$STATE_FILE"; then
            log_error "Could not delete the setup state file $STATE_FILE"
            exit 1
        fi
        log_success "Cleared setup state file (--delete-config)"
    fi
    if [ -d "$TERRAFORM_DIR/.terraform" ]; then
        if ! rm -rf "$TERRAFORM_DIR/.terraform"; then
            log_error "Could not clear the local Terraform cache $TERRAFORM_DIR/.terraform"
            exit 1
        fi
        log_success "Cleared local Terraform cache (.terraform/)"
    fi
    if [ -f "$TERRAFORM_DIR/.terraform.lock.hcl" ]; then
        if ! rm -f "$TERRAFORM_DIR/.terraform.lock.hcl"; then
            log_error "Could not clear the Terraform lock file"
            exit 1
        fi
        log_success "Cleared Terraform lock file"
    fi
else
    echo ""
    echo -e "${GREEN}Configuration preserved:${NC} $TFVARS_FILE"
fi

# -----------------------------------------------------------------------------
# Notify Corco: Teardown Completed
# -----------------------------------------------------------------------------
# Last, after every cleanup step above succeeded. A step that fails exits
# before this point, and the EXIT trap tells Corco the teardown failed, and at which step.

TEARDOWN_CURRENT_STEP="Releasing the teardown lease"
if ! release_teardown_lease; then
    log_error "Could not release the teardown lease"
    exit 1
fi

log_step "Notifying Corco: Teardown Completed"

# From here on the teardown has succeeded, so the EXIT trap must not report a failure,
# whatever this callback answers.
TEARDOWN_COMPLETE_SENT="true"
if send_teardown_callback complete "$(printf '"delete_data": %s, "delete_secrets": %s, "timestamp": "%s"' "$DELETE_DATA" "$DELETE_SECRETS" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")")"; then
    log_success "Corco notified of teardown completion"
else
    log_warning "Could not notify Corco of teardown completion"
    echo "  Response: $TEARDOWN_CALLBACK_RESPONSE"
fi

# -----------------------------------------------------------------------------
# Manual Steps
# -----------------------------------------------------------------------------

log_step "MANUAL STEPS REQUIRED"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                    DOMAIN-WIDE DELEGATION CLEANUP                        ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  The service account's Domain-Wide Delegation entry must be removed manually:"
echo ""
echo "  1. Open: https://admin.google.com/ac/owl/domainwidedelegation"
echo "  2. Find the entry for: gmail-sync-sa@${PROJECT_ID}.iam.gserviceaccount.com"
echo "  3. Click the trash icon to delete it"
echo ""
echo "  (If you're reinstalling, you'll need to re-add this during setup)"
echo ""

if [ "$DELETE_SECRETS" == "true" ]; then
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                    EXTERNAL SERVICE CLEANUP                              ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Consider cleaning up these external services:"
    echo ""
    echo "  • Telegram: Delete the bot via @BotFather → /deletebot"
    echo "  • Twilio: Remove/reconfigure phone numbers if dedicated to this deployment"
    echo "  • OpenAI: Revoke the API key at platform.openai.com/api-keys"
    echo ""
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

log_step "Teardown Complete"

# Each line reports what this run did, not what its flags asked for: a project that was
# already gone deleted nothing here, and nothing is "preserved" in a project that no
# longer exists.
print_summary_line() {
    case "$2" in
        DELETED*|REMOVED*) echo -e "  - $1: ${RED}$2${NC}" ;;
        PRESERVED*) echo -e "  - $1: ${GREEN}$2${NC}" ;;
        *) echo "  - $1: $2" ;;
    esac
}

if [ -z "$PROJECT_ID" ]; then
    INFRASTRUCTURE_OUTCOME="not checked (no project ID)"
    DATA_OUTCOME="not checked (no project ID)"
elif [ "$PROJECT_EXISTS" == "false" ]; then
    INFRASTRUCTURE_OUTCOME="gone with the project"
    DATA_OUTCOME="gone with the project"
elif [ "$PROJECT_DELETED" == "true" ]; then
    INFRASTRUCTURE_OUTCOME="DELETED with the project"
    DATA_OUTCOME="DELETED with the project"
else
    INFRASTRUCTURE_OUTCOME="DELETED"
    if [ "$DELETE_DATA" == "true" ]; then
        DATA_OUTCOME="DELETED"
    else
        DATA_OUTCOME="PRESERVED"
    fi
fi
if [ "$DELETE_CONFIG" == "true" ]; then
    CONFIG_OUTCOME="DELETED"
else
    CONFIG_OUTCOME="PRESERVED"
fi

echo ""
echo "Domain:  $DOMAIN"
echo "Project: $PROJECT_ID"
echo ""
echo "Summary:"
print_summary_line "Infrastructure" "$INFRASTRUCTURE_OUTCOME"
print_summary_line "BigQuery data" "$DATA_OUTCOME"
print_summary_line "Secrets" "$SECRETS_OUTCOME"
print_summary_line "Configuration" "$CONFIG_OUTCOME"
if [ "$RESTORE_ORG_POLICY" == "true" ]; then
    print_summary_line "Org policy exception" "$ORG_POLICY_OUTCOME"
fi
echo ""

# The reinstall and wipe commands below are ones the operator can paste where they ran
# this, so each is built from this file's own place, as PLATFORM_ROOT is at the top:
#   - in deployment/scripts/, setup.sh beside this file is the installer. It takes
#     --domain, and it finds its tree from its own path, so it runs from any directory;
#   - anywhere else, setup.sh beside this file is the corco-installer bootstrap. It takes
#     no --domain, because the setup token names the domain, and it unpacks the release
#     into the directory it runs from, so it runs only from this file's directory.
# --resume is offered only while the setup state it resumes from is still on disk, so
# never after --delete-config. Either setup.sh asks for the setup token itself.

# operator_path FILE: FILE as the operator types it from INVOCATION_DIR, quoted for the shell.
operator_path() {
    local directory
    local file
    directory="$(cd "$(dirname "$1")" && pwd -P)" || return 1
    file="$directory/$(basename "$1")"
    case "$file" in
        "$INVOCATION_DIR"/*) printf './%q' "${file#"$INVOCATION_DIR"/}" ;;
        *) printf '%q' "$file" ;;
    esac
}

# reinstall_command RESUME: the setup command for the layout this file runs in, with
# --resume when RESUME is true. It fails when no setup.sh sits beside this file.
reinstall_command() {
    local resume_flag=""
    local bootstrap_dir
    if [ "$1" = "true" ]; then
        resume_flag=" --resume"
    fi
    [ -f "$SCRIPT_DIR/setup.sh" ] || return 1
    case "$SCRIPT_DIR" in
        */deployment/scripts)
            printf '%s --domain=%q%s' "$(operator_path "$SCRIPT_DIR/setup.sh")" "$DOMAIN" "$resume_flag"
            ;;
        *)
            bootstrap_dir="$(cd "$SCRIPT_DIR" && pwd -P)" || return 1
            if [ "$bootstrap_dir" = "$INVOCATION_DIR" ]; then
                printf './setup.sh%s' "$resume_flag"
            else
                printf 'cd %q && ./setup.sh%s' "$bootstrap_dir" "$resume_flag"
            fi
            ;;
    esac
}

# print_reinstall_step RESUME NOTE: step 2 of the reinstall instructions.
print_reinstall_step() {
    local command
    if command="$(reinstall_command "$1")"; then
        echo "  2. Run: $command"
        echo "     $2"
    else
        echo "  2. Open your setup link and run setup again: no setup.sh sits beside this teardown.sh"
    fi
}

SETUP_STATE_SURVIVES=false
if [ "$DELETE_CONFIG" != "true" ] && [ -f "$STATE_FILE" ]; then
    SETUP_STATE_SURVIVES=true
fi

PRESERVED_ITEMS=""
for preserved in "data:$DATA_OUTCOME" "secrets:$SECRETS_OUTCOME" "configuration:$CONFIG_OUTCOME"; do
    case "${preserved#*:}" in
        PRESERVED*) PRESERVED_ITEMS="${PRESERVED_ITEMS:+$PRESERVED_ITEMS, }${preserved%%:*}" ;;
    esac
done

if [ "$DELETE_DATA" == "true" ] && [ "$DELETE_SECRETS" == "true" ] && [ "$DELETE_CONFIG" == "true" ]; then
    echo -e "${GREEN}Full cleanup complete.${NC} The project is ready for a fresh install."
    echo ""
    echo "Everything removed:"
    echo "  - GCP resources (functions, schedulers, buckets, etc.)"
    echo "  - BigQuery dataset and all data"
    echo "  - All CORCO_* secrets"
    echo "  - Terraform state (local and GCS)"
    echo "  - Configuration files (tfvars)"
    echo "  - Setup state (resume data)"
    echo ""
    echo "To reinstall from scratch:"
    echo "  1. Complete manual DWD cleanup (see above)"
    print_reinstall_step false "Use a new setup token when setup.sh asks for one."
else
    if [ -n "$PRESERVED_ITEMS" ]; then
        echo -e "${GREEN}Safe teardown complete.${NC} Preserved for reinstall: $PRESERVED_ITEMS."
    else
        echo -e "${GREEN}Teardown complete.${NC} Nothing was preserved for reinstall."
    fi
    echo ""
    echo "To reinstall:"
    echo "  1. Complete manual DWD cleanup (see above)"
    print_reinstall_step "$SETUP_STATE_SURVIVES" "setup.sh asks for your setup token."
    echo ""
    echo "To fully wipe later:"
    echo "  $(operator_path "$TEARDOWN_SCRIPT") $(printf '%q' "$DOMAIN") --all"
fi
echo ""
