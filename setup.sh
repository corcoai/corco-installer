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

# Parse arguments (if provided)
TOKEN=""
for i in "$@"; do
case $i in
    --token=*)
    TOKEN="${i#*=}"
    ;;
    *)
    ;;
esac
done

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
echo -e "${BLUE}• Extracting files...${NC}"
rm -rf corco-installer 2>/dev/null || true
mkdir -p corco-installer
tar -xzf corco-installer.tar.gz -C corco-installer

if [ ! -f corco-installer/deployment/scripts/setup.sh ]; then
    echo -e "${RED}Error: Invalid package structure.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Extracted${NC}"
echo ""

# 6. Run Real Setup
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Launching main installer...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

cd corco-installer/deployment/scripts
chmod +x setup.sh

# Pass token and extracted data to real setup
./setup.sh --token="$TOKEN" --domain="$DOMAIN" --consultant="$CONSULTANT"
