#!/bin/bash
# ============================================================================
# Corco Utterances - Setup Bootstrap
# ============================================================================
# This script runs in the public corco-installer repo:
# github.com/corcoai/corco-installer. It downloads the secure source package
# and launches the real installer.
#
# Because it executes what it downloads, it verifies the package against the
# SHA-256 the setup service publishes before extracting anything. A missing or
# mismatched checksum aborts the install. That makes the deployment order
# mandatory: the setup-landing function must be serving checksums, and a
# release built by corco-release must be in gs://corco-prod-dist, BEFORE this file
# is pushed here -- clients pull it live from the default branch.
# ============================================================================

set -euo pipefail

# Configuration
SETUP_SERVICE_URL="https://setup.corco.ai"

# Extract a JSON string field. Prints nothing when the key is absent or its
# value is null, so each caller decides whether that is fatal.
json_string_field() {
    printf '%s' "$1" \
        | grep -m1 -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | sed "s/.*:[[:space:]]*\"//;s/\"\$//"
}

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BOLD='\033[1m'

clear

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                                                                          ║${NC}"
echo -e "${CYAN}║   ${BOLD}CORCO UTTERANCES${NC}${CYAN}                                                      ║${NC}"
echo -e "${CYAN}║   AI Communications Platform Setup                                       ║${NC}"
echo -e "${CYAN}║                                                                          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Parse only the public bootstrap's interface. Saved-answer mode is forwarded to
# the verified installer from the downloaded package; arbitrary arguments are not.
parse_bootstrap_arguments() {
    TOKEN=""
    FORWARD_SETUP_ARGUMENTS=()
    for argument in "$@"; do
        case $argument in
            --token=*) TOKEN="${argument#*=}" ;;
            --resume|--reuse-saved|--upgrade|--bootstrap-operator-access)
                FORWARD_SETUP_ARGUMENTS+=("$argument")
                ;;
            --approve-destructive-plan=*) FORWARD_SETUP_ARGUMENTS+=("$argument") ;;
            --allow-destructive-plan=*)
                FORWARD_SETUP_ARGUMENTS+=("--approve-destructive-plan=${argument#*=}")
                ;;
            --telegram-webhook-cutover-from=*)
                cutover_url=${argument#*=}
                if ! printf '%s' "$cutover_url" | grep -Eq '^https://[^[:space:]]+$'; then
                    echo -e "${RED}Error: Telegram webhook cutover source must be a complete HTTPS URL.${NC}" >&2
                    return 1
                fi
                FORWARD_SETUP_ARGUMENTS+=("$argument")
                ;;
            --telegram-webhook-cutover-from)
                echo -e "${RED}Error: --telegram-webhook-cutover-from requires the exact current HTTPS URL.${NC}" >&2
                return 1
                ;;
            *)
                echo -e "${RED}Error: unknown bootstrap argument: $argument${NC}" >&2
                return 1
                ;;
        esac
    done
}

launch_main_setup() {
    local setup_script=$1
    local setup_arguments=(
        --token="$TOKEN"
        --domain="$DOMAIN"
        --consultant="$CONSULTANT"
    )
    local forwarded
    if [ "${#FORWARD_SETUP_ARGUMENTS[@]}" -gt 0 ]; then
        for forwarded in "${FORWARD_SETUP_ARGUMENTS[@]}"; do
            case "$forwarded" in
                --approve-destructive-plan=*|--allow-destructive-plan=*)
                    grep -Fq -- '--approve-destructive-plan=' "$setup_script" || {
                        echo -e "${RED}Error: downloaded release ${RELEASE_VERSION:-unknown} does not support destructive-plan hashes.${NC}"
                        return 1
                    }
                    ;;
                --telegram-webhook-cutover-from=*)
                    grep -Fq -- '--telegram-webhook-cutover-from=*' "$setup_script" || {
                        echo -e "${RED}Error: downloaded release ${RELEASE_VERSION:-unknown} does not support Telegram webhook cutover gates.${NC}"
                        return 1
                    }
                    ;;
                *)
                    grep -Eq "^[[:space:]]*${forwarded}\\)" "$setup_script" || {
                        echo -e "${RED}Error: downloaded release ${RELEASE_VERSION:-unknown} does not support ${forwarded}.${NC}"
                        return 1
                    }
                    ;;
            esac
        done
        setup_arguments+=("${FORWARD_SETUP_ARGUMENTS[@]}")
    fi
    "$setup_script" "${setup_arguments[@]}"
}

parse_bootstrap_arguments "$@"

# If no token provided, prompt for it
if [ -z "$TOKEN" ]; then
    echo -e "${YELLOW}Please enter your setup token.${NC}"
    echo -e "You can find this on your setup page at ${CYAN}setup.corco.ai${NC}"
    echo ""
    read -r -p "Setup Token: " TOKEN
    echo ""
fi

if [ -z "$TOKEN" ]; then
    echo -e "${RED}Error: Setup token is required.${NC}"
    exit 1
fi

echo -e "${BLUE}• Authenticating with setup service...${NC}"

# 1. Get Signed URL for Source Code
RESPONSE=$(curl -fsS -X GET "${SETUP_SERVICE_URL}/api/download/${TOKEN}" || true)
DOWNLOAD_URL=$(json_string_field "$RESPONSE" download_url || true)
# The identity of what we are about to install, published alongside the URL.
EXPECTED_SHA256=$(json_string_field "$RESPONSE" sha256 || true)
RELEASE_VERSION=$(json_string_field "$RESPONSE" version || true)

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    echo -e "${RED}Error: Invalid or expired token.${NC}"
    echo ""
    echo "Please check:"
    echo "  • You copied the complete token"
    echo "  • Your setup link hasn't expired"
    echo "  • You haven't already completed setup"
    echo ""
    echo "Contact support@corco.ai if you need a new setup link."
    exit 1
fi

echo -e "${GREEN}✓ Token verified${NC}"
echo ""

# 2. Get client data for pre-population
echo -e "${BLUE}• Fetching configuration...${NC}"
CLIENT_RESPONSE=$(curl -fsS -X GET "${SETUP_SERVICE_URL}/api/client/${TOKEN}" || true)
DOMAIN=$(json_string_field "$CLIENT_RESPONSE" domain || true)
COMPANY=$(json_string_field "$CLIENT_RESPONSE" company_name || true)
CONSULTANT=$(json_string_field "$CLIENT_RESPONSE" consultant_email || true)
# This client's own terraform variables, base64 of the whole file in one JSON
# string. It arrives here and not in the release archive because the archive is
# identical for every client: shipping deployment/terraform/environments/ in it
# handed each client every other client's gcp_project_id, admin email, Drive
# folder and Twilio caller id. This endpoint is already token-scoped and already
# authorizes server-side, so there is no object path to enumerate and no
# per-client bucket ACL to get wrong.
#
# Base64 of the file rather than a field per variable: the tfvars has some
# twenty-five keys that deployment/scripts/setup.sh derives together, and a
# second derivation of them here would drift from that one. Empty is the normal
# case -- a first-time client has no stored tfvars, and the installer generates
# one from the answers it collects.
CLIENT_TFVARS_B64=$(json_string_field "$CLIENT_RESPONSE" tfvars_base64 || true)

if [ -n "$DOMAIN" ]; then
    echo -e "${GREEN}✓ Setting up for: ${BOLD}${COMPANY}${NC} ${GREEN}(${DOMAIN})${NC}"
else
    echo -e "${YELLOW}⚠ Could not fetch client details, continuing anyway...${NC}"
fi
echo ""

# 3. Download Source Code
if [ -n "$RELEASE_VERSION" ]; then
    echo -e "${BLUE}• Downloading installer package (version ${RELEASE_VERSION})...${NC}"
else
    echo -e "${BLUE}• Downloading installer package...${NC}"
fi
rm -f corco-installer.tar.gz
# -f so an HTTP error page is never written to the file and then unpacked;
# --proto '=https' so a tampered response cannot downgrade the transport.
if ! curl -fsS --proto '=https' -o corco-installer.tar.gz "$DOWNLOAD_URL"; then
    echo -e "${RED}Error: Download failed.${NC}"
    exit 1
fi

if [ ! -s corco-installer.tar.gz ]; then
    echo -e "${RED}Error: Download failed (empty package).${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Downloaded${NC}"

# 4. Verify integrity before anything is unpacked or executed
# Everything past this point runs code out of the tarball, so this is the last
# moment a substituted artifact can be stopped. A missing checksum is fatal on
# purpose: skipping the check when none is published would leave a verification
# step that verifies nothing.
echo -e "${BLUE}• Verifying package integrity...${NC}"

if [ -z "$EXPECTED_SHA256" ]; then
    echo -e "${RED}Error: the setup service published no checksum for this package.${NC}"
    echo ""
    echo "The installer will not extract an unverified package."
    echo "Contact support@corco.ai and quote 'missing release checksum'."
    rm -f corco-installer.tar.gz
    exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SHA256=$(sha256sum corco-installer.tar.gz | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL_SHA256=$(shasum -a 256 corco-installer.tar.gz | awk '{print $1}')
else
    echo -e "${RED}Error: no SHA-256 tool available, so the package cannot be verified.${NC}"
    rm -f corco-installer.tar.gz
    exit 1
fi

if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo -e "${RED}Error: package checksum mismatch. Refusing to continue.${NC}"
    echo ""
    echo "  expected: ${EXPECTED_SHA256}"
    echo "  actual:   ${ACTUAL_SHA256}"
    echo ""
    echo "The downloaded package is not the one the setup service published."
    echo "Do not retry blindly - contact support@corco.ai."
    rm -f corco-installer.tar.gz
    exit 1
fi

echo -e "${GREEN}✓ Integrity verified (sha256 ${ACTUAL_SHA256})${NC}"
echo ""

# 5. Extract
#
# The archive carries no environments/ and no taxonomies/approved/: it is one
# artifact for every client, so it can carry no client's own data. That makes the
# rm -rf below destructive in a way it was not before -- it used to wipe those two
# directories and the archive put them straight back. So this tenant's own copies
# are carried across the wipe and restored afterwards. Only this tenant's: the
# taxonomy is taken by name, so a stale folder belonging to some other domain is
# not carried forward.
#
# This is what makes the exclusion safe to ship before the setup service learns to
# return a stored tfvars. An upgrade keeps the file it already had, including hand
# edits the installer cannot re-derive.
echo -e "${BLUE}• Extracting files...${NC}"

PRESERVE_DIR=""
if [ -d corco-installer/deployment ]; then
    PRESERVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/corco-preserve.XXXXXX")"
    chmod 700 "$PRESERVE_DIR"
    if [ -d corco-installer/deployment/terraform/environments ]; then
        cp -R corco-installer/deployment/terraform/environments "$PRESERVE_DIR/environments"
    fi
    if [ -n "$DOMAIN" ] && [ -d "corco-installer/deployment/taxonomies/approved/${DOMAIN}" ]; then
        mkdir -p "$PRESERVE_DIR/approved"
        cp -R "corco-installer/deployment/taxonomies/approved/${DOMAIN}" "$PRESERVE_DIR/approved/${DOMAIN}"
    fi
fi

rm -rf corco-installer 2>/dev/null || true
mkdir -p corco-installer
tar -xzf corco-installer.tar.gz -C corco-installer

if [ -n "$PRESERVE_DIR" ]; then
    if [ -d "$PRESERVE_DIR/environments" ]; then
        mkdir -p corco-installer/deployment/terraform
        cp -R "$PRESERVE_DIR/environments" corco-installer/deployment/terraform/environments
        echo -e "${GREEN}✓ Kept the existing deployment configuration${NC}"
    fi
    if [ -d "$PRESERVE_DIR/approved/${DOMAIN}" ]; then
        mkdir -p corco-installer/deployment/taxonomies/approved
        cp -R "$PRESERVE_DIR/approved/${DOMAIN}" "corco-installer/deployment/taxonomies/approved/${DOMAIN}"
        echo -e "${GREEN}✓ Kept the existing topic taxonomy${NC}"
    fi
    rm -rf "$PRESERVE_DIR"
fi

if [ ! -f corco-installer/deployment/scripts/setup.sh ]; then
    echo -e "${RED}Error: Invalid package structure.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Extracted${NC}"
echo ""

# 5b. Place this client's terraform variables
# The archive deliberately carries no environments/ directory (it is one archive
# for every client, so it can carry no client's configuration). Two paths lead
# out of that, and only one of them writes a file here:
#
#   - First install: the setup service has no stored tfvars for this client, so
#     nothing is written and deployment/scripts/setup.sh generates
#     environments/<domain>.tfvars from the answers it collects. This is the
#     normal path and it is unchanged.
#   - Re-install or upgrade over a live deployment: the stored tfvars is the
#     only record of decisions that installer cannot re-derive -- the bucket
#     prefix the live Eventarc trigger filters on, the tuned scheduler cadences,
#     whether AI enrichment was turned on. It is restored here, before the
#     installer runs, because the installer treats an existing file as
#     authoritative and never overwrites it.
#
# A partial file is worse than no file for exactly that reason, so this writes
# the service's file verbatim or writes nothing at all.
place_client_tfvars() {
    [ -n "$CLIENT_TFVARS_B64" ] || return 0

    # A file preserved across the extraction wins over anything the service sends.
    # The installer treats an existing tfvars as final and never regenerates it, so
    # editing that file is the supported way to change a deployment -- which makes
    # the copy on this machine the only place a hand edit can live. The service's
    # copy is the fallback for a client with no local file, not a newer truth.
    if [ -n "$DOMAIN" ] && [ -f "corco-installer/deployment/terraform/environments/${DOMAIN}.tfvars" ]; then
        return 0
    fi

    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Error: the setup service sent terraform variables but no domain.${NC}" >&2
        echo "Refusing to guess which deployment they describe. Contact support@corco.ai." >&2
        return 1
    fi

    local decoded
    if decoded=$(printf '%s' "$CLIENT_TFVARS_B64" | base64 -d 2>/dev/null); then
        :
    elif decoded=$(printf '%s' "$CLIENT_TFVARS_B64" | base64 -D 2>/dev/null); then
        :
    elif decoded=$(printf '%s' "$CLIENT_TFVARS_B64" | openssl base64 -d -A 2>/dev/null); then
        :
    else
        echo -e "${RED}Error: could not decode the configuration the setup service sent.${NC}" >&2
        echo "Do not continue with a partial configuration - contact support@corco.ai." >&2
        return 1
    fi

    # Two assertions, because a file that is not this tenant's, or not complete,
    # would be applied as though it were: the installer does not re-check it.
    if ! printf '%s' "$decoded" | grep -Eq '^[[:space:]]*gcp_project_id[[:space:]]*='; then
        echo -e "${RED}Error: the configuration sent for ${DOMAIN} names no GCP project.${NC}" >&2
        echo "Contact support@corco.ai and quote 'incomplete tfvars'." >&2
        return 1
    fi
    if ! printf '%s' "$decoded" | grep -Eq "^[[:space:]]*workspace_domain[[:space:]]*=[[:space:]]*\"${DOMAIN}\"[[:space:]]*$"; then
        echo -e "${RED}Error: the configuration sent does not belong to ${DOMAIN}.${NC}" >&2
        echo "Contact support@corco.ai and quote 'tfvars domain mismatch'." >&2
        return 1
    fi

    local environments_dir="corco-installer/deployment/terraform/environments"
    mkdir -p "$environments_dir"
    chmod 700 "$environments_dir"
    # Owner-only from the moment it exists: it names this deployment's project,
    # administrator and telephony identity.
    ( umask 077 && printf '%s\n' "$decoded" > "${environments_dir}/${DOMAIN}.tfvars" )
    chmod 600 "${environments_dir}/${DOMAIN}.tfvars"
    echo -e "${GREEN}✓ Restored existing configuration for ${DOMAIN}${NC}"
    echo ""
}

place_client_tfvars

# 6. Run Real Setup
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Launching main installer...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

cd corco-installer/deployment/scripts
chmod +x setup.sh

# Pass token, extracted data and the explicitly supported mode to the real setup.
launch_main_setup ./setup.sh
