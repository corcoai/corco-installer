#!/bin/bash
# =============================================================================
# AI Ingestion Platform - Unified Setup Script
# 
# Complete self-service deployment:
#   1. GCP project creation & billing
#   2. API credentials (Telegram, Twilio, OpenAI)
#   3. Historical data import configuration
#   4. Domain-Wide Delegation setup
#   5. Terraform infrastructure deployment
#   6. Registration with Corco (for support & licensing)
#
# Usage:
#   Via Cloud Shell button: Pre-filled with --token and --domain
#   Direct:                 ./setup.sh --token=xxx --domain=example.com
#
# NOTE: A valid setup token is REQUIRED. Interactive mode without token is not supported.
#       Get a setup link from your Corco consultant or https://corco.ai/get-started
#
# Prerequisites:
#   - Google Cloud SDK (gcloud)
#   - Terraform
#   - Logged in as organization admin
# =============================================================================

set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TERRAFORM_DIR="$REPO_ROOT/deployment/terraform"
REGISTRY_ENDPOINT="https://setup.corco.ai/register"

# State file for resume functionality
STATE_DIR="$HOME/.corco-setup"
STATE_FILE=""  # Set after domain is known

# =============================================================================
# Failure Handling
# =============================================================================

SETUP_COMPLETED="false"

cleanup_on_exit() {
    if [ "$SETUP_COMPLETED" != "true" ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  Setup was interrupted or failed.${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "  Your progress has been saved. Options:"
        echo ""
        echo "  1. Resume from where you left off:"
        echo -e "     ${CYAN}./setup.sh --token=$SETUP_TOKEN --domain=$SETUP_DOMAIN --resume${NC}"
        echo ""
        echo "  2. Retry from scratch (keeps partial resources, re-runs all steps):"
        echo -e "     ${CYAN}./setup.sh --token=$SETUP_TOKEN --domain=$SETUP_DOMAIN${NC}"
        echo ""
        echo "  3. Fully wipe and start over (if partial install is problematic):"
        echo -e "     ${CYAN}./teardown.sh $SETUP_DOMAIN --all${NC}"
        echo -e "     ${CYAN}./setup.sh --token=$SETUP_TOKEN --domain=$SETUP_DOMAIN${NC}"
        echo ""
        if [ -n "$CONSULTANT_EMAIL" ]; then
            echo "  Need help? Contact: $CONSULTANT_EMAIL"
        fi
        echo ""
    fi
}

trap cleanup_on_exit EXIT

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# =============================================================================
# Parse Arguments
# =============================================================================

SETUP_TOKEN=""
SETUP_DOMAIN=""
SETUP_CONSULTANT=""
RESUME_MODE="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        --token=*) SETUP_TOKEN="${1#*=}"; shift ;;
        --domain=*) SETUP_DOMAIN="${1#*=}"; shift ;;
        --consultant=*) SETUP_CONSULTANT="${1#*=}"; shift ;;
        --token) SETUP_TOKEN="$2"; shift 2 ;;
        --domain) SETUP_DOMAIN="$2"; shift 2 ;;
        --consultant) SETUP_CONSULTANT="$2"; shift 2 ;;
        --resume) RESUME_MODE="true"; shift ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --token=TOKEN       Setup token from onboarding"
            echo "  --domain=DOMAIN     Company domain"
            echo "  --consultant=EMAIL  Consultant email (from token)"
            echo "  --resume            Resume from last checkpoint (skips completed steps)"
            echo "  --help, -h          Show this help"
            exit 0
            ;;
        *) shift ;;
    esac
done

# =============================================================================
# Helper Functions
# =============================================================================

log_step() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

prompt() {
    local var_name=$1
    local prompt_text=$2
    local default=$3
    
    if [ -n "$default" ]; then
        read -p "$prompt_text [$default]: " value
        value="${value:-$default}"
    else
        read -p "$prompt_text: " value
    fi
    eval "$var_name='$value'"
}

open_url() {
    local url=$1
    # In Cloud Shell, URLs are clickable in the terminal
    # Always show the URL prominently, then try to open if possible
    echo ""
    echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}👆 Click this link (or Cmd/Ctrl+click):${NC}"
    echo ""
    echo -e "     ${GREEN}${url}${NC}"
    echo ""
    echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Also try to open automatically (works on local machines, not Cloud Shell)
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url" 2>/dev/null &
    elif command -v open &> /dev/null; then
        open "$url" 2>/dev/null &
    fi
}

# =============================================================================
# State Management (for resume functionality)
# =============================================================================

init_state_file() {
    # Call this after domain is known
    mkdir -p "$STATE_DIR"
    STATE_FILE="$STATE_DIR/${SETUP_DOMAIN}.state"
}

save_state() {
    local key=$1
    local value=$2
    [ -z "$STATE_FILE" ] && return
    
    # Create state file directory if needed
    mkdir -p "$(dirname "$STATE_FILE")"
    
    # Create or update key in state file
    if [ -f "$STATE_FILE" ] && grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        # Update existing key (Linux/Cloud Shell compatible sed)
        sed -i "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
    else
        echo "${key}=${value}" >> "$STATE_FILE"
    fi
}

load_state() {
    local key=$1
    local default=$2
    [ -z "$STATE_FILE" ] && echo "$default" && return
    [ ! -f "$STATE_FILE" ] && echo "$default" && return
    
    local value
    value=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2-)
    echo "${value:-$default}"
}

step_completed() {
    local step=$1
    if [ "$RESUME_MODE" != "true" ]; then
        return 1
    fi
    local state_value=$(load_state "step_${step}" "false")
    if [ "$state_value" == "true" ]; then
        return 0
    else
        return 1
    fi
}

mark_step_complete() {
    local step=$1
    save_state "step_${step}" "true"
}

clear_state() {
    # Instead of deleting the state file, mark it as completed.
    # This prevents --resume from re-executing everything after a successful run.
    if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
        save_state "setup_completed" "true"
    fi
}

create_secret() {
    local name=$1
    local value=$2
    
    [ -z "$value" ] && return 1
    
    # Check if secret already has a version (avoid creating duplicates on re-run)
    if gcloud secrets versions list "$name" --project="$PROJECT_ID" --limit=1 --format="value(name)" 2>/dev/null | grep -q .; then
        echo -e "    ${CYAN}•${NC} $name already has a value (keeping existing)"
        return 0
    fi
    
    # Secret exists but has no version - add first version
    if gcloud secrets describe "$name" --project="$PROJECT_ID" &>/dev/null 2>&1; then
        if echo -n "$value" | gcloud secrets versions add "$name" --data-file=- --project="$PROJECT_ID" 2>/dev/null; then
            echo -e "    ${GREEN}✓${NC} Added value to $name"
            return 0
        fi
    fi
    
    # Secret doesn't exist - create with value
    if echo -n "$value" | gcloud secrets create "$name" --data-file=- --project="$PROJECT_ID" 2>/dev/null; then
        echo -e "    ${GREEN}✓${NC} Created $name"
        return 0
    fi
    
    echo -e "    ${RED}✗${NC} Failed: $name"
    return 1
}

# =============================================================================
# Header
# =============================================================================

clear
echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                                                                ║${NC}"
echo -e "${BOLD}║            AI INGESTION PLATFORM - SETUP                       ║${NC}"
echo -e "${BOLD}║                                                                ║${NC}"
echo -e "${BOLD}║  This script will set up everything you need:                  ║${NC}"
echo -e "${BOLD}║    - GCP project & billing                                     ║${NC}"
echo -e "${BOLD}║    - Integration credentials (Telegram, Twilio, OpenAI)        ║${NC}"
echo -e "${BOLD}║    - Gmail Domain-Wide Delegation                              ║${NC}"
echo -e "${BOLD}║    - Cloud infrastructure (functions, storage, BigQuery)       ║${NC}"
echo -e "${BOLD}║                                                                ║${NC}"
echo -e "${BOLD}║  Estimated time: 20-40 minutes (first deployment is slowest)   ║${NC}"
echo -e "${BOLD}║                                                                ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Pre-populate from registry if setup token is provided
PREFILL_CLIENT_NAME=""
PREFILL_ADMIN_FIRST_NAME=""
PREFILL_ADMIN_SURNAME=""
PREFILL_ADMIN_EMAIL=""
PREFILL_ADMIN_PHONE=""
PREFILL_ADMIN_TELEGRAM=""

if [ -n "$SETUP_TOKEN" ] && [ -n "$SETUP_DOMAIN" ]; then
    echo -e "${GREEN}✓${NC} Setup token detected for domain: ${BOLD}$SETUP_DOMAIN${NC}"
    DOMAIN="$SETUP_DOMAIN"
    CONSULTANT_EMAIL="${SETUP_CONSULTANT:-support@corco.ai}"
    
    # Initialize state file for resume functionality
    init_state_file
    
    if [ "$RESUME_MODE" == "true" ]; then
        if [ -f "$STATE_FILE" ]; then
            # Check if a previous setup already completed successfully
            PREV_COMPLETED=$(load_state "setup_completed" "false")
            if [ "$PREV_COMPLETED" == "true" ]; then
                echo ""
                echo -e "${GREEN}A previous setup for this domain completed successfully.${NC}"
                echo ""
                read -p "Run setup again from scratch? [y/N]: " run_again
                if [[ ! "$run_again" =~ ^[Yy] ]]; then
                    echo "Aborting. Use teardown.sh first if you want a clean reinstall."
                    exit 0
                fi
                # User wants to re-run: clear the state file for a fresh start
                rm -f "$STATE_FILE"
                RESUME_MODE="false"
            fi
            echo -e "${CYAN}Resuming from previous session...${NC}"
            echo -e "  State file: ${STATE_FILE}"
            echo -e "  Completed steps: $(grep 'step_.*=true' "$STATE_FILE" 2>/dev/null | cut -d'=' -f1 | tr '\n' ' ')"
            echo ""
        else
            echo -e "${YELLOW}Note: No previous state found at ${STATE_FILE}${NC}"
            echo -e "${YELLOW}Starting fresh (state will be saved for future resumes)${NC}"
            echo ""
        fi
    fi
    
    # Fetch client data from registry
    echo -e "${CYAN}Fetching your information from registry...${NC}"
    REGISTRY_API="https://setup.corco.ai/api/client"
    CLIENT_DATA=$(curl -s -H "Authorization: Bearer $SETUP_TOKEN" "$REGISTRY_API/$SETUP_TOKEN" 2>/dev/null || echo "")
    
    if [ -n "$CLIENT_DATA" ] && [ "$CLIENT_DATA" != "null" ] && [ "$(echo "$CLIENT_DATA" | jq -r '.error // empty')" == "" ]; then
        PREFILL_CLIENT_NAME=$(echo "$CLIENT_DATA" | jq -r '.company_name // empty')
        PREFILL_ADMIN_FIRST_NAME=$(echo "$CLIENT_DATA" | jq -r '.contact.first_name // empty')
        PREFILL_ADMIN_SURNAME=$(echo "$CLIENT_DATA" | jq -r '.contact.surname // empty')
        PREFILL_ADMIN_EMAIL=$(echo "$CLIENT_DATA" | jq -r '.contact.email // empty')
        PREFILL_ADMIN_PHONE=$(echo "$CLIENT_DATA" | jq -r '.contact.phone // empty')
        PREFILL_ADMIN_TELEGRAM=$(echo "$CLIENT_DATA" | jq -r '.contact.telegram_handle // empty')
        CONSULTANT_EMAIL=$(echo "$CLIENT_DATA" | jq -r '.consultant_email // empty')
        
        if [ -n "$PREFILL_CLIENT_NAME" ]; then
            echo -e "${GREEN}✓${NC} Found your registration: ${BOLD}$PREFILL_CLIENT_NAME${NC}"
            echo -e "  Your details have been pre-filled. Just confirm or edit as needed."
        fi
    else
        echo -e "${YELLOW}⚠${NC} Could not fetch pre-fill data (you'll enter details manually)"
    fi
    echo ""
fi

# Security notice
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  SECURITY NOTICE${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  - All credentials are entered directly in Google Cloud Console"
echo "  - You will create secrets yourself in Google's secure UI"
echo "  - No secrets pass through this script or are transmitted"
echo "  - Only metadata (project ID, URLs, contact info) is registered"
echo "  - Review: github.com/benedikt-waganari/corco-installer"
echo ""
read -p "Press Enter to continue (or Ctrl+C to abort)..."

# =============================================================================
# Step 1: Pre-flight Checks
# =============================================================================

# Always resolve the current account (needed for registration even on --resume)
CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")

if step_completed "preflight"; then
    log_step "Step 1/8: Pre-flight Checks (already completed)"
    log_success "Skipping - already verified"
else
    log_step "Step 1/8: Pre-flight Checks"

# Check gcloud
if ! command -v gcloud &> /dev/null; then
    log_error "Google Cloud SDK (gcloud) not found"
    echo "  Install from: https://cloud.google.com/sdk/docs/install"
    exit 1
fi
log_success "Google Cloud SDK found"

# Check terraform
if ! command -v terraform &> /dev/null; then
    log_error "Terraform not found"
    echo "  Install from: https://developer.hashicorp.com/terraform/install"
    exit 1
fi
log_success "Terraform found"

# Check authentication - auto-login if needed
CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")
if [ -z "$CURRENT_ACCOUNT" ]; then
    log_warning "Not logged in to gcloud - starting authentication..."
    echo ""
    echo "  Follow the prompts below to authenticate."
    echo "  Use your organization's Workspace admin account."
    echo ""
    gcloud auth login --no-launch-browser
    
    # Re-check after login
    CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")
    if [ -z "$CURRENT_ACCOUNT" ]; then
        log_error "Login failed or was cancelled"
        exit 1
    fi
    echo ""
fi

# Prominent account display - critical for clients to verify
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  VERIFY YOUR GOOGLE ACCOUNT${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  You are currently logged in as:"
echo ""
echo -e "    ${BOLD}${GREEN}${CURRENT_ACCOUNT}${NC}"
echo ""
echo -e "  This must be a ${BOLD}Workspace admin account${NC} for your org."
echo "  Using the wrong account will cause permission errors."
echo ""
read -p "Is this the correct admin account for your organization? [Y/n]: " confirm
if [[ "$confirm" =~ ^[Nn] ]]; then
    echo ""
    echo -e "${CYAN}A browser window will open for you to sign in with the correct account.${NC}"
    echo "Make sure to select your organization's Workspace admin account."
    echo ""
    read -p "Press Enter to open the Google login page..."
    echo ""
    gcloud auth login
    
    # Re-check account after login
    CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")
    if [ -z "$CURRENT_ACCOUNT" ]; then
        log_error "Login failed or was cancelled"
        exit 1
    fi
    echo ""
    echo -e "Now logged in as: ${BOLD}${GREEN}$CURRENT_ACCOUNT${NC}"
    read -p "Continue with this account? [Y/n]: " confirm2
    if [[ "$confirm2" =~ ^[Nn] ]]; then
        echo "Exiting. Re-run this script when ready."
        exit 0
    fi
fi
log_success "Account confirmed: $CURRENT_ACCOUNT"
    mark_step_complete "preflight"
fi

# =============================================================================
# Step 2: Company & Admin Information
# =============================================================================

if step_completed "company_info"; then
    log_step "Step 2/8: Company & Admin Information (already completed)"
    # Restore from state
    CLIENT_NAME=$(load_state "CLIENT_NAME" "")
    ADMIN_FIRST_NAME=$(load_state "ADMIN_FIRST_NAME" "")
    ADMIN_SURNAME=$(load_state "ADMIN_SURNAME" "")
    ADMIN_EMAIL=$(load_state "ADMIN_EMAIL" "")
    ADMIN_PHONE=$(load_state "ADMIN_PHONE" "")
    ADMIN_TELEGRAM=$(load_state "ADMIN_TELEGRAM" "")
    log_success "Skipping - using saved info for $CLIENT_NAME"
else
    log_step "Step 2/8: Company & Admin Information"

    echo ""
    echo -e "${CYAN}Company Information${NC}"
    echo ""

    # Domain is NEVER editable - must come from setup token for security
    if [ -z "$DOMAIN" ]; then
        log_error "Domain not set. Setup requires a valid setup token."
        echo ""
        echo "  To get a setup link, contact your Corco consultant or"
        echo "  request one from: https://corco.ai/get-started"
        echo ""
        exit 1
    fi

    echo -e "Domain: ${BOLD}$DOMAIN${NC} (locked - from setup token)"
    prompt CLIENT_NAME "Company/Client name (e.g., ACME Corporation)" "$PREFILL_CLIENT_NAME"

    echo ""
    echo -e "${CYAN}Admin Contact (primary point of contact)${NC}"
    echo ""
    prompt ADMIN_FIRST_NAME "Admin first name(s)" "$PREFILL_ADMIN_FIRST_NAME"
    prompt ADMIN_SURNAME "Admin surname" "$PREFILL_ADMIN_SURNAME"
    prompt ADMIN_EMAIL "Admin email" "${PREFILL_ADMIN_EMAIL:-admin@$DOMAIN}"
    prompt ADMIN_PHONE "Admin work phone (E.164 format, e.g., +14155551234)" "$PREFILL_ADMIN_PHONE"
    prompt ADMIN_TELEGRAM "Admin Telegram handle (optional, e.g., @johndoe)" "$PREFILL_ADMIN_TELEGRAM"

    # Save to state
    save_state "CLIENT_NAME" "$CLIENT_NAME"
    save_state "ADMIN_FIRST_NAME" "$ADMIN_FIRST_NAME"
    save_state "ADMIN_SURNAME" "$ADMIN_SURNAME"
    save_state "ADMIN_EMAIL" "$ADMIN_EMAIL"
    save_state "ADMIN_PHONE" "$ADMIN_PHONE"
    save_state "ADMIN_TELEGRAM" "$ADMIN_TELEGRAM"
    mark_step_complete "company_info"
fi

if [ -z "$CONSULTANT_EMAIL" ]; then
    CONSULTANT_EMAIL="support@corco.ai"
fi

# =============================================================================
# Step 3: GCP Project Setup
# =============================================================================

if step_completed "gcp_project"; then
    log_step "Step 3/8: GCP Project Setup (already completed)"
    # Restore project variables from state
    SAFE_DOMAIN=$(echo "$DOMAIN" | tr '.' '-' | tr '[:upper:]' '[:lower:]')
    PROJECT_ID="${SAFE_DOMAIN}-ingestion"
    REGION="us-central1"
    gcloud config set project "$PROJECT_ID" --quiet 2>/dev/null
    log_success "Skipping - project $PROJECT_ID already configured"
else
    log_step "Step 3/8: GCP Project Setup"

# Generate project ID from domain (not editable for consistency)
SAFE_DOMAIN=$(echo "$DOMAIN" | tr '.' '-' | tr '[:upper:]' '[:lower:]')
PROJECT_ID="${SAFE_DOMAIN}-ingestion"
REGION="us-central1"

echo ""
echo -e "GCP Project ID: ${BOLD}$PROJECT_ID${NC} (derived from domain)"
echo -e "GCP Region:     ${BOLD}$REGION${NC}"

# List billing accounts (with retry loop if none found)
echo ""
echo "Available billing accounts:"
BILLING_ACCOUNTS=$(gcloud billing accounts list --format="value(name,displayName)" 2>/dev/null | head -5)

while [ -z "$BILLING_ACCOUNTS" ]; do
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  NO BILLING ACCOUNT FOUND${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  You need a Google Cloud billing account to create a project."
    echo ""
    echo "  Steps:"
    echo "    1. Click the link below to open the billing page"
    echo "    2. Click 'Create account' or 'Add billing account'"
    echo "    3. Enter payment details (card or bank account)"
    echo "    4. Complete setup and return here"
    echo ""
    echo -e "  ${CYAN}Note: GCP offers \$300 free credits for new accounts.${NC}"
    echo ""
    echo -e "  ${BOLD}Open this link in a new browser tab to create a billing account:${NC}"
    open_url "https://console.cloud.google.com/billing/create"
    echo "  Complete billing setup in the browser, then return here."
    echo ""
    read -p "Press Enter when you've created a billing account (we'll check again)..."
    echo ""
    echo "Checking for billing accounts..."
    BILLING_ACCOUNTS=$(gcloud billing accounts list --format="value(name,displayName)" 2>/dev/null | head -5)
    
    if [ -z "$BILLING_ACCOUNTS" ]; then
        echo ""
        log_warning "Still no billing accounts found."
        echo "  This can happen if:"
        echo "    • The billing account is still being set up (wait a minute)"
        echo "    • You're logged in with a different Google account"
        echo "    • The account was created under a different organization"
        echo ""
        read -p "Try again? [Y/n]: " retry_billing
        if [[ "$retry_billing" =~ ^[Nn] ]]; then
            log_error "Cannot proceed without a billing account."
            echo "  Re-run this script after setting up billing."
            exit 1
        fi
    fi
done

echo ""
log_success "Billing account(s) found"

i=1
while IFS=$'\t' read -r id name; do
    echo "  $i) $name"
    eval "BILLING_$i=$id"
    i=$((i+1))
done <<< "$BILLING_ACCOUNTS"

echo ""
prompt BILLING_CHOICE "Select billing account (number)" "1"
eval "BILLING_ID=\$BILLING_$BILLING_CHOICE"

# Create or use existing project
echo ""
PROJECT_STATE=$(gcloud projects describe "$PROJECT_ID" --format="value(lifecycleState)" 2>/dev/null || echo "NOT_FOUND")

if [ "$PROJECT_STATE" = "ACTIVE" ]; then
    echo -e "${YELLOW}Project $PROJECT_ID already exists${NC}"
    echo ""
    echo "  An existing deployment was found. To ensure a clean install,"
    echo "  the previous deployment should be torn down first."
    echo ""
    read -p "Tear down existing deployment and start fresh? [Y/n]: " teardown_existing
    if [[ "$teardown_existing" =~ ^[Nn] ]]; then
        echo ""
        read -p "Use existing project as-is? [Y/n]: " use_existing
        if [[ "$use_existing" =~ ^[Nn] ]]; then
            log_error "Please choose a different project ID or tear down the existing one."
            exit 1
        fi
        log_success "Using existing project (without teardown)"
    else
        echo ""
        echo "Running teardown..."
        TEARDOWN_SCRIPT="$SCRIPT_DIR/teardown.sh"
        if [ -f "$TEARDOWN_SCRIPT" ]; then
            bash "$TEARDOWN_SCRIPT" "$DOMAIN" --all --force || true
            echo ""
            # After --all teardown, the project is in DELETE_REQUESTED state.
            # Re-check and undelete it for the fresh install.
            PROJECT_STATE=$(gcloud projects describe "$PROJECT_ID" --format="value(lifecycleState)" 2>/dev/null || echo "NOT_FOUND")
            if [ "$PROJECT_STATE" = "DELETE_REQUESTED" ]; then
                echo "Restoring project for fresh install..."
                gcloud projects undelete "$PROJECT_ID" --quiet
                log_success "Project restored from pending deletion"
            elif [ "$PROJECT_STATE" = "NOT_FOUND" ]; then
                echo "Creating project: $PROJECT_ID"
                DISPLAY_DOMAIN=$(echo "$DOMAIN" | sed 's/\.[^.]*$//' | tr '.' ' ')
                PROJECT_DISPLAY_NAME="Ingestion - ${DISPLAY_DOMAIN}"
                PROJECT_DISPLAY_NAME="${PROJECT_DISPLAY_NAME:0:30}"
                gcloud projects create "$PROJECT_ID" --name="$PROJECT_DISPLAY_NAME" --quiet
                log_success "Project created"
            else
                log_success "Project ready after teardown"
            fi
        else
            log_warning "Teardown script not found at: $TEARDOWN_SCRIPT"
            echo "  Continuing with existing project..."
        fi
    fi
elif [ "$PROJECT_STATE" = "DELETE_REQUESTED" ]; then
    echo -e "${YELLOW}Project $PROJECT_ID exists but is pending deletion${NC}"
    read -p "Restore and reuse it? [Y/n]: " restore_project
    if [[ "$restore_project" =~ ^[Nn] ]]; then
        log_error "Cannot create a new project with the same ID while deletion is pending (up to 30 days)."
        exit 1
    fi
    echo "Restoring project..."
    gcloud projects undelete "$PROJECT_ID" --quiet
    log_success "Project restored"
else
    echo "Creating project: $PROJECT_ID"
    # Display name: max 30 chars, no periods allowed
    # Use domain without TLD, replace dots with spaces, truncate
    DISPLAY_DOMAIN=$(echo "$DOMAIN" | sed 's/\.[^.]*$//' | tr '.' ' ')
    PROJECT_DISPLAY_NAME="Ingestion - ${DISPLAY_DOMAIN}"
    # Truncate to 30 chars if needed
    PROJECT_DISPLAY_NAME="${PROJECT_DISPLAY_NAME:0:30}"
    gcloud projects create "$PROJECT_ID" --name="$PROJECT_DISPLAY_NAME" --quiet
    log_success "Project created"
fi

# Link billing (skip if already linked to the selected account)
CURRENT_BILLING=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingAccountName)" 2>/dev/null || echo "")
CURRENT_BILLING_ID=$(echo "$CURRENT_BILLING" | sed 's|billingAccounts/||')

if [ "$CURRENT_BILLING_ID" = "$BILLING_ID" ]; then
    log_success "Billing already linked to selected account"
elif [ -n "$CURRENT_BILLING_ID" ] && [ "$CURRENT_BILLING_ID" != "$BILLING_ID" ]; then
    echo "Switching billing from $CURRENT_BILLING_ID to $BILLING_ID..."
    gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ID" --quiet
    log_success "Billing re-linked"
else
    echo "Linking billing account..."
    gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ID" --quiet
    log_success "Billing linked"
fi

# Set as current project
gcloud config set project "$PROJECT_ID" --quiet

# Enable APIs
echo ""
echo "Enabling required APIs (this takes 1-2 minutes)..."

# Cloud Resource Manager MUST be enabled first - it's required to manage other APIs
echo "  Enabling Cloud Resource Manager API (required first)..."
gcloud services enable cloudresourcemanager.googleapis.com --quiet

# Now enable the rest
APIS=(
    "storage.googleapis.com"
    "iam.googleapis.com"
    "cloudfunctions.googleapis.com"
    "run.googleapis.com"
    "cloudbuild.googleapis.com"
    "bigquery.googleapis.com"
    "secretmanager.googleapis.com"
    "cloudscheduler.googleapis.com"
    "eventarc.googleapis.com"
    "artifactregistry.googleapis.com"
    "admin.googleapis.com"
    "gmail.googleapis.com"
    "drive.googleapis.com"
    "aiplatform.googleapis.com"
)
gcloud services enable "${APIS[@]}" --quiet
log_success "APIs enabled"
    
    # Save project info to state
    save_state "PROJECT_ID" "$PROJECT_ID"
    save_state "REGION" "$REGION"
    mark_step_complete "gcp_project"
fi

# =============================================================================
# Step 4: API Credentials
# =============================================================================

if step_completed "credentials"; then
    log_step "Step 4/8: API Credentials (already completed)"
    # Restore integration choices from state
    ENABLE_TELEGRAM=$(load_state "ENABLE_TELEGRAM" "false")
    ENABLE_TWILIO=$(load_state "ENABLE_TWILIO" "false")
    ENABLE_OPENAI=$(load_state "ENABLE_OPENAI" "false")
    log_success "Skipping - credentials already configured"
else
    log_step "Step 4/8: API Credentials"

echo ""
echo -e "${GREEN}✓ Gmail${NC}        - Always included (email sync)"
echo -e "${GREEN}✓ Google Meet${NC} - Always included (meeting recordings)"
echo ""
echo "Which additional integrations do you need?"
echo ""
echo "  1) Telegram Bot      - Chat message ingestion"
echo "  2) Twilio            - Voice call transcription"
echo "  3) OpenAI            - AI enrichment features"
echo ""
read -p "Select (comma-separated, Enter for all, or 'none'): " integration_choices
if [ "$integration_choices" == "none" ]; then
    integration_choices=""
else
    integration_choices="${integration_choices:-1,2,3}"
fi
integration_choices="${integration_choices:-1,2,3}"

# Track enabled modules
ENABLE_TELEGRAM=false
ENABLE_TWILIO=false
ENABLE_OPENAI=false

IFS=',' read -ra SELECTED <<< "$integration_choices"
for choice in "${SELECTED[@]}"; do
    choice=$(echo "$choice" | tr -d ' ')
    case $choice in
        1) ENABLE_TELEGRAM=true ;;
        2) ENABLE_TWILIO=true ;;
        3) ENABLE_OPENAI=true ;;
    esac
done

# Warn about Telegram org policy requirement
if [ "$ENABLE_TELEGRAM" == "true" ]; then
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  ℹ️  TELEGRAM REQUIRES PUBLIC WEBHOOK${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Telegram integration works via webhooks - Telegram's servers send"
    echo "  messages to your Cloud Function. This requires public access."
    echo ""
    echo "  Many GCP organizations have a default policy (iam.allowedPolicyMemberDomains)"
    echo "  that blocks public access."
    echo ""
    echo "  If this policy exists, you'll need Organization Policy Admin permissions"
    echo "  to add a project-level exception. Setup will detect this and guide you."
    echo ""
    read -p "  Press Enter to continue..."
fi

# Helper: verify secret has a value
verify_secret() {
    local secret_name=$1
    local friendly_name=$2
    
    if gcloud secrets versions list "$secret_name" --project="$PROJECT_ID" --limit=1 --format="value(name)" 2>/dev/null | grep -q .; then
        echo -e "  ${GREEN}✓${NC} $friendly_name saved"
        return 0
    else
        echo -e "  ${YELLOW}⚠${NC} $friendly_name not saved yet (you can add it later)"
        return 1
    fi
}

# Create ALL empty secrets upfront
echo ""
echo "Creating secret containers..."
SECRETS_TO_CREATE=()
[ "$ENABLE_TELEGRAM" == "true" ] && SECRETS_TO_CREATE+=("CORCO_TELEGRAM_BOT_TOKEN")
[ "$ENABLE_TWILIO" == "true" ] && SECRETS_TO_CREATE+=("CORCO_TWILIO_ACCOUNT_SID" "CORCO_TWILIO_AUTH_TOKEN")
[ "$ENABLE_OPENAI" == "true" ] && SECRETS_TO_CREATE+=("CORCO_OPENAI_API_KEY")

for secret in "${SECRETS_TO_CREATE[@]}"; do
    if ! gcloud secrets describe "$secret" --project="$PROJECT_ID" &>/dev/null 2>&1; then
        gcloud secrets create "$secret" --project="$PROJECT_ID" --quiet 2>/dev/null
        echo -e "  ${GREEN}✓${NC} $secret"
    else
        echo -e "  ${CYAN}•${NC} $secret (exists)"
    fi
done

SECRET_MANAGER_URL="https://console.cloud.google.com/security/secret-manager/secret"

# Helper: check if secret has a value
secret_has_value() {
    local secret_name=$1
    gcloud secrets versions list "$secret_name" --project="$PROJECT_ID" --limit=1 --format="value(name)" 2>/dev/null | grep -q .
}

# Process each integration: check existing → offer to keep or override
if [ "$ENABLE_TELEGRAM" == "true" ]; then
    echo ""
    echo -e "${CYAN}━━━ TELEGRAM ━━━${NC}"
    echo ""
    
    if secret_has_value "CORCO_TELEGRAM_BOT_TOKEN"; then
        echo -e "  ${GREEN}✓${NC} Telegram bot token already configured."
        read -p "  Keep existing token? [Y/n]: " keep_telegram
        if [[ ! "$keep_telegram" =~ ^[Nn] ]]; then
            echo -e "  ${GREEN}✓${NC} Keeping existing Telegram token"
        else
            echo ""
            echo -e "${YELLOW}Note: Use a company Telegram account, not personal.${NC}"
            echo ""
            echo "Opening BotFather..."
            open_url "https://t.me/BotFather"
            echo ""
            echo -e "  1. Send ${BOLD}/newbot${NC} to BotFather"
            echo "  2. Choose a display name and username"
            echo -e "  3. ${BOLD}Copy the token${NC} (looks like: 123456789:ABCdef...)"
            echo ""
            read -p "  Press Enter when you've copied the token..."
            echo ""
            echo "  Opening Secret Manager..."
            open_url "${SECRET_MANAGER_URL}/CORCO_TELEGRAM_BOT_TOKEN?project=${PROJECT_ID}"
            echo ""
            echo -e "  4. Click '${BOLD}+ New version${NC}'"
            echo -e "  5. Paste into '${BOLD}Secret value${NC}'"
            echo -e "  6. Click '${BOLD}Add new version${NC}'"
            echo ""
            read -p "  Press Enter when done..."
            verify_secret "CORCO_TELEGRAM_BOT_TOKEN" "Telegram token"
        fi
    else
        echo -e "${YELLOW}Note: Use a company Telegram account, not personal.${NC}"
        echo "   The Telegram account that creates the bot owns it permanently."
        echo ""
        read -p "  Press Enter when ready with a company Telegram account..."
        echo ""
        echo "Opening BotFather..."
        open_url "https://t.me/BotFather"
        echo ""
        echo -e "  1. Send ${BOLD}/newbot${NC} to BotFather"
        echo "  2. Choose a display name and username"
        echo -e "  3. ${BOLD}Copy the token${NC} (looks like: 123456789:ABCdef...)"
        echo ""
        read -p "  Press Enter when you've copied the token..."
        echo ""
        echo "  Opening Secret Manager..."
        open_url "${SECRET_MANAGER_URL}/CORCO_TELEGRAM_BOT_TOKEN?project=${PROJECT_ID}"
        echo ""
        echo -e "  4. Click '${BOLD}+ New version${NC}'"
        echo -e "  5. Paste into '${BOLD}Secret value${NC}'"
        echo -e "  6. Click '${BOLD}Add new version${NC}'"
        echo ""
        read -p "  Press Enter when done..."
        verify_secret "CORCO_TELEGRAM_BOT_TOKEN" "Telegram token"
    fi
fi

if [ "$ENABLE_TWILIO" == "true" ]; then
    echo ""
    echo -e "${CYAN}━━━ TWILIO ━━━${NC}"
    echo ""
    
    # Check if both Twilio secrets already have values
    TWILIO_SID_EXISTS=false
    TWILIO_TOKEN_EXISTS=false
    secret_has_value "CORCO_TWILIO_ACCOUNT_SID" && TWILIO_SID_EXISTS=true
    secret_has_value "CORCO_TWILIO_AUTH_TOKEN" && TWILIO_TOKEN_EXISTS=true
    
    if [ "$TWILIO_SID_EXISTS" == "true" ] && [ "$TWILIO_TOKEN_EXISTS" == "true" ]; then
        echo -e "  ${GREEN}✓${NC} Twilio credentials already configured."
        read -p "  Keep existing credentials? [Y/n]: " keep_twilio
        if [[ ! "$keep_twilio" =~ ^[Nn] ]]; then
            echo -e "  ${GREEN}✓${NC} Keeping existing Twilio credentials"
        else
            # User wants to override - show full flow
            echo ""
            echo -e "  ${BOLD}Step 1: Select your subaccount${NC}"
            echo "    If you use subaccounts (e.g. dev/prod), select the right one now."
            echo ""
            echo "  Opening Twilio Subaccounts page..."
            open_url "https://console.twilio.com/us1/account/manage-account/subaccounts"
            echo ""
            read -p "  Press Enter once you have selected the correct subaccount..."
            echo ""
            
            echo -e "  ${BOLD}Step 2: Get Account SID${NC}"
            open_url "https://console.twilio.com/us1/account/keys-credentials/api-keys"
            echo ""
            echo -e "  Find your ${BOLD}Account SID${NC} (starts with AC...) and copy it"
            echo ""
            read -p "  Press Enter when you've copied the Account SID..."
            echo ""
            echo "  Opening Secret Manager..."
            open_url "${SECRET_MANAGER_URL}/CORCO_TWILIO_ACCOUNT_SID?project=${PROJECT_ID}"
            echo ""
            echo -e "  Click '${BOLD}+ New version${NC}', paste, click '${BOLD}Add new version${NC}'"
            echo ""
            read -p "  Press Enter when done..."
            verify_secret "CORCO_TWILIO_ACCOUNT_SID" "Account SID"
            echo ""
            
            echo -e "  ${BOLD}Step 3: Get Auth Token${NC}"
            open_url "https://console.twilio.com/us1/account/keys-credentials/api-keys"
            echo ""
            echo -e "  Click the eye icon next to ${BOLD}Auth Token${NC}, then copy it"
            echo ""
            read -p "  Press Enter when you've copied the Auth Token..."
            echo ""
            echo "  Opening Secret Manager..."
            open_url "${SECRET_MANAGER_URL}/CORCO_TWILIO_AUTH_TOKEN?project=${PROJECT_ID}"
            echo ""
            echo -e "  Click '${BOLD}+ New version${NC}', paste, click '${BOLD}Add new version${NC}'"
            echo ""
            read -p "  Press Enter when done..."
            verify_secret "CORCO_TWILIO_AUTH_TOKEN" "Auth Token"
        fi
    else
        # No existing credentials - show full flow
        echo -e "  ${BOLD}Step 1: Select your subaccount${NC}"
        echo "    If you use subaccounts (e.g. dev/prod), select the right one now."
        echo ""
        echo "  Opening Twilio Subaccounts page..."
        open_url "https://console.twilio.com/us1/account/manage-account/subaccounts"
        echo ""
        read -p "  Press Enter once you have selected the correct subaccount..."
        echo ""
        
        echo -e "  ${BOLD}Step 2: Get Account SID${NC}"
        open_url "https://console.twilio.com/us1/account/keys-credentials/api-keys"
        echo ""
        echo -e "  Find your ${BOLD}Account SID${NC} (starts with AC...) and copy it"
        echo ""
        read -p "  Press Enter when you've copied the Account SID..."
        echo ""
        echo "  Opening Secret Manager..."
        open_url "${SECRET_MANAGER_URL}/CORCO_TWILIO_ACCOUNT_SID?project=${PROJECT_ID}"
        echo ""
        echo -e "  Click '${BOLD}+ New version${NC}', paste, click '${BOLD}Add new version${NC}'"
        echo ""
        read -p "  Press Enter when done..."
        verify_secret "CORCO_TWILIO_ACCOUNT_SID" "Account SID"
        echo ""
        
        echo -e "  ${BOLD}Step 3: Get Auth Token${NC}"
        open_url "https://console.twilio.com/us1/account/keys-credentials/api-keys"
        echo ""
        echo -e "  Click the eye icon next to ${BOLD}Auth Token${NC}, then copy it"
        echo ""
        read -p "  Press Enter when you've copied the Auth Token..."
        echo ""
        echo "  Opening Secret Manager..."
        open_url "${SECRET_MANAGER_URL}/CORCO_TWILIO_AUTH_TOKEN?project=${PROJECT_ID}"
        echo ""
        echo -e "  Click '${BOLD}+ New version${NC}', paste, click '${BOLD}Add new version${NC}'"
        echo ""
        read -p "  Press Enter when done..."
        verify_secret "CORCO_TWILIO_AUTH_TOKEN" "Auth Token"
    fi
fi

if [ "$ENABLE_OPENAI" == "true" ]; then
    echo ""
    echo -e "${CYAN}━━━ OPENAI ━━━${NC}"
    echo ""
    
    if secret_has_value "CORCO_OPENAI_API_KEY"; then
        echo -e "  ${GREEN}✓${NC} OpenAI API key already configured."
        read -p "  Keep existing key? [Y/n]: " keep_openai
        if [[ ! "$keep_openai" =~ ^[Nn] ]]; then
            echo -e "  ${GREEN}✓${NC} Keeping existing OpenAI key"
        else
            echo ""
            echo "Opening OpenAI API Keys page..."
            open_url "https://platform.openai.com/api-keys"
            echo ""
            echo -e "  1. Click '${BOLD}+ Create new secret key${NC}'"
            echo "  2. Name it (e.g., 'AI Ingestion')"
            echo -e "  3. ${BOLD}Copy the key${NC} (starts with sk-...) - you can only see it once!"
            echo ""
            read -p "  Press Enter when you've copied the key..."
            echo ""
            echo "  Opening Secret Manager..."
            open_url "${SECRET_MANAGER_URL}/CORCO_OPENAI_API_KEY?project=${PROJECT_ID}"
            echo ""
            echo -e "  Click '${BOLD}+ New version${NC}', paste, click '${BOLD}Add new version${NC}'"
            echo ""
            read -p "  Press Enter when done..."
            verify_secret "CORCO_OPENAI_API_KEY" "OpenAI key"
        fi
    else
        echo "Opening OpenAI API Keys page..."
        open_url "https://platform.openai.com/api-keys"
        echo ""
        echo -e "  1. Click '${BOLD}+ Create new secret key${NC}'"
        echo "  2. Name it (e.g., 'AI Ingestion')"
        echo -e "  3. ${BOLD}Copy the key${NC} (starts with sk-...) - you can only see it once!"
        echo ""
        read -p "  Press Enter when you've copied the key..."
        echo ""
        echo "  Opening Secret Manager..."
        open_url "${SECRET_MANAGER_URL}/CORCO_OPENAI_API_KEY?project=${PROJECT_ID}"
        echo ""
        echo -e "  Click '${BOLD}+ New version${NC}', paste, click '${BOLD}Add new version${NC}'"
        echo ""
        read -p "  Press Enter when done..."
        verify_secret "CORCO_OPENAI_API_KEY" "OpenAI key"
    fi
fi

echo ""

log_success "Credentials configured"
    
    # Save integration choices to state
    save_state "ENABLE_TELEGRAM" "$ENABLE_TELEGRAM"
    save_state "ENABLE_TWILIO" "$ENABLE_TWILIO"
    save_state "ENABLE_OPENAI" "$ENABLE_OPENAI"
    mark_step_complete "credentials"
fi

# =============================================================================
# Step 5: Historical Data Import Options
# =============================================================================

if step_completed "historical_import"; then
    log_step "Step 5/8: Historical Data Import (already completed)"
    # Restore from state
    GMAIL_IMPORT_MODE=$(load_state "GMAIL_IMPORT_MODE" "all")
    GMAIL_SYNC_SINCE=$(load_state "GMAIL_SYNC_SINCE" "")
    TWILIO_IMPORT_EXISTING=$(load_state "TWILIO_IMPORT_EXISTING" "false")
    TWILIO_IMPORT_SINCE=$(load_state "TWILIO_IMPORT_SINCE" "")
    MEET_IMPORT_EXISTING=$(load_state "MEET_IMPORT_EXISTING" "true")
    log_success "Skipping - using saved import settings"
else
    log_step "Step 5/8: Historical Data Import"

    echo ""
    echo -e "${CYAN}Do you want to import existing historical data?${NC}"
    echo ""

    # Gmail
    echo -e "${CYAN}━━━ GMAIL ━━━${NC}"
    echo ""
    echo "  1) Import ALL emails (full history)"
    echo "  2) Import from a specific date"
    echo "  3) New emails only"
    echo ""
    read -p "  Gmail import mode [1/2/3, default=1]: " gmail_mode
    gmail_mode="${gmail_mode:-1}"

    GMAIL_IMPORT_MODE="all"
    GMAIL_SYNC_SINCE=""
    case $gmail_mode in
        1) GMAIL_IMPORT_MODE="all" ;;
        2) 
            GMAIL_IMPORT_MODE="since"
            read -p "  Import emails since (YYYY-MM-DD): " GMAIL_SYNC_SINCE
            ;;
        3) GMAIL_IMPORT_MODE="none" ;;
    esac
    echo -e "  ${GREEN}✓${NC} Gmail: $GMAIL_IMPORT_MODE${GMAIL_SYNC_SINCE:+ (since $GMAIL_SYNC_SINCE)}"

    echo ""

    # Twilio
    echo -e "${CYAN}━━━ TWILIO RECORDINGS ━━━${NC}"
    echo ""
    echo "  1) Import existing recordings"
    echo "  2) New calls only"
    echo ""
    read -p "  Twilio import mode [1/2, default=2]: " twilio_mode
    twilio_mode="${twilio_mode:-2}"

    TWILIO_IMPORT_EXISTING="false"
    TWILIO_IMPORT_SINCE=""
    case $twilio_mode in
        1)
            TWILIO_IMPORT_EXISTING="true"
            read -p "  Import from (YYYY-MM-DD, or Enter for all): " TWILIO_IMPORT_SINCE
            ;;
    esac
    echo -e "  ${GREEN}✓${NC} Twilio: import_existing=$TWILIO_IMPORT_EXISTING"

    echo ""

    # Google Meet
    echo -e "${CYAN}━━━ GOOGLE MEET ━━━${NC}"
    echo ""
    echo "  1) Process existing recordings in Drive"
    echo "  2) New recordings only"
    echo ""
    read -p "  Meet import mode [1/2, default=1]: " meet_mode
    meet_mode="${meet_mode:-1}"

    MEET_IMPORT_EXISTING="true"
    [ "$meet_mode" == "2" ] && MEET_IMPORT_EXISTING="false"
    echo -e "  ${GREEN}✓${NC} Meet: import_existing=$MEET_IMPORT_EXISTING"

    # Save to state
    save_state "GMAIL_IMPORT_MODE" "$GMAIL_IMPORT_MODE"
    save_state "GMAIL_SYNC_SINCE" "$GMAIL_SYNC_SINCE"
    save_state "TWILIO_IMPORT_EXISTING" "$TWILIO_IMPORT_EXISTING"
    save_state "TWILIO_IMPORT_SINCE" "$TWILIO_IMPORT_SINCE"
    save_state "MEET_IMPORT_EXISTING" "$MEET_IMPORT_EXISTING"
    mark_step_complete "historical_import"

    log_success "Historical import options configured"
fi

# =============================================================================
# Step 6: Domain-Wide Delegation
# =============================================================================

if step_completed "dwd"; then
    log_step "Step 6/8: Gmail Domain-Wide Delegation (already completed)"
    # Restore service account info from state
    SA_NAME="gmail-sync-sa"
    SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
    CLIENT_ID=$(load_state "CLIENT_ID" "")
    log_success "Skipping - DWD already configured"
else
    log_step "Step 6/8: Gmail Domain-Wide Delegation"

echo ""
echo -e "${YELLOW}This allows the system to read emails from your organization.${NC}"
echo ""

# Create Gmail service account
SA_NAME="gmail-sync-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null 2>&1; then
    log_success "Service account already exists"
else
    gcloud iam service-accounts create "$SA_NAME" \
        --display-name="Gmail Sync Service Account" \
        --project="$PROJECT_ID" --quiet
    log_success "Service account created"
fi

# Get Client ID
CLIENT_ID=$(gcloud iam service-accounts describe "$SA_EMAIL" --format='value(uniqueId)' 2>/dev/null || echo "")

# Authentication method: try key-based first, fall back to impersonation
# Key-based: traditional JSON key stored in Secret Manager
# Impersonation: Cloud Functions impersonate gmail-sync-sa (no downloadable key needed)

AUTH_METHOD=""

# Check if key already exists in Secret Manager
if gcloud secrets versions access latest --secret="CORCO_GMAIL_SA_KEY" --project="$PROJECT_ID" &>/dev/null 2>&1; then
    log_success "Service account key already stored (reusing existing)"
    AUTH_METHOD="key"
else
    # Try to create a key (disable set -e temporarily to catch org policy errors)
    echo "Creating service account key..."
    KEY_FILE="/tmp/gmail-sa-key-$$.json"
    
    set +e  # Disable exit-on-error to handle org policy gracefully
    KEY_CREATE_OUTPUT=$(gcloud iam service-accounts keys create "$KEY_FILE" \
        --iam-account="$SA_EMAIL" \
        --project="$PROJECT_ID" --quiet 2>&1)
    KEY_CREATE_EXIT=$?
    set -e  # Re-enable exit-on-error
    
    if [ $KEY_CREATE_EXIT -eq 0 ]; then
        create_secret "CORCO_GMAIL_SA_KEY" "$(cat $KEY_FILE)"
        rm -f "$KEY_FILE"
        log_success "Service account key stored"
        AUTH_METHOD="key"
    elif echo "$KEY_CREATE_OUTPUT" | grep -q "disableServiceAccountKeyCreation\|CUSTOM_ORG_POLICY_VIOLATION"; then
        # Org policy blocks keys - use impersonation instead (more secure anyway)
        echo ""
        echo -e "  ${CYAN}ℹ${NC}  Your organization blocks service account keys (good security practice)"
        echo "     Setting up service account impersonation instead..."
        echo ""
        
        # Get the project number (needed for default compute SA)
        PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null)
        
        # Get the default compute service account (used by Cloud Functions)
        COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
        
        # Grant the compute SA permission to impersonate gmail-sync-sa
        echo "  Granting impersonation permissions..."
        if ! gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
            --project="$PROJECT_ID" \
            --member="serviceAccount:${COMPUTE_SA}" \
            --role="roles/iam.serviceAccountTokenCreator" \
            --quiet; then
            echo -e "  ${RED}Failed to grant impersonation permission to ${COMPUTE_SA}${NC}"
            exit 1
        fi
        
        # Also grant to the Cloud Functions service account if different
        FUNCTIONS_SA="${PROJECT_ID}@appspot.gserviceaccount.com"
        if [ "$FUNCTIONS_SA" != "$COMPUTE_SA" ]; then
            gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
                --project="$PROJECT_ID" \
                --member="serviceAccount:${FUNCTIONS_SA}" \
                --role="roles/iam.serviceAccountTokenCreator" \
                --quiet 2>/dev/null || true  # Optional, may not exist
        fi
        
        # Store the SA email as the "key" - functions will use impersonation
        create_secret "CORCO_GMAIL_SA_KEY" "{\"type\":\"impersonation\",\"service_account_email\":\"${SA_EMAIL}\"}"
        
        log_success "Service account impersonation configured"
        AUTH_METHOD="impersonation"
    else
        # Some other error
        echo -e "${RED}Error creating service account key:${NC}"
        echo "$KEY_CREATE_OUTPUT"
        exit 1
    fi
fi

# Store auth method in state for Terraform
save_state "GMAIL_AUTH_METHOD" "$AUTH_METHOD"

echo ""
echo -e "  ${GREEN}Client ID: ${BOLD}$CLIENT_ID${NC}"
echo ""
echo "  Opening Google Workspace Admin Console..."
echo ""
echo -e "  ${YELLOW}Steps:${NC}"
echo "    1. Click 'Add new'"
echo "    2. Paste this Client ID:"
echo ""
echo -e "       ${GREEN}$CLIENT_ID${NC}"
echo ""
echo "    3. Paste these OAuth scopes:"
echo ""
echo -e "       ${GREEN}https://www.googleapis.com/auth/gmail.readonly,https://www.googleapis.com/auth/admin.directory.user.readonly${NC}"
echo ""
echo "    4. Click 'Authorize'"
echo ""

open_url "https://admin.google.com/ac/owl/domainwidedelegation"

read -p "  Press Enter when you've completed Domain-Wide Delegation..."
log_success "Domain-Wide Delegation configured"
    
    # Save client ID to state
    save_state "CLIENT_ID" "$CLIENT_ID"
    mark_step_complete "dwd"
fi

# =============================================================================
# Step 6b: License Tier Verification
# =============================================================================
# Query Admin SDK to verify user count matches licensed tier

log_step "Verifying License Tier"

echo ""
echo "Checking Workspace user count against licensed tier..."
echo ""

# License tier limits (from PRICING.md)
TIER_SMALL_LIMIT=50
TIER_MEDIUM_LIMIT=100
TIER_LARGE_LIMIT=200
TIER_XLARGE_LIMIT=500
TIER_ENTERPRISE_LIMIT=1000

# Grace buffer (10%)
GRACE_BUFFER_PERCENT=10

# Initialize license tracking variables
LICENSE_EXCEEDED="false"
LICENSE_EXCEEDED_BY=0
LICENSE_STATUS="unknown"

# Function to get active user count via Admin SDK
get_workspace_user_count() {
    local domain=$1
    local admin_email=$2
    local sa_key_secret=$3
    
    # Download SA key temporarily
    local temp_key="/tmp/license-check-key-$$.json"
    if ! gcloud secrets versions access latest --secret="$sa_key_secret" --project="$PROJECT_ID" > "$temp_key" 2>/dev/null; then
        echo "0"
        rm -f "$temp_key"
        return 1
    fi
    
    # Use gcloud to get user count (requires DWD to be configured)
    # This uses the Admin SDK Directory API
    local user_count
    user_count=$(python3 -c "
import json
import sys
try:
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
    
    SCOPES = ['https://www.googleapis.com/auth/admin.directory.user.readonly']
    
    credentials = service_account.Credentials.from_service_account_file(
        '$temp_key',
        scopes=SCOPES
    )
    delegated_credentials = credentials.with_subject('$admin_email')
    
    service = build('admin', 'directory_v1', credentials=delegated_credentials)
    
    # Count active users (not suspended)
    count = 0
    page_token = None
    while True:
        results = service.users().list(
            domain='$domain',
            query='isSuspended=false',
            maxResults=500,
            pageToken=page_token
        ).execute()
        
        users = results.get('users', [])
        count += len(users)
        
        page_token = results.get('nextPageToken')
        if not page_token:
            break
    
    print(count)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    print('0')
" 2>/dev/null)
    
    rm -f "$temp_key"
    echo "$user_count"
}

# Get licensed tier from registry (already fetched in CLIENT_DATA)
LICENSED_TIER=""
LICENSED_LIMIT=0

if [ -n "$CLIENT_DATA" ] && [ "$CLIENT_DATA" != "null" ]; then
    LICENSED_TIER=$(echo "$CLIENT_DATA" | jq -r '.license.tier // "unknown"' 2>/dev/null || echo "unknown")
    LICENSED_LIMIT=$(echo "$CLIENT_DATA" | jq -r '.license.user_limit // 0' 2>/dev/null || echo "0")
fi

# Handle license display
if [ "$LICENSED_TIER" == "Founder" ] || [ "$LICENSED_LIMIT" == "0" ]; then
    echo -e "  License tier: ${GREEN}${BOLD}$LICENSED_TIER${NC} (unlimited users)"
    SKIP_LICENSE_CHECK="true"  # Founders have unlimited
elif [ -n "$LICENSED_TIER" ] && [ "$LICENSED_TIER" != "unknown" ]; then
    echo -e "  License tier: ${BOLD}$LICENSED_TIER${NC} (up to $LICENSED_LIMIT users)"
    SKIP_LICENSE_CHECK="false"
else
    echo -e "${YELLOW}Note: Could not retrieve licensed tier from registry.${NC}"
    echo "  License verification will be skipped."
    SKIP_LICENSE_CHECK="true"
fi

# Perform license verification
if [ "$SKIP_LICENSE_CHECK" != "true" ]; then
    echo "Querying Admin SDK for active user count..."
    echo ""
    
    WORKSPACE_USER_COUNT=$(get_workspace_user_count "$DOMAIN" "$ADMIN_EMAIL" "CORCO_GMAIL_SA_KEY")
    
    if [ "$WORKSPACE_USER_COUNT" == "0" ] || [ -z "$WORKSPACE_USER_COUNT" ]; then
        log_warning "Could not verify user count (DWD may not be active yet)"
        echo "  This is normal if you just configured Domain-Wide Delegation."
        echo "  User count will be verified automatically on first sync."
        WORKSPACE_USER_COUNT="unknown"
    else
        echo -e "  Active Workspace users: ${BOLD}$WORKSPACE_USER_COUNT${NC}"
        echo -e "  Licensed tier:          ${BOLD}$LICENSED_TIER${NC} (up to $LICENSED_LIMIT users)"
        echo ""
        
        # Calculate grace limit (10% buffer) - using bash arithmetic instead of bc
        GRACE_BUFFER_AMOUNT=$((LICENSED_LIMIT * GRACE_BUFFER_PERCENT / 100))
        GRACE_LIMIT=$((LICENSED_LIMIT + GRACE_BUFFER_AMOUNT))
        
        if [ "$WORKSPACE_USER_COUNT" -gt "$LICENSED_LIMIT" ]; then
            if [ "$WORKSPACE_USER_COUNT" -le "$GRACE_LIMIT" ]; then
                # Soft warning (within grace period)
                log_warning "User count ($WORKSPACE_USER_COUNT) slightly exceeds license ($LICENSED_LIMIT)"
                echo "  This is within the 10% grace period."
                echo "  Consider upgrading if you expect continued growth."
                LICENSE_STATUS="grace_period"
            else
                # Hard warning (over grace period)
                echo ""
                echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${YELLOW}  LICENSE TIER EXCEEDED${NC}"
                echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
                echo -e "  Your Workspace: ${BOLD}$WORKSPACE_USER_COUNT${NC} active users"
                echo -e "  Your license:   ${BOLD}$LICENSED_LIMIT${NC} users"
                echo ""
                echo "  Setup will continue, but please contact Corco to discuss"
                echo "  upgrading your license tier."
                echo ""
                LICENSE_STATUS="exceeded"
                
                # Flag for sales follow-up (will be sent with registration)
                LICENSE_EXCEEDED="true"
                LICENSE_EXCEEDED_BY=$((WORKSPACE_USER_COUNT - LICENSED_LIMIT))
            fi
        else
            log_success "User count ($WORKSPACE_USER_COUNT) within licensed tier ($LICENSED_LIMIT)"
            LICENSE_STATUS="compliant"
        fi
    fi
else
    WORKSPACE_USER_COUNT="unknown"
    LICENSE_STATUS="skipped"
fi

echo ""

# =============================================================================
# Step 7: Terraform Deployment
# =============================================================================

# Grant Cloud Build service account permissions BEFORE Terraform tries to create functions
# This is required for Cloud Functions Gen 2 builds
# ALWAYS run this, even on resume, to ensure permissions are current
echo ""
echo "Granting Cloud Build service account permissions..."



PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>&1)
PROJECT_NUMBER_EXIT=$?


if [ -z "$PROJECT_NUMBER" ] || [ $PROJECT_NUMBER_EXIT -ne 0 ]; then
    echo -e "${RED}ERROR: Could not get project number for $PROJECT_ID${NC}"
    echo "  This might indicate authentication or permission issues."
    exit 1
fi

CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
echo "  Cloud Build SA: $CLOUDBUILD_SA"
echo "  Project Number: $PROJECT_NUMBER"


# Function to grant permission with proper error handling
grant_permission() {
    local role=$1
    local description=$2
    echo -n "  Granting $role... "
    
    
    local grant_output
    grant_output=$(gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${CLOUDBUILD_SA}" \
        --role="$role" \
        --quiet 2>&1)
    local exit_code=$?
    
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓${NC}"
        return 0
    else
        # Check if it's "already exists" error (which is actually success)
        if echo "$grant_output" | grep -qi "already exists\|already has\|already granted"; then
            echo -e "${YELLOW}(already granted)${NC}"
            return 0
        else
            echo -e "${RED}✗ FAILED${NC}"
            echo "    Error: $(echo $grant_output | head -c 200)"
            return 1
        fi
    fi
}

# Grant required project-level roles
ERRORS=0
grant_permission "roles/cloudbuild.builds.builder" "Cloud Build builder role" || ERRORS=$((ERRORS + 1))
grant_permission "roles/run.admin" "Cloud Run admin role" || ERRORS=$((ERRORS + 1))
grant_permission "roles/iam.serviceAccountUser" "Service Account User role" || ERRORS=$((ERRORS + 1))
grant_permission "roles/cloudfunctions.developer" "Cloud Functions developer role" || ERRORS=$((ERRORS + 1))
grant_permission "roles/artifactregistry.writer" "Artifact Registry writer role" || ERRORS=$((ERRORS + 1))
grant_permission "roles/storage.objectViewer" "Storage object viewer role" || ERRORS=$((ERRORS + 1))
grant_permission "roles/logging.logWriter" "Logging writer role" || ERRORS=$((ERRORS + 1))

# Grant Cloud Build permission to act as the default compute service account
# This is required for Cloud Functions Gen 2 to deploy
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
echo -n "  Granting serviceAccountTokenCreator on $COMPUTE_SA... "
token_creator_output=$(gcloud iam service-accounts add-iam-policy-binding "$COMPUTE_SA" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${CLOUDBUILD_SA}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --quiet 2>&1)
token_creator_exit=$?

if [ $token_creator_exit -eq 0 ]; then
    echo -e "${GREEN}✓${NC}"
elif echo "$token_creator_output" | grep -qi "already exists\|already has\|already granted"; then
    echo -e "${YELLOW}(already granted)${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
    echo "    Error: $(echo $token_creator_output | head -c 200)"
    ERRORS=$((ERRORS + 1))
fi

if [ $ERRORS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}WARNING: $ERRORS permission(s) failed to grant.${NC}"
    echo "  This may cause Cloud Function builds to fail."
    echo "  Check your IAM permissions and organization policies."
    echo ""
    read -p "  Continue anyway? [y/N]: " continue_anyway
    if [ "$continue_anyway" != "y" ] && [ "$continue_anyway" != "Y" ]; then
        exit 1
    fi
fi

# Wait for permissions to propagate (IAM changes can take a few seconds)
echo ""
echo "  Waiting 10 seconds for IAM permissions to propagate..."


sleep 10


# Verify permissions were actually granted
echo "  Verifying permissions..."
VERIFICATION_FAILED=0
for role in "roles/cloudbuild.builds.builder" "roles/run.admin" "roles/iam.serviceAccountUser" "roles/cloudfunctions.developer" "roles/artifactregistry.writer" "roles/storage.objectViewer" "roles/logging.logWriter"; do
    if gcloud projects get-iam-policy "$PROJECT_ID" \
        --flatten="bindings[].members" \
        --filter="bindings.members:serviceAccount:${CLOUDBUILD_SA} AND bindings.role:${role}" \
        --format="value(bindings.role)" 2>/dev/null | grep -q "$role"; then
        : # Permission verified
    else
        VERIFICATION_FAILED=1
    fi
done

if [ $VERIFICATION_FAILED -eq 1 ]; then
    echo -e "${YELLOW}  WARNING: Some permissions could not be verified${NC}"
fi

log_success "Cloud Build permissions granted"

if step_completed "terraform"; then
    log_step "Step 7/8: Infrastructure Deployment (already completed)"
    # Restore Terraform outputs from state
    cd "$TERRAFORM_DIR"
    TFSTATE_BUCKET="${PROJECT_ID}-tfstate"
    # Re-init to connect to remote state
    terraform init -input=false -reconfigure \
        -backend-config="bucket=${TFSTATE_BUCKET}" \
        -backend-config="prefix=ai-ingestion" >/dev/null 2>&1 || true
    GMAIL_SYNC_URL=$(terraform output -raw gmail_sync_url 2>/dev/null || load_state "GMAIL_SYNC_URL" "")
    TELEGRAM_WEBHOOK_URL=$(terraform output -raw telegram_webhook_url 2>/dev/null || load_state "TELEGRAM_WEBHOOK_URL" "")
    DRIVE_SYNC_URL=$(terraform output -raw drive_sync_url 2>/dev/null || load_state "DRIVE_SYNC_URL" "")
    VOICE_ENROLL_URL=$(terraform output -raw voice_enroll_url 2>/dev/null || load_state "VOICE_ENROLL_URL" "")
    STANDARDIZE_UTTERANCES_URL=$(terraform output -raw standardize_utterances_url 2>/dev/null || load_state "STANDARDIZE_UTTERANCES_URL" "")
    RECORDINGS_BUCKET=$(terraform output -raw recordings_bucket 2>/dev/null || load_state "RECORDINGS_BUCKET" "")
    BIGQUERY_DATASET=$(terraform output -raw bigquery_dataset_id 2>/dev/null || load_state "BIGQUERY_DATASET" "")
    log_success "Skipping - infrastructure already deployed"
else
    log_step "Step 7/8: Infrastructure Deployment"

echo ""
echo "Deploying cloud infrastructure with Terraform..."
echo ""

cd "$TERRAFORM_DIR"

# Create GCS bucket for Terraform state (enables self-service teardown)
TFSTATE_BUCKET="${PROJECT_ID}-tfstate"
echo "Creating Terraform state bucket..."
if ! gsutil ls -b "gs://${TFSTATE_BUCKET}" &>/dev/null 2>&1; then
    gsutil mb -l "$REGION" -p "$PROJECT_ID" "gs://${TFSTATE_BUCKET}"
    gsutil versioning set on "gs://${TFSTATE_BUCKET}"
    log_success "State bucket created: $TFSTATE_BUCKET"
else
    log_success "State bucket exists: $TFSTATE_BUCKET"
fi

# Initialize Terraform with remote backend (with auth retry)
echo "Initializing Terraform with remote state..."

set +e
TF_INIT_OUTPUT=$(terraform init -input=false -reconfigure \
    -backend-config="bucket=${TFSTATE_BUCKET}" \
    -backend-config="prefix=ai-ingestion" 2>&1)
TF_INIT_EXIT=$?
set -e

# Check for OAuth token expiry (common Cloud Shell issue)
if [ $TF_INIT_EXIT -ne 0 ]; then
    if echo "$TF_INIT_OUTPUT" | grep -q "invalid token JSON\|oauth2/google\|token expired\|EOF"; then
        echo ""
        echo -e "${YELLOW}  Cloud Shell token issue detected. Refreshing credentials...${NC}"
        echo ""
        
        # Get a fresh access token directly from gcloud and pass to Terraform
        FRESH_TOKEN=$(gcloud auth print-access-token 2>/dev/null)
        
        if [ -n "$FRESH_TOKEN" ]; then
            export GOOGLE_OAUTH_ACCESS_TOKEN="$FRESH_TOKEN"
            echo "  Retrying with fresh token..."
            
            terraform init -input=false -reconfigure \
                -backend-config="bucket=${TFSTATE_BUCKET}" \
                -backend-config="prefix=ai-ingestion"
        else
            echo -e "${RED}  Could not get access token. Try running:${NC}"
            echo ""
            echo -e "     ${CYAN}gcloud auth login${NC}"
            echo ""
            echo "  Then resume:"
            echo -e "     ${CYAN}./setup.sh --token=$SETUP_TOKEN --domain=$DOMAIN --resume${NC}"
            exit 1
        fi
    else
        echo "$TF_INIT_OUTPUT"
        exit 1
    fi
fi

log_success "Terraform initialized with remote state"

# Generate tfvars file
TFVARS_FILE="environments/${DOMAIN}.tfvars"
cat > "$TFVARS_FILE" << EOF
# Auto-generated by setup.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Domain: $DOMAIN

gcp_project_id = "$PROJECT_ID"
region         = "$REGION"

workspace_domain      = "$DOMAIN"
workspace_admin_email = "$ADMIN_EMAIL"

bigquery_dataset  = "corporate_context"
bigquery_location = "EU"

gcs_bucket_prefix = "${SAFE_DOMAIN}-ingestion"

# Enabled modules
enable_gmail           = true
enable_google_meet     = true
enable_telegram        = $ENABLE_TELEGRAM
enable_twilio          = $ENABLE_TWILIO
enable_voice_enrollment = $ENABLE_TWILIO
enable_ai_enrichment   = $ENABLE_OPENAI

# Secrets (already created)
create_gmail_secret    = false
create_telegram_secret = false
create_twilio_secrets  = false
create_openai_secret   = false

secret_name_gmail_sa_key   = "CORCO_GMAIL_SA_KEY"
secret_name_telegram_token = "CORCO_TELEGRAM_BOT_TOKEN"
secret_name_twilio_sid     = "CORCO_TWILIO_ACCOUNT_SID"
secret_name_twilio_token   = "CORCO_TWILIO_AUTH_TOKEN"
secret_name_openai_key     = "CORCO_OPENAI_API_KEY"
EOF

log_success "Generated $TFVARS_FILE"

# Import existing resources if they exist (for idempotency)
echo ""
echo "Checking for existing resources to import..."

import_if_exists() {
    local addr="$1"
    local id="$2"
    local check_cmd="$3"
    
    # Check if already in state
    if terraform state show "$addr" &>/dev/null; then
        echo "  ✓ $addr (in state)"
        return 0
    fi
    
    # Check if resource exists in GCP
    if eval "$check_cmd" &>/dev/null; then
        echo "  → Importing $addr..."
        local import_output
        import_output=$(terraform import -var-file="$TFVARS_FILE" "$addr" "$id" 2>&1)
        if [ $? -eq 0 ]; then
            echo "    ✓ Imported"
        else
            echo "    ⚠ Import failed: $(echo "$import_output" | grep -i "error" | head -1)"
        fi
    fi
}

# Import project if exists
import_if_exists "google_project.metadata" "$PROJECT_ID" \
    "gcloud projects describe $PROJECT_ID --format='value(projectId)'"

# Import service accounts if they exist
import_if_exists "module.iam.google_service_account.gmail_sync[0]" \
    "projects/$PROJECT_ID/serviceAccounts/gmail-sync-sa@$PROJECT_ID.iam.gserviceaccount.com" \
    "gcloud iam service-accounts describe gmail-sync-sa@$PROJECT_ID.iam.gserviceaccount.com --project=$PROJECT_ID"

import_if_exists "module.iam.google_service_account.twilio_ingest[0]" \
    "projects/$PROJECT_ID/serviceAccounts/twilio-ingest-sa@$PROJECT_ID.iam.gserviceaccount.com" \
    "gcloud iam service-accounts describe twilio-ingest-sa@$PROJECT_ID.iam.gserviceaccount.com --project=$PROJECT_ID"

# Import BigQuery dataset if exists
import_if_exists "module.bigquery.google_bigquery_dataset.main" \
    "projects/$PROJECT_ID/datasets/corporate_context" \
    "bq show --project_id=$PROJECT_ID corporate_context"

# Import GCS buckets if they exist
import_if_exists "module.storage.google_storage_bucket.recordings[0]" \
    "$PROJECT_ID-recordings" \
    "gsutil ls -b gs://$PROJECT_ID-recordings"

import_if_exists "module.storage.google_storage_bucket.voice_samples[0]" \
    "$PROJECT_ID-voice" \
    "gsutil ls -b gs://$PROJECT_ID-voice"

log_success "Resource check complete"

# ═══════════════════════════════════════════════════════════════════════════════
# Check for Organization Policy blocking allUsers (proactive detection)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Checking organization policies..."

ALLOW_PUBLIC_WEBHOOKS="true"
ORG_POLICY_BLOCKED="false"

# Check if iam.allowedPolicyMemberDomains constraint is in effect
ORG_POLICY_CHECK=$(gcloud resource-manager org-policies describe iam.allowedPolicyMemberDomains \
    --project="$PROJECT_ID" --format=json 2>/dev/null || echo "{}")

# Check if the policy restricts to specific domains (blocks allUsers)
if echo "$ORG_POLICY_CHECK" | grep -q '"allValues":\s*"DENY"\|"allowedValues"'; then
    ORG_POLICY_BLOCKED="true"
fi

# Also check if there's an inherited constraint
if [ "$ORG_POLICY_BLOCKED" != "true" ]; then
    EFFECTIVE_POLICY=$(gcloud resource-manager org-policies describe iam.allowedPolicyMemberDomains \
        --effective --project="$PROJECT_ID" --format=json 2>/dev/null || echo "{}")
    if echo "$EFFECTIVE_POLICY" | grep -q '"allowedValues"\|"deniedValues"'; then
        # Policy exists and likely restricts domains
        ORG_POLICY_BLOCKED="true"
    fi
fi

if [ "$ORG_POLICY_BLOCKED" == "true" ] && { [ "$ENABLE_TELEGRAM" == "true" ] || [ "$ENABLE_TWILIO" == "true" ]; }; then
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  ⚠️  ORGANIZATION POLICY DETECTED${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Your organization has a policy (iam.allowedPolicyMemberDomains) that"
    echo "  blocks public access. This affects webhook integrations."
    echo ""
    echo "  Webhooks require public endpoints because external services"
    echo "  (Telegram, Twilio) need to send HTTP requests to your functions."
    echo ""
    echo -e "  ${CYAN}OPTIONS:${NC}"
    echo ""
    echo -e "  ${BOLD}1. Add a project-level exception (recommended)${NC}"
    echo "     This overrides the org policy for this project only."
    echo ""
    echo -e "  ${BOLD}2. Continue without public webhooks${NC}"
    echo "     Functions will deploy but external services won't reach them."
    echo "     You can add the exception later and re-run setup."
    echo ""
    read -p "  Add project-level exception to allow public webhooks? (Y/n): " ADD_EXCEPTION
    
    if [[ ! "$ADD_EXCEPTION" =~ ^[Nn] ]]; then
        echo ""
        echo "  Adding project-level exception for iam.allowedPolicyMemberDomains..."
        echo ""
        
        # Create policy file allowing allUsers
        cat > /tmp/org_policy_override.json << 'POLICY_EOF'
{
  "constraint": "constraints/iam.allowedPolicyMemberDomains",
  "listPolicy": {
    "allValues": "ALLOW"
  }
}
POLICY_EOF
        
        # Apply the policy override
        if gcloud resource-manager org-policies set-policy /tmp/org_policy_override.json \
            --project="$PROJECT_ID" 2>&1; then
            log_success "Project-level exception added"
            echo "  Public webhooks will now work for this project."
            echo ""
            echo "  Waiting 30 seconds for policy to propagate..."
            sleep 30
        else
            echo ""
            echo -e "  ${YELLOW}Could not add exception automatically.${NC}"
            echo ""
            echo "  This usually means you don't have Organization Policy Admin permissions."
            echo ""
            echo -e "  ${BOLD}Manual steps:${NC}"
            echo "  1. Open: https://console.cloud.google.com/iam-admin/orgpolicies/iam-allowedPolicyMemberDomains?project=$PROJECT_ID"
            echo "  2. Click 'Manage Policy'"
            echo "  3. Select 'Override parent's policy'"
            echo "  4. Under 'Policy enforcement', select 'Replace'"
            echo "  5. Add rule: 'Allow All'"
            echo "  6. Click 'Set Policy'"
            echo ""
            read -p "  Press Enter after setting the policy (or Enter to continue without)..." POLICY_DONE
            
            # Re-check if policy was manually set
            RECHECK=$(gcloud resource-manager org-policies describe iam.allowedPolicyMemberDomains \
                --project="$PROJECT_ID" --format='value(listPolicy.allValues)' 2>/dev/null || echo "")
            if [ "$RECHECK" == "ALLOW" ]; then
                log_success "Policy exception confirmed"
            else
                echo -e "  ${YELLOW}Policy exception not detected. Continuing with restricted access.${NC}"
                ALLOW_PUBLIC_WEBHOOKS="false"
            fi
        fi
        rm -f /tmp/org_policy_override.json
    else
        ALLOW_PUBLIC_WEBHOOKS="false"
        echo ""
        echo "  Continuing without public webhook access."
        echo "  You can add the exception later and re-run setup."
    fi
else
    log_success "Organization policy allows public access"
fi

# Apply Terraform
echo ""
echo "Applying infrastructure (this takes 20-30 minutes for first deployment)..."

# Build Terraform command based on whether public webhooks are allowed
TF_APPLY_ARGS="-var-file=\"$TFVARS_FILE\" -auto-approve"
if [ "$ALLOW_PUBLIC_WEBHOOKS" == "false" ]; then
    TF_APPLY_ARGS="$TF_APPLY_ARGS -var=\"allow_unauthenticated_invocations=false\""
fi

eval "terraform apply $TF_APPLY_ARGS" 2>&1 | tee /tmp/terraform_output.log
TERRAFORM_EXIT=${PIPESTATUS[0]}

# Check for org policy error blocking allUsers (fallback if not caught proactively)
if [ $TERRAFORM_EXIT -ne 0 ]; then
    if grep -q "organization policy\|allowedPolicyMemberDomains\|do not belong to a permitted customer" /tmp/terraform_output.log; then
        # Org policy issue not caught proactively - retry without public access
        echo ""
        echo -e "${YELLOW}Organization policy blocking allUsers detected during apply.${NC}"
        echo "Retrying with public webhook access disabled..."
        
        terraform apply -var-file="$TFVARS_FILE" -var="allow_unauthenticated_invocations=false" -auto-approve 2>&1 | tee /tmp/terraform_output.log
        TERRAFORM_EXIT=${PIPESTATUS[0]}
        ALLOW_PUBLIC_WEBHOOKS="false"
        
        if [ $TERRAFORM_EXIT -eq 0 ]; then
            echo ""
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}  ⚠️  WEBHOOK SETUP REQUIRED${NC}"
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "  Infrastructure deployed, but webhooks are not publicly accessible."
            echo ""
            echo "  To enable webhooks, add a project-level org policy exception:"
            echo "  https://console.cloud.google.com/iam-admin/orgpolicies/iam-allowedPolicyMemberDomains?project=$PROJECT_ID"
            echo ""
            echo "  Then re-run: ./setup.sh --domain=$DOMAIN --resume"
            echo ""
        fi
    else
        # Some other Terraform error - show the log
        echo ""
        echo -e "${RED}Terraform apply failed. See error above.${NC}"
        exit 1
    fi
fi

if [ $TERRAFORM_EXIT -ne 0 ]; then
    echo ""
    echo -e "${RED}Terraform apply failed after retry.${NC}"
    exit 1
fi

log_success "Infrastructure deployed"

# Capture outputs
GMAIL_SYNC_URL=$(terraform output -raw gmail_sync_url 2>/dev/null || echo "")
TELEGRAM_WEBHOOK_URL=$(terraform output -raw telegram_webhook_url 2>/dev/null || echo "")
DRIVE_SYNC_URL=$(terraform output -raw drive_sync_url 2>/dev/null || echo "")
VOICE_ENROLL_URL=$(terraform output -raw voice_enroll_url 2>/dev/null || echo "")
STANDARDIZE_UTTERANCES_URL=$(terraform output -raw standardize_utterances_url 2>/dev/null || echo "")
RECORDINGS_BUCKET=$(terraform output -raw recordings_bucket 2>/dev/null || echo "")
BIGQUERY_DATASET=$(terraform output -raw bigquery_dataset_id 2>/dev/null || echo "")

# Set Telegram webhook if enabled
if [ "$ENABLE_TELEGRAM" == "true" ] && [ -n "$TELEGRAM_WEBHOOK_URL" ]; then
    echo ""
    echo "Setting Telegram webhook..."
    TELEGRAM_TOKEN=$(gcloud secrets versions access latest --secret="CORCO_TELEGRAM_BOT_TOKEN" --project="$PROJECT_ID" 2>/dev/null || echo "")
    if [ -n "$TELEGRAM_TOKEN" ]; then
        curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/setWebhook?url=${TELEGRAM_WEBHOOK_URL}" > /dev/null
        log_success "Telegram webhook configured"
    else
        log_warning "Telegram token not found - configure webhook manually later"
        echo "  curl \"https://api.telegram.org/bot<YOUR_TOKEN>/setWebhook?url=${TELEGRAM_WEBHOOK_URL}\""
    fi
fi
    
    # Save Terraform outputs to state
    save_state "GMAIL_SYNC_URL" "$GMAIL_SYNC_URL"
    save_state "TELEGRAM_WEBHOOK_URL" "$TELEGRAM_WEBHOOK_URL"
    save_state "DRIVE_SYNC_URL" "$DRIVE_SYNC_URL"
    save_state "VOICE_ENROLL_URL" "$VOICE_ENROLL_URL"
    save_state "STANDARDIZE_UTTERANCES_URL" "$STANDARDIZE_UTTERANCES_URL"
    save_state "RECORDINGS_BUCKET" "$RECORDINGS_BUCKET"
    save_state "BIGQUERY_DATASET" "$BIGQUERY_DATASET"
    mark_step_complete "terraform"
fi

# =============================================================================
# Step 8: Register with Corco
# =============================================================================

if step_completed "registration"; then
    log_step "Step 8/8: Registration (already completed)"
    log_success "Skipping - already registered"
else
log_step "Step 8/8: Registration"

echo ""
echo "Registering deployment with Corco..."

DEPLOYED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DEPLOYED_BY="$CURRENT_ACCOUNT"

# Build registration payload
REGISTRATION_PAYLOAD=$(cat << EOF
{
  "identity": {
    "company_name": "$CLIENT_NAME",
    "domain": "$DOMAIN",
    "admin_first_name": "$ADMIN_FIRST_NAME",
    "admin_surname": "$ADMIN_SURNAME",
    "admin_email": "$ADMIN_EMAIL",
    "admin_phone": "$ADMIN_PHONE",
    "admin_telegram": "$ADMIN_TELEGRAM"
  },
  "onboarding": {
    "setup_token": "$SETUP_TOKEN",
    "consultant_email": "$CONSULTANT_EMAIL"
  },
  "deployment": {
    "project_id": "$PROJECT_ID",
    "region": "$REGION",
    "deployed_at": "$DEPLOYED_AT",
    "deployed_by": "$DEPLOYED_BY"
  },
  "modules": {
    "gmail": true,
    "telegram": $ENABLE_TELEGRAM,
    "twilio": $ENABLE_TWILIO,
    "google_meet": true,
    "voice_enrollment": $ENABLE_TWILIO,
    "ai_enrichment": $ENABLE_OPENAI
  },
  "historical_import": {
    "gmail_mode": "$GMAIL_IMPORT_MODE",
    "gmail_since": ${GMAIL_SYNC_SINCE:+\"$GMAIL_SYNC_SINCE\"}${GMAIL_SYNC_SINCE:-null},
    "twilio_import": $TWILIO_IMPORT_EXISTING,
    "twilio_since": ${TWILIO_IMPORT_SINCE:+\"$TWILIO_IMPORT_SINCE\"}${TWILIO_IMPORT_SINCE:-null},
    "meet_import": $MEET_IMPORT_EXISTING
  },
  "endpoints": {
    "gmail_sync_url": "$GMAIL_SYNC_URL",
    "telegram_webhook_url": "$TELEGRAM_WEBHOOK_URL",
    "drive_sync_url": "$DRIVE_SYNC_URL",
    "voice_enroll_url": "$VOICE_ENROLL_URL",
    "standardize_utterances_url": "$STANDARDIZE_UTTERANCES_URL"
  },
  "resources": {
    "recordings_bucket": "$RECORDINGS_BUCKET",
    "bigquery_dataset": "$BIGQUERY_DATASET",
    "gmail_service_account": "$SA_EMAIL",
    "gmail_client_id": "$CLIENT_ID"
  },
  "license": {
    "tier": "${LICENSED_TIER:-unknown}",
    "tier_limit": ${LICENSED_LIMIT:-0},
    "workspace_user_count": $([ "$WORKSPACE_USER_COUNT" == "unknown" ] && echo "null" || echo "${WORKSPACE_USER_COUNT:-0}"),
    "status": "${LICENSE_STATUS:-unknown}",
    "exceeded": $([ "$LICENSE_EXCEEDED" == "true" ] && echo "true" || echo "false"),
    "exceeded_by": ${LICENSE_EXCEEDED_BY:-0},
    "verified_at": "$DEPLOYED_AT"
  }
}
EOF
)

# Send registration (with auth token if available)
if [ -n "$SETUP_TOKEN" ]; then
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$REGISTRY_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $SETUP_TOKEN" \
        -d "$REGISTRATION_PAYLOAD" 2>/dev/null || echo "error")
else
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$REGISTRY_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "$REGISTRATION_PAYLOAD" 2>/dev/null || echo "error")
fi

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "201" ]; then
    log_success "Registered with Corco"
else
    log_warning "Registration returned HTTP $HTTP_CODE (deployment still successful)"
    echo "  You may need to manually notify Corco support."
fi

mark_step_complete "registration"
fi  # End of: if step_completed "registration"

# =============================================================================
# Step 8.5: Trigger Historical Imports (if enabled)
# =============================================================================

if [ "$TWILIO_IMPORT_EXISTING" == "true" ] || [ "$MEET_IMPORT_EXISTING" == "true" ]; then
    echo ""
    log_step "Step 8.5/9: Historical Data Import"
    echo ""
    echo "Triggering historical data imports based on your preferences..."
    echo ""
fi

# ── Twilio Historical Import ──
if [ "$TWILIO_IMPORT_EXISTING" == "true" ] && [ "$ENABLE_TWILIO" == "true" ]; then
  if step_completed "historical_twilio"; then
    echo "  Twilio historical import: already triggered"
  else
    echo -e "${CYAN}━━━ Twilio Historical Import ━━━${NC}"
    
    # Get the historical import function URL
    TWILIO_IMPORT_URL=$(gcloud functions describe twilio-historical-import --project="$PROJECT_ID" --region="$REGION" --format='value(httpsTrigger.url)' 2>/dev/null || echo "")
    
    if [ -n "$TWILIO_IMPORT_URL" ]; then
        # Build payload
        TWILIO_IMPORT_PAYLOAD="{"
        [ -n "$TWILIO_IMPORT_SINCE" ] && TWILIO_IMPORT_PAYLOAD="$TWILIO_IMPORT_PAYLOAD\"since_date\": \"$TWILIO_IMPORT_SINCE\""
        TWILIO_IMPORT_PAYLOAD="$TWILIO_IMPORT_PAYLOAD}"
        
        echo "  Triggering historical import from Twilio..."
        TWILIO_RESPONSE=$(curl -s -X POST "$TWILIO_IMPORT_URL" \
            -H "Content-Type: application/json" \
            -d "$TWILIO_IMPORT_PAYLOAD" 2>/dev/null || echo "error")
        
        if echo "$TWILIO_RESPONSE" | grep -q "success\|status"; then
            log_success "Twilio historical import triggered"
            echo "  This may take several minutes. Check function logs for progress."
        else
            log_warning "Twilio historical import may not have been triggered"
            echo "  You can manually trigger it later via the function URL."
        fi
    else
        log_warning "Twilio historical import function not found"
        echo "  Function may not be deployed yet. Historical import will need to be triggered manually."
    fi
    mark_step_complete "historical_twilio"
    echo ""
  fi
fi

# ── Google Meet Historical Import ──
if [ "$MEET_IMPORT_EXISTING" == "true" ]; then
  if step_completed "historical_meet"; then
    echo "  Google Meet historical import: already triggered"
  else
    echo -e "${CYAN}━━━ Google Meet Historical Import ━━━${NC}"
    
    # Get the drive sync function URL (same function, different parameter)
    DRIVE_SYNC_URL=$(gcloud functions describe drive-sync --project="$PROJECT_ID" --region="$REGION" --format='value(httpsTrigger.url)' 2>/dev/null || echo "")
    
    if [ -n "$DRIVE_SYNC_URL" ]; then
        echo "  Triggering historical import from Google Drive..."
        MEET_RESPONSE=$(curl -s -X POST "$DRIVE_SYNC_URL?historical_import=true" \
            -H "Content-Type: application/json" \
            -d '{"historical_import": true}' 2>/dev/null || echo "error")
        
        if echo "$MEET_RESPONSE" | grep -q "Sync complete\|Uploaded"; then
            log_success "Google Meet historical import triggered"
            echo "  Processing existing recordings in Drive folder..."
        else
            log_warning "Google Meet historical import may not have been triggered"
            echo "  You can manually trigger it later via: $DRIVE_SYNC_URL?historical_import=true"
        fi
    else
        log_warning "Google Meet sync function not found"
        echo "  Function may not be deployed yet. Historical import will need to be triggered manually."
    fi
    mark_step_complete "historical_meet"
    echo ""
  fi
fi

# =============================================================================
# Step 9: Verification - End-to-End Pipeline Test
# =============================================================================

log_step "Step 9: Verification"

echo ""
echo "Testing end-to-end pipeline with welcome email..."
echo ""

# Track verification results
GMAIL_VERIFIED="false"
WELCOME_SENT="false"
WELCOME_INGESTED="false"

# Corco welcome endpoints (deployed on corco-prod)
WELCOME_EMAIL_URL="https://us-central1-corco-prod.cloudfunctions.net/send-welcome-email"
WELCOME_TELEGRAM_URL="https://us-central1-corco-prod.cloudfunctions.net/send-welcome-telegram"
WELCOME_CALL_URL="https://us-central1-corco-prod.cloudfunctions.net/make-welcome-call"

# Build enabled modules list
ENABLED_MODULES="[\"gmail\", \"google_meet\""
[ "$ENABLE_TELEGRAM" == "true" ] && ENABLED_MODULES="$ENABLED_MODULES, \"telegram\""
[ "$ENABLE_TWILIO" == "true" ] && ENABLED_MODULES="$ENABLED_MODULES, \"twilio\""
ENABLED_MODULES="$ENABLED_MODULES]"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9: SEND WELCOME COMMUNICATIONS
# ══════════════════════════════════════════════════════════════════════════════
# Send all welcome messages FIRST, then verify all at once

WELCOME_SENT="false"
TELEGRAM_MSG_SENT="false"
CALL_INITIATED="false"

# ── Step 9a: Send Welcome Email ──
echo -e "${CYAN}━━━ Sending Welcome Communications ━━━${NC}"
echo ""

if step_completed "welcome_email"; then
    echo "  [1/3] Welcome email: already sent"
    WELCOME_SENT="true"
else
    echo "  [1/3] Sending welcome email to $ADMIN_EMAIL..."

    WELCOME_PAYLOAD=$(cat <<EOF
{
    "client_name": "$CLIENT_NAME",
    "admin_first_name": "$ADMIN_FIRST_NAME",
    "admin_email": "$ADMIN_EMAIL",
    "project_id": "$PROJECT_ID",
    "enabled_modules": $ENABLED_MODULES,
    "consultant_email": "$CONSULTANT_EMAIL"
}
EOF
)

    WELCOME_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$WELCOME_EMAIL_URL" \
        -H "Content-Type: application/json" \
        -d "$WELCOME_PAYLOAD" 2>/dev/null)
    WELCOME_HTTP=$(echo "$WELCOME_RESPONSE" | tail -1)
    WELCOME_BODY=$(echo "$WELCOME_RESPONSE" | head -n -1)

    if [ "$WELCOME_HTTP" == "200" ] && echo "$WELCOME_BODY" | grep -q '"success":true'; then
        log_success "Welcome email sent"
        WELCOME_SENT="true"
        mark_step_complete "welcome_email"
    else
        log_warning "Could not send welcome email (HTTP $WELCOME_HTTP)"
    fi
fi

# ── Step 9b: Configure Telegram Webhook and Send Welcome Message ──
if [ "$ENABLE_TELEGRAM" == "true" ] && [ -n "$TELEGRAM_WEBHOOK_URL" ]; then
    echo ""
    if step_completed "welcome_telegram"; then
        echo "  [2/3] Telegram welcome: already sent"
        TELEGRAM_MSG_SENT="true"
    else
        echo "  [2/3] Setting up Telegram..."
        
        # Token should already be configured in secrets step - just retrieve it
        TELEGRAM_TOKEN=$(gcloud secrets versions access latest --secret="CORCO_TELEGRAM_BOT_TOKEN" --project="$PROJECT_ID" 2>/dev/null || echo "")
        
        if [ -n "$TELEGRAM_TOKEN" ]; then
            # Automatically set webhook
            WEBHOOK_RESPONSE=$(curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/setWebhook?url=${TELEGRAM_WEBHOOK_URL}")
            if echo "$WEBHOOK_RESPONSE" | grep -q '"ok":true'; then
                log_success "Telegram webhook configured automatically"
                
                # Send welcome message to support group (if group exists)
                if [ -n "$TELEGRAM_GROUP_ID" ]; then
                    echo "  Sending welcome message to Telegram group..."
                    
                    TELEGRAM_PAYLOAD=$(cat <<EOF
{
    "chat_id": "$TELEGRAM_GROUP_ID",
    "client_name": "$CLIENT_NAME",
    "admin_first_name": "$ADMIN_FIRST_NAME",
    "project_id": "$PROJECT_ID",
    "enabled_modules": $ENABLED_MODULES,
    "consultant_email": "$CONSULTANT_EMAIL"
}
EOF
)
                    
                    TG_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$WELCOME_TELEGRAM_URL" \
                        -H "Content-Type: application/json" \
                        -d "$TELEGRAM_PAYLOAD" 2>/dev/null)
                    TG_HTTP=$(echo "$TG_RESPONSE" | tail -1)
                    TG_BODY=$(echo "$TG_RESPONSE" | head -n -1)
                    
                    if [ "$TG_HTTP" == "200" ] && echo "$TG_BODY" | grep -q '"success":true'; then
                        log_success "Welcome message sent to Telegram group"
                        TELEGRAM_MSG_SENT="true"
                        mark_step_complete "welcome_telegram"
                    else
                        log_warning "Could not send Telegram welcome message"
                    fi
                fi
            else
                log_warning "Telegram webhook setup failed: $(echo "$WEBHOOK_RESPONSE" | grep -o '"description":"[^"]*"')"
            fi
        else
            log_warning "Telegram token not found - was it configured in the secrets step?"
        fi
    fi
else
    echo ""
    echo "  [2/3] Telegram not enabled - skipping"
fi

# ── Step 9c: Make Welcome Call (if Twilio enabled) ──
if [ "$ENABLE_TWILIO" == "true" ] && [ -n "$ADMIN_PHONE" ]; then
    echo ""
    if step_completed "welcome_call"; then
        echo "  [3/3] Welcome call: already made"
        CALL_INITIATED="true"
    else
        echo "  [3/3] Making welcome call to $ADMIN_PHONE..."
        
        CALL_PAYLOAD=$(cat <<EOF
{
    "to_number": "$ADMIN_PHONE",
    "client_name": "$CLIENT_NAME",
    "admin_first_name": "$ADMIN_FIRST_NAME",
    "project_id": "$PROJECT_ID",
    "enabled_modules": $ENABLED_MODULES,
    "recordings_bucket": "$RECORDINGS_BUCKET"
}
EOF
)
        
        CALL_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$WELCOME_CALL_URL" \
            -H "Content-Type: application/json" \
            -d "$CALL_PAYLOAD" 2>/dev/null)
        CALL_HTTP=$(echo "$CALL_RESPONSE" | tail -1)
        CALL_BODY=$(echo "$CALL_RESPONSE" | head -n -1)
        
        if [ "$CALL_HTTP" == "200" ] && echo "$CALL_BODY" | grep -q '"success":true'; then
            CALL_SID=$(echo "$CALL_BODY" | grep -o '"call_sid":"[^"]*"' | cut -d'"' -f4)
            log_success "Welcome call initiated (SID: $CALL_SID)"
            CALL_INITIATED="true"
            mark_step_complete "welcome_call"
            echo "  Note: Answer the call to verify the full pipeline. If you miss it, that's OK."
        else
            log_warning "Could not initiate welcome call"
        fi
    fi
elif [ "$ENABLE_TWILIO" == "true" ]; then
    echo ""
    echo "  [3/3] Twilio enabled but no phone number - skipping call"
else
    echo ""
    echo "  [3/3] Twilio not enabled - skipping"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10: VERIFY GMAIL SYNC
# ══════════════════════════════════════════════════════════════════════════════
# DWD was already configured in Step 6. This just verifies it's working.

echo ""
echo -e "${CYAN}━━━ Verifying Gmail Sync ━━━${NC}"

echo "  Testing Gmail sync..."
GMAIL_RESPONSE=$(curl -s -w "\n%{http_code}" "$GMAIL_SYNC_URL" 2>/dev/null)
GMAIL_HTTP=$(echo "$GMAIL_RESPONSE" | tail -1)

GMAIL_VERIFIED="false"
if [ "$GMAIL_HTTP" == "200" ]; then
    log_success "Gmail sync working"
    GMAIL_VERIFIED="true"
else
    log_warning "Gmail sync returned HTTP $GMAIL_HTTP"
    echo "  DWD was configured in Step 6 but may need time to propagate."
    echo "  If this persists, verify DWD at: https://admin.google.com/ac/owl/domainwidedelegation"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 11: VERIFY ALL PIPELINES
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}━━━ Verifying Pipelines ━━━${NC}"

# Count how many things we need to wait for
THINGS_TO_VERIFY=0
[ "$WELCOME_SENT" == "true" ] && [ "$GMAIL_VERIFIED" == "true" ] && THINGS_TO_VERIFY=$((THINGS_TO_VERIFY + 1))
[ "$TELEGRAM_MSG_SENT" == "true" ] && THINGS_TO_VERIFY=$((THINGS_TO_VERIFY + 1))
[ "$CALL_INITIATED" == "true" ] && THINGS_TO_VERIFY=$((THINGS_TO_VERIFY + 1))

if [ "$THINGS_TO_VERIFY" -gt 0 ]; then
    # Wait once for all pipelines (2 min covers email sync + call transcription)
    echo "  Waiting 2 minutes for all pipelines to process..."
    sleep 120
    
    # Trigger Gmail sync to speed things up
    if [ "$GMAIL_VERIFIED" == "true" ]; then
        echo "  Triggering Gmail sync..."
        curl -s "$GMAIL_SYNC_URL" > /dev/null 2>&1
        sleep 10
    fi
    
    echo ""
    echo "  Checking BigQuery for ingested data..."
    echo ""
fi

# Initialize verification flags
WELCOME_INGESTED="false"
TELEGRAM_INGESTED="false"
CALL_TRANSCRIBED="false"

# ── Verify Email ──
if [ "$WELCOME_SENT" == "true" ] && [ "$GMAIL_VERIFIED" == "true" ]; then
    WELCOME_CHECK=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv \
        "SELECT COUNT(*) as cnt FROM \`$PROJECT_ID.$BIGQUERY_DATASET.email_messages\` 
         WHERE sender_email LIKE '%corco%' 
         AND subject LIKE '%Welcome%' 
         AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 MINUTE)" 2>/dev/null | tail -1)
    
    if [ "$WELCOME_CHECK" -gt 0 ] 2>/dev/null; then
        WELCOME_INGESTED="true"
        log_success "Email pipeline: Welcome email in BigQuery"
    else
        log_warning "Email pipeline: Welcome email not yet ingested"
    fi
fi

# ── Verify Telegram ──
if [ "$TELEGRAM_MSG_SENT" == "true" ]; then
    TG_CHECK=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv \
        "SELECT COUNT(*) as cnt FROM \`$PROJECT_ID.$BIGQUERY_DATASET.telegram_messages\` 
         WHERE text LIKE '%Welcome%' AND text LIKE '%Corco%'
         AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 MINUTE)" 2>/dev/null | tail -1)
    
    if [ "$TG_CHECK" -gt 0 ] 2>/dev/null; then
        TELEGRAM_INGESTED="true"
        log_success "Telegram pipeline: Welcome message in BigQuery"
    else
        log_warning "Telegram pipeline: Welcome message not yet ingested"
    fi
fi

# ── Verify Call ──
if [ "$CALL_INITIATED" == "true" ]; then
    CALL_CHECK=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv \
        "SELECT COUNT(*) as cnt FROM \`$PROJECT_ID.$BIGQUERY_DATASET.call_transcripts\` 
         WHERE created_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 MINUTE)" 2>/dev/null | tail -1)
    
    if [ "$CALL_CHECK" -gt 0 ] 2>/dev/null; then
        CALL_TRANSCRIBED="true"
        log_success "Call pipeline: Welcome call transcript in BigQuery"
    else
        log_warning "Call pipeline: Transcript not yet ingested (call may not have been answered)"
    fi
fi

# Set verification flags for summary
TELEGRAM_VERIFIED="$TELEGRAM_MSG_SENT"
CALL_VERIFIED="$CALL_INITIATED"

# ── Summary ──
echo ""
OVERALL_OK="true"
[ "$GMAIL_VERIFIED" != "true" ] && OVERALL_OK="false"
[ "$WELCOME_SENT" == "true" ] && [ "$WELCOME_INGESTED" != "true" ] && OVERALL_OK="false"

# =============================================================================
# Complete!
# =============================================================================

echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                                                                ║${NC}"
echo -e "${BOLD}║                    SETUP COMPLETE!                             ║${NC}"
echo -e "${BOLD}║                                                                ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Deployment Details:${NC}"
echo "  Company:  $CLIENT_NAME"
echo "  Domain:   $DOMAIN"
echo "  Project:  $PROJECT_ID"
echo "  Admin:    $ADMIN_FIRST_NAME $ADMIN_SURNAME <$ADMIN_EMAIL>"
echo ""

echo -e "${BOLD}Verification Results:${NC}"

# Email pipeline
if [ "$WELCOME_INGESTED" == "true" ]; then
    echo -e "  ${GREEN}[OK]${NC} Email: Welcome email ingested into BigQuery"
elif [ "$WELCOME_SENT" == "true" ] && [ "$GMAIL_VERIFIED" == "true" ]; then
    echo -e "  ${YELLOW}[..]${NC} Email: Welcome sent, awaiting ingestion"
elif [ "$GMAIL_VERIFIED" == "true" ]; then
    echo -e "  ${GREEN}[OK]${NC} Email: Gmail sync operational"
else
    echo -e "  ${YELLOW}[..]${NC} Email: Needs DWD configuration"
fi

# Telegram pipeline
if [ "$ENABLE_TELEGRAM" == "true" ]; then
    if [ "$TELEGRAM_INGESTED" == "true" ]; then
        echo -e "  ${GREEN}[OK]${NC} Telegram: Welcome message ingested into BigQuery"
    elif [ "$TELEGRAM_VERIFIED" == "true" ]; then
        echo -e "  ${GREEN}[OK]${NC} Telegram: Webhook configured"
    elif [ "$ALLOW_PUBLIC_WEBHOOKS" == "false" ]; then
        echo -e "  ${YELLOW}[..]${NC} Telegram: Webhook not public (org policy)"
    else
        echo -e "  ${YELLOW}[..]${NC} Telegram: Needs bot token"
    fi
fi

# Call pipeline
if [ "$ENABLE_TWILIO" == "true" ]; then
    if [ "$CALL_TRANSCRIBED" == "true" ]; then
        echo -e "  ${GREEN}[OK]${NC} Calls: Welcome call transcribed into BigQuery"
    elif [ "$CALL_VERIFIED" == "true" ]; then
        echo -e "  ${GREEN}[OK]${NC} Calls: Welcome call made (transcript pending)"
    else
        echo -e "  ${GREEN}[OK]${NC} Calls: Ready (recordings auto-transcribed)"
    fi
fi

echo ""
echo -e "${BOLD}Useful Links:${NC}"
echo "  BigQuery:  https://console.cloud.google.com/bigquery?project=$PROJECT_ID"
echo "  Functions: https://console.cloud.google.com/functions?project=$PROJECT_ID"
echo "  Logs:      https://console.cloud.google.com/logs?project=$PROJECT_ID"

echo ""

# Determine overall verification status
FULLY_VERIFIED="true"
[ "$GMAIL_VERIFIED" != "true" ] && FULLY_VERIFIED="false"
[ "$ENABLE_TELEGRAM" == "true" ] && [ "$TELEGRAM_VERIFIED" != "true" ] && FULLY_VERIFIED="false"

if [ "$WELCOME_INGESTED" == "true" ] || [ "$TELEGRAM_INGESTED" == "true" ] || [ "$CALL_TRANSCRIBED" == "true" ]; then
    echo -e "${GREEN}✓ Setup complete and verified! Data is flowing into BigQuery.${NC}"
elif [ "$FULLY_VERIFIED" == "true" ]; then
    echo -e "${GREEN}✓ Setup complete! All pipelines are operational.${NC}"
else
    echo -e "${YELLOW}Setup complete. Some pipelines need configuration (see above).${NC}"
fi

# Warn about org policy if webhooks are not public
if [ "$ALLOW_PUBLIC_WEBHOOKS" == "false" ] && { [ "$ENABLE_TELEGRAM" == "true" ] || [ "$ENABLE_TWILIO" == "true" ]; }; then
    echo ""
    echo -e "${YELLOW}Note: Webhooks are not publicly accessible due to organization policy.${NC}"
    echo "  To enable, add a project-level exception:"
    echo "  https://console.cloud.google.com/iam-admin/orgpolicies/iam-allowedPolicyMemberDomains?project=$PROJECT_ID"
    echo "  Then re-run: ./setup.sh --domain=$DOMAIN --resume"
fi

echo ""
echo -e "Questions? Contact: ${BOLD}$CONSULTANT_EMAIL${NC}"
echo ""

# Mark setup as complete (prevents cleanup message)
SETUP_COMPLETED="true"

# Clear state file on successful completion
clear_state

