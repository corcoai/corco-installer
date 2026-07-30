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
#   ./teardown.sh <domain> [--token=xxx]   # Interactive, keeps secrets
#   ./teardown.sh <domain> --full          # Also deletes secrets
#   ./teardown.sh <domain> --project-only  # Keep Terraform state for reimport
#
# What this does:
#   1. Notifies Corco teardown started
#   2. Runs terraform destroy (removes all GCP resources)
#   3. Optionally deletes secrets from Secret Manager
#   4. Updates local registry (if present)
#   5. Notifies Corco teardown completed
#   6. Provides instructions for manual cleanup (DWD, etc.)
#
# =============================================================================

# Don't use set -e globally - we handle errors gracefully to ensure cleanup completes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate the platform tree. This script is the client-side bootstrap and does not ship
# inside the release tarball, so it cannot source the tarball's deployment/config -
# it has to resolve the paths itself. There is deliberately no empty fallback: an
# unset TERRAFORM_DIR would turn "cd $TERRAFORM_DIR" into a no-op that runs terraform
# destroy against whatever happens to be the current directory, and
# "rm -rf $TERRAFORM_DIR/.terraform" into "rm -rf /.terraform".
PLATFORM_ROOT="${CORCO_PLATFORM_ROOT:-}"
if [ -z "$PLATFORM_ROOT" ]; then
    if [ -d "$SCRIPT_DIR/corco-installer/deployment/terraform" ]; then
        # Normal client layout: setup.sh extracts the release tarball alongside us.
        PLATFORM_ROOT="$SCRIPT_DIR/corco-installer"
    elif [ -d "$SCRIPT_DIR/deployment/terraform" ]; then
        # Consultant running this from a full corco-platform checkout.
        PLATFORM_ROOT="$SCRIPT_DIR"
    else
        # Nothing extracted yet. Keep the client path so every derived path stays
        # absolute and non-empty; the terraform steps check before using it.
        PLATFORM_ROOT="$SCRIPT_DIR/corco-installer"
    fi
fi

TERRAFORM_DIR="$PLATFORM_ROOT/deployment/terraform"

# Only present in a full checkout - the release tarball does not ship the registry.
# Every use below is guarded by [ -f "$REGISTRY_FILE" ].
REGISTRY_FILE="$PLATFORM_ROOT/deployment/registry.json"

# Corco callback endpoint
TEARDOWN_CALLBACK_URL="${TEARDOWN_CALLBACK_URL:-https://setup.corco.ai/api/teardown}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
BOLD=$'\033[1m'

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

log_step() {
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

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------

DOMAIN=""
TEARDOWN_TOKEN=""
DELETE_DATA=false
DELETE_SECRETS=false
DELETE_CONFIG=false
KEEP_PROJECT=false
RESTORE_ORG_POLICY=false
FORCE=false
SECRETS_DELETE_ATTEMPTED=false
SECRETS_DELETE_VERIFIED=false
SECRETS_REMAINING_LIST=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --token=*)
            TEARDOWN_TOKEN="${1#*=}"
            shift
            ;;
        --token)
            TEARDOWN_TOKEN="$2"
            shift 2
            ;;
        --delete-data)
            DELETE_DATA=true
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
        --keep-project)
            KEEP_PROJECT=true
            shift
            ;;
        --project=*)
            PROJECT_ID="${1#*=}"
            shift
            ;;
        --project)
            PROJECT_ID="$2"
            shift 2
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
            echo "Options:"
            echo "  --delete-data        Also delete BigQuery dataset (IRREVERSIBLE)"
            echo "  --delete-secrets     Also delete CORCO_* secrets"
            echo "  --delete-config      Also delete tfvars configuration file"
            echo "  --all                Delete everything (data + secrets + config + project)"
            echo "  --keep-project       With --all: delete resources but keep GCP project & billing"
            echo "  --project=ID         Explicit project ID (skips tfvars/registry/domain derivation)"
            echo "  --restore-org-policy Reinstate iam.allowedPolicyMemberDomains restriction"
            echo "  --force, -f          Skip confirmation prompts"
            echo "  --help, -h           Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 waganari.capital                          # Safe teardown (keeps data)"
            echo "  $0 waganari.capital --delete-secrets          # Teardown + remove secrets"
            echo "  $0 waganari.capital --all                     # Complete wipe (deletes project)"
            echo "  $0 waganari.capital --all --keep-project      # Wipe resources, keep project"
            echo "  $0 waganari.capital --all --force              # Complete wipe, no prompts"
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

# Check tfvars file exists
TFVARS_FILE="$TERRAFORM_DIR/environments/${DOMAIN}.tfvars"
TFVARS_EXISTS=true

if [ ! -f "$TFVARS_FILE" ]; then
    # Only warn if project ID wasn't provided directly (via --project)
    if [ -z "$PROJECT_ID" ]; then
        log_warning "No configuration found for domain: $DOMAIN"
        echo "Expected file: $TFVARS_FILE"
        echo ""
        echo "Will attempt cleanup using domain name and registry..."
    fi
    TFVARS_EXISTS=false
fi

# Parse tfvars for project info
parse_tfvar() {
    local file=$1
    local key=$2
    grep "^${key}[[:space:]]*=" "$file" 2>/dev/null | sed 's/.*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | head -1
}

# PROJECT_ID may already be set via --project flag
REGION=""
DATASET=""
WORKSPACE_ADMIN=""

if [ -n "$PROJECT_ID" ]; then
    # Project ID provided via --project flag - skip all derivation
    REGION="${REGION:-us-central1}"
    echo "Using provided project ID: $PROJECT_ID"
elif [ "$TFVARS_EXISTS" == "true" ]; then
    PROJECT_ID=$(parse_tfvar "$TFVARS_FILE" "gcp_project_id")
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
    BASE_ID="${SAFE_DOMAIN}-ingestion"
    # GCP project IDs max 30 chars (same truncation as setup.sh)
    BASE_ID="${BASE_ID:0:30}"
    
    # Check base ID first, then suffixed variants (-2, -3, ..., -9)
    FOUND_PROJECT=""
    if gcloud projects describe "$BASE_ID" --format="value(lifecycleState)" &>/dev/null 2>&1; then
        FOUND_PROJECT="$BASE_ID"
    else
        for suffix in 2 3 4 5 6 7 8 9; do
            SUFFIX_STR="-${suffix}"
            MAX_BASE=$((30 - ${#SUFFIX_STR}))
            CANDIDATE="${BASE_ID:0:$MAX_BASE}${SUFFIX_STR}"
            if gcloud projects describe "$CANDIDATE" --format="value(lifecycleState)" &>/dev/null 2>&1; then
                FOUND_PROJECT="$CANDIDATE"
                break
            fi
        done
    fi
    
    if [ -n "$FOUND_PROJECT" ]; then
        PROJECT_ID="$FOUND_PROJECT"
        REGION="${REGION:-us-central1}"
        log_warning "Derived project ID from domain: $PROJECT_ID"
    else
        log_warning "Could not determine project ID - will only clean up local files"
        echo "  No tfvars file, no registry entry, and no project matching ${BASE_ID}[-N] found."
        echo "  Skipping GCP resource deletion."
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
else
    echo "    • Config: KEPT (use --delete-config to remove)"
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

# -----------------------------------------------------------------------------
# Verify and fix authentication
# -----------------------------------------------------------------------------

log_step "Verifying Authentication"

# Determine if running in Cloud Shell or locally
if [ -n "$CLOUD_SHELL" ] || [ -n "$GOOGLE_CLOUD_SHELL" ]; then
    # Cloud Shell: already authenticated as the user. Do NOT activate
    # configurations or change accounts - this corrupts Cloud Shell auth.
    echo "Running in Cloud Shell - using existing authentication"
    if [ -n "$PROJECT_ID" ]; then
        gcloud config set project "$PROJECT_ID" --quiet
    fi
else
    # Local machine: use gcloud configuration based on domain
    # Map domain to configuration name
    CONFIG_NAME=""
    case "$DOMAIN" in
        benediktmwagner.com) CONFIG_NAME="benediktmwagner" ;;
        waganari.capital) CONFIG_NAME="waganari" ;;
        *.corco.ai|corco.ai) CONFIG_NAME="corco" ;;
        *)
            # Try to find a matching configuration
            CONFIG_NAME=$(gcloud config configurations list --format="value(name)" 2>/dev/null | head -1)
            ;;
    esac
    
    if [ -n "$CONFIG_NAME" ]; then
        echo "Activating gcloud configuration: $CONFIG_NAME"
        gcloud config configurations activate "$CONFIG_NAME" 2>/dev/null || true
    fi
    
    # Test if we can access the project
    if [ -n "$PROJECT_ID" ] && ! gcloud projects describe "$PROJECT_ID" --format="value(projectId)" &>/dev/null 2>&1; then
        echo ""
        echo -e "${YELLOW}Cannot access project. Re-authenticating...${NC}"
        echo ""
        gcloud auth login
        
        # Also refresh application default credentials (used by Terraform)
        echo ""
        echo "Refreshing Terraform credentials..."
        gcloud auth application-default login
    fi
    
    if [ -n "$PROJECT_ID" ]; then
        gcloud config set project "$PROJECT_ID" --quiet
    fi
fi

# Verify access (but don't fail - project might already be deleted)
if gcloud projects describe "$PROJECT_ID" --format="value(projectId)" &>/dev/null 2>&1; then
    log_success "Authenticated and project accessible: $PROJECT_ID"
else
    log_warning "Project $PROJECT_ID not accessible (may be deleted or permissions changed)"
    echo "  Continuing with local cleanup..."
fi

# -----------------------------------------------------------------------------
# Notify Corco: Teardown Started
# -----------------------------------------------------------------------------

# Notify Corco (silent - don't show internal callback status to user)
DEPLOYER=$(gcloud config get-value account 2>/dev/null || echo "unknown")
if command -v curl &> /dev/null; then
    curl -s -X POST "$TEARDOWN_CALLBACK_URL/start" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain\": \"$DOMAIN\",
            \"token\": \"$TEARDOWN_TOKEN\",
            \"initiated_by\": \"$DEPLOYER\",
            \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"
        }" >/dev/null 2>&1 || true
fi

# -----------------------------------------------------------------------------
# Delete Resources
# -----------------------------------------------------------------------------

PROJECT_DELETED="false"
PROJECT_EXISTS="true"

# Skip GCP operations if we don't have a project ID
if [ -z "$PROJECT_ID" ]; then
    PROJECT_EXISTS="false"
    PROJECT_DELETED="true"  # Treat as already deleted for later logic
    log_warning "No project ID - skipping GCP resource deletion"
elif [ "$KEEP_PROJECT" == "true" ]; then
    # For --keep-project, we know the project exists (setup just detected it).
    # Don't test with gcloud projects describe - Cloud Shell auth can be flaky.
    # Set the project explicitly and proceed.
    PROJECT_EXISTS="true"
    gcloud config set project "$PROJECT_ID" --quiet 2>/dev/null || true
# Check if project exists (for --all and partial teardown only)
elif ! gcloud projects describe "$PROJECT_ID" &>/dev/null 2>&1; then
    PROJECT_EXISTS="false"
    log_warning "Project $PROJECT_ID does not exist or is not accessible"
    echo "  It may have already been deleted. Continuing with local cleanup..."
fi

# ─────────────────────────────────────────────────────────────────────────────
# --keep-project mode: delete all resources INSIDE the project via gcloud,
# but keep the project itself and its billing link intact.
# No Terraform needed (works without state, e.g. in Cloud Shell).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$KEEP_PROJECT" == "true" ] && [ "$PROJECT_EXISTS" == "true" ]; then
    log_step "Cleaning Resources (Keeping Project)"
    
    echo ""
    echo "Removing all deployment resources from project $PROJECT_ID..."
    echo "Project and billing will be preserved."
    echo ""
    
    REGION="${REGION:-us-central1}"
    
    # 1. Delete Telegram webhook (before deleting secrets)
    echo "  [1/7] Telegram webhook..."
    TELEGRAM_TOKEN=$(gcloud secrets versions access latest --secret="CORCO_TELEGRAM_BOT_TOKEN" --project="$PROJECT_ID" 2>/dev/null || echo "")
    if [ -n "$TELEGRAM_TOKEN" ]; then
        curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/deleteWebhook" >/dev/null 2>&1
        log_success "Telegram webhook removed"
    else
        echo "    No Telegram token found - skipping"
    fi
    
    # 2. Delete all Cloud Functions (gen1 + gen2) AND orphaned Cloud Run services
    echo "  [2/7] Cloud Functions + Cloud Run..."
    
    # 2a. Delete Cloud Functions
    FUNCTIONS=$(gcloud functions list --project="$PROJECT_ID" --regions="$REGION" --format="value(name)" 2>/dev/null || echo "")
    if [ -n "$FUNCTIONS" ]; then
        while IFS= read -r fn_full; do
            [ -z "$fn_full" ] && continue
            fn_name=$(basename "$fn_full")
            if gcloud functions delete "$fn_name" --gen2 --region="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null; then
                echo "    Deleted function: $fn_name"
            elif gcloud functions delete "$fn_name" --region="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null; then
                echo "    Deleted function: $fn_name (gen1)"
            else
                echo "    Failed to delete function: $fn_name"
            fi
        done <<< "$FUNCTIONS"
    else
        echo "    No Cloud Functions found"
    fi
    
    # 2b. Delete orphaned Cloud Run services (gen2 functions leave these behind)
    RUN_SERVICES=$(gcloud run services list --project="$PROJECT_ID" --region="$REGION" --format="value(metadata.name)" 2>/dev/null || echo "")
    if [ -n "$RUN_SERVICES" ]; then
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            if gcloud run services delete "$svc" --region="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null; then
                echo "    Deleted Cloud Run service: $svc"
            else
                echo "    Failed to delete Cloud Run service: $svc"
            fi
        done <<< "$RUN_SERVICES"
    fi
    
    # Verify: no functions AND no Cloud Run services remain
    REMAINING_FNS=$(gcloud functions list --project="$PROJECT_ID" --regions="$REGION" --format="value(name)" 2>/dev/null || echo "")
    REMAINING_RUN=$(gcloud run services list --project="$PROJECT_ID" --region="$REGION" --format="value(metadata.name)" 2>/dev/null || echo "")
    if [ -z "$REMAINING_FNS" ] && [ -z "$REMAINING_RUN" ]; then
        log_success "Cloud Functions and Cloud Run services deleted and verified"
    else
        log_warning "Some services remain after deletion"
        if [ -n "$REMAINING_FNS" ]; then
            echo "    Remaining functions:"
            while IFS= read -r fn; do [ -z "$fn" ] && continue; echo "      - $(basename "$fn")"; done <<< "$REMAINING_FNS"
        fi
        if [ -n "$REMAINING_RUN" ]; then
            echo "    Remaining Cloud Run services:"
            while IFS= read -r svc; do [ -z "$svc" ] && continue; echo "      - $svc"; done <<< "$REMAINING_RUN"
        fi
    fi
    
    # 3. Delete Cloud Scheduler jobs
    echo "  [3/7] Cloud Scheduler jobs..."
    JOBS=$(gcloud scheduler jobs list --project="$PROJECT_ID" --location="$REGION" --format="value(name)" 2>/dev/null || echo "")
    if [ -n "$JOBS" ]; then
        while IFS= read -r job_full; do
            [ -z "$job_full" ] && continue
            JOB_NAME=$(basename "$job_full")
            if gcloud scheduler jobs delete "$JOB_NAME" --location="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null; then
                echo "    Deleted: $JOB_NAME"
            else
                echo "    Failed to delete: $JOB_NAME"
            fi
        done <<< "$JOBS"
        log_success "Scheduler jobs deleted"
    else
        echo "    No scheduler jobs found"
    fi
    
    # 4. Delete CORCO_* secrets
    if [ "$DELETE_SECRETS" == "true" ]; then
        echo "  [4/7] Secrets..."
        SECRETS_DELETE_ATTEMPTED=true
        # List CORCO_* secrets (short names only)
        ALL_SECRETS=$(gcloud secrets list --project="$PROJECT_ID" --format="value(name)" 2>/dev/null || echo "")
        SECRETS=""
        while IFS= read -r secret; do
            [ -z "$secret" ] && continue
            SHORT_NAME=$(basename "$secret")
            if [[ "$SHORT_NAME" == CORCO_* ]]; then
                SECRETS="${SECRETS}${SHORT_NAME}"$'\n'
            fi
        done <<< "$ALL_SECRETS"
        if [ -n "$SECRETS" ]; then
            SECRET_DELETE_FAILURES=0
            while IFS= read -r SHORT_NAME; do
                [ -z "$SHORT_NAME" ] && continue
                if gcloud secrets delete "$SHORT_NAME" --project="$PROJECT_ID" --quiet >/dev/null 2>&1; then
                    echo "    Deleted: $SHORT_NAME"
                else
                    echo "    Failed to delete: $SHORT_NAME"
                    SECRET_DELETE_FAILURES=$((SECRET_DELETE_FAILURES + 1))
                fi
            done <<< "$SECRETS"

            # Verify remaining CORCO_* secrets
            REMAINING=$(gcloud secrets list --project="$PROJECT_ID" --format="value(name)" 2>/dev/null || echo "")
            SECRETS_REMAINING_LIST=""
            while IFS= read -r secret; do
                [ -z "$secret" ] && continue
                SHORT_NAME=$(basename "$secret")
                if [[ "$SHORT_NAME" == CORCO_* ]]; then
                    SECRETS_REMAINING_LIST="${SECRETS_REMAINING_LIST}${SHORT_NAME}"$'\n'
                fi
            done <<< "$REMAINING"

            if [ -z "$SECRETS_REMAINING_LIST" ] && [ "$SECRET_DELETE_FAILURES" -eq 0 ]; then
                SECRETS_DELETE_VERIFIED=true
                log_success "Secrets deleted and verified"
            else
                SECRETS_DELETE_VERIFIED=false
                log_warning "Secret deletion incomplete (some secrets remain or deletions failed)"
                if [ -n "$SECRETS_REMAINING_LIST" ]; then
                    echo "    Remaining secrets:"
                    while IFS= read -r remaining_secret; do
                        [ -z "$remaining_secret" ] && continue
                        echo "      - $remaining_secret"
                    done <<< "$SECRETS_REMAINING_LIST"
                fi
            fi
        else
            echo "    No CORCO_* secrets found"
            SECRETS_DELETE_VERIFIED=true
        fi
    else
        echo "  [4/7] Secrets: preserved (no --delete-secrets)"
    fi
    
    # 5. Delete GCS buckets (preserve tfstate - Terraform needs it on reinstall)
    echo "  [5/7] GCS buckets..."
    for bucket in "${PROJECT_ID}-recordings" "${PROJECT_ID}-voice" "${PROJECT_ID}-function-source"; do
        if gsutil ls -b "gs://${bucket}" &>/dev/null 2>&1; then
            gsutil -m rm -r "gs://${bucket}/**" 2>/dev/null || true
            gsutil rb "gs://${bucket}" 2>/dev/null || true
            echo "    Deleted: gs://${bucket}"
        fi
    done
    TFSTATE_BUCKET="${PROJECT_ID}-tfstate"
    if gsutil ls -b "gs://${TFSTATE_BUCKET}" &>/dev/null 2>&1; then
        echo "    Preserved: gs://${TFSTATE_BUCKET} (Terraform state - needed for idempotent reinstall)"
    fi
    log_success "GCS buckets cleaned (tfstate preserved)"
    
    # 6. Delete BigQuery dataset
    if [ "$DELETE_DATA" == "true" ]; then
        echo "  [6/7] BigQuery dataset..."
        if bq show --project_id="$PROJECT_ID" corporate_context &>/dev/null 2>&1; then
            bq rm -r -f --project_id="$PROJECT_ID" corporate_context 2>/dev/null || true
            log_success "BigQuery dataset deleted"
        else
            echo "    No BigQuery dataset found"
        fi
    else
        echo "  [6/7] BigQuery: preserved (no --delete-data)"
    fi
    
    # 7. Service accounts - PRESERVED
    # SAs are kept because:
    #   - DWD configuration in Google Workspace Admin references the SA's uniqueId
    #   - Deleting the SA invalidates DWD (requires manual re-configuration)
    #   - SA keys stored in Secret Manager become useless if SA is deleted
    echo "  [7/7] Service accounts: preserved (DWD depends on SA uniqueId)"
    
    echo ""
    log_success "All resources removed. Project $PROJECT_ID preserved with billing and SAs intact."
    
    # Mark as done so later sections skip GCP operations
    PROJECT_DELETED="false"

# ─────────────────────────────────────────────────────────────────────────────
# --all mode (without --keep-project): delete the entire GCP project
# ─────────────────────────────────────────────────────────────────────────────
elif [ "$DELETE_DATA" == "true" ] && [ "$DELETE_SECRETS" == "true" ] && [ "$DELETE_CONFIG" == "true" ]; then
    
    # ── Pre-deletion cleanup: deregister Telegram webhook ──
    if [ "$PROJECT_EXISTS" == "true" ]; then
        log_step "Pre-deletion Cleanup"
        
        # Delete Telegram webhook (prevents Telegram from hitting a dead URL after project deletion)
        TELEGRAM_TOKEN=$(gcloud secrets versions access latest --secret="CORCO_TELEGRAM_BOT_TOKEN" --project="$PROJECT_ID" 2>/dev/null || echo "")
        if [ -n "$TELEGRAM_TOKEN" ]; then
            echo "Removing Telegram webhook..."
            WEBHOOK_DEL=$(curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/deleteWebhook" 2>/dev/null || echo "")
            if echo "$WEBHOOK_DEL" | grep -q '"ok":true'; then
                log_success "Telegram webhook removed"
            else
                log_warning "Could not remove Telegram webhook (may already be gone)"
            fi
        else
            echo "No Telegram bot token found - skipping webhook cleanup"
        fi
    fi
    
    log_step "Deleting GCP Project"
    
    if [ "$PROJECT_EXISTS" == "false" ]; then
        echo "Project already deleted or not accessible."
        PROJECT_DELETED="true"
    else
        echo ""
        echo -e "${RED}⚠️  FULL TEARDOWN: Deleting entire GCP project${NC}"
        echo "   Project: $PROJECT_ID"
        echo "   This will delete ALL resources, data, and configurations."
        echo ""
        
        if [ "$FORCE" != "true" ]; then
            echo -e "${YELLOW}Type the project ID to confirm deletion:${NC} $PROJECT_ID"
            read -p "> " confirm_project
            if [ "$confirm_project" != "$PROJECT_ID" ]; then
                log_warning "Project confirmation failed - skipping GCP project deletion"
                echo "  Continuing with local cleanup..."
                PROJECT_EXISTS="false"
            fi
        fi
        
        # Only delete if confirmation passed
        if [ "$PROJECT_EXISTS" == "true" ]; then
        echo ""
        echo "Deleting project $PROJECT_ID..."
        if gcloud projects delete "$PROJECT_ID" --quiet 2>&1; then
            log_success "GCP project deleted"
            PROJECT_DELETED="true"
        else
            # Check if it's because project is already gone
            if ! gcloud projects describe "$PROJECT_ID" &>/dev/null 2>&1; then
                echo "Project already deleted."
                PROJECT_DELETED="true"
            else
                log_warning "Could not delete project via gcloud"
                echo "  You may need to delete it manually:"
                echo "  https://console.cloud.google.com/iam-admin/settings?project=$PROJECT_ID"
            fi
        fi
        fi  # End of: if [ "$PROJECT_EXISTS" == "true" ] (confirmation passed)
    fi

else
    # Partial teardown - use Terraform to selectively destroy resources
    log_step "Running Terraform Destroy (Partial)"
    
    if [ "$PROJECT_EXISTS" == "false" ]; then
        echo "Project doesn't exist - skipping Terraform destroy."
        echo "Resources were likely already deleted."
    elif ! cd "$TERRAFORM_DIR" 2>/dev/null; then
        # Never fall through to running terraform in whatever the current directory is.
        log_error "Terraform directory not found: $TERRAFORM_DIR"
        echo "  Re-run the installer to extract the platform files, or set"
        echo "  CORCO_PLATFORM_ROOT to the directory containing deployment/terraform."
        echo "  Skipping Terraform destroy; nothing was changed."
    else
        # Initialize Terraform with correct backend config
        echo "Initializing Terraform..."
        TFSTATE_BUCKET="${PROJECT_ID}-tfstate"
        
        set +e  # Don't exit on error - handle gracefully
        terraform init \
            -backend-config="bucket=${TFSTATE_BUCKET}" \
            -backend-config="prefix=ai-ingestion" \
            -input=false \
            -reconfigure 2>&1
        TF_INIT_EXIT=$?
        set -e
        
        if [ $TF_INIT_EXIT -ne 0 ]; then
            log_warning "Could not initialize Terraform (state bucket may not exist)"
            echo "  Resources may have already been deleted. Continuing..."
        else
            # Build the terraform command with appropriate variables
            TF_VARS="-var-file=environments/${DOMAIN}.tfvars"
            
            if [ "$DELETE_DATA" == "true" ]; then
                echo ""
                echo -e "${RED}⚠️  WARNING: --delete-data specified${NC}"
                echo "   BigQuery deletion protection will be DISABLED"
                echo "   All communications data will be PERMANENTLY DELETED"
                echo ""
                TF_VARS="$TF_VARS -var=bigquery_deletion_protection=false"
            else
                echo ""
                echo -e "${GREEN}ℹ️  BigQuery data will be PRESERVED${NC}"
                echo "   (Use --delete-data to also delete BigQuery dataset)"
                echo ""
            fi
            
            echo "Planning destruction..."
            set +e
            if [ "$DELETE_DATA" == "true" ]; then
                terraform plan -destroy $TF_VARS -out=destroy.plan -input=false 2>&1
            else
                terraform plan -destroy $TF_VARS \
                    -target=module.functions \
                    -target=module.iam \
                    -target=module.scheduler \
                    -target=module.secrets \
                    -target=module.storage \
                    -target=module.monitoring \
                    -out=destroy.plan -input=false 2>&1
            fi
            TF_PLAN_EXIT=$?
            set -e
            
            if [ $TF_PLAN_EXIT -ne 0 ]; then
                log_warning "Terraform plan failed (resources may already be deleted)"
                rm -f destroy.plan
            elif [ -f destroy.plan ]; then
                echo ""
                if [ "$FORCE" != "true" ]; then
                    if ! prompt_yes_no "Apply the destruction plan?" "n"; then
                        rm -f destroy.plan
                        log_error "Teardown cancelled."
                        exit 1
                    fi
                fi
                
                echo ""
                echo "Destroying resources..."
                set +e
                terraform apply -input=false destroy.plan 2>&1
                set -e
                rm -f destroy.plan
                
                log_success "Terraform destroy complete"
            fi
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Delete Secrets (if --full and project not already deleted)
# -----------------------------------------------------------------------------

if [ "$PROJECT_DELETED" == "true" ] || [ "$PROJECT_EXISTS" == "false" ]; then
    echo "Secrets deleted with project (or project not accessible)."
elif [ "$SECRETS_DELETE_ATTEMPTED" == "true" ]; then
    if [ "$SECRETS_DELETE_VERIFIED" == "true" ]; then
        log_step "Secrets Deletion Verified"
        echo "CORCO_* secrets removed successfully."
    else
        log_step "Secrets Deletion Incomplete"
        echo "Some CORCO_* secrets could not be deleted."
        if [ -n "$SECRETS_REMAINING_LIST" ]; then
            echo "Remaining:"
            while IFS= read -r remaining_secret; do
                [ -z "$remaining_secret" ] && continue
                echo "  • $remaining_secret"
            done <<< "$SECRETS_REMAINING_LIST"
        fi
    fi
elif [ "$DELETE_SECRETS" == "true" ]; then
    log_step "Deleting Secrets"
    
    echo "Finding CORCO_* secrets..."
    SECRETS=$(gcloud secrets list --project="$PROJECT_ID" --format="value(name)" 2>/dev/null || echo "")
    FILTERED_SECRETS=""
    while IFS= read -r secret; do
        [ -z "$secret" ] && continue
        SHORT_NAME=$(basename "$secret")
        if [[ "$SHORT_NAME" == CORCO_* ]]; then
            FILTERED_SECRETS="${FILTERED_SECRETS}${SHORT_NAME}"$'\n'
        fi
    done <<< "$SECRETS"
    
    if [ -n "$FILTERED_SECRETS" ]; then
        while IFS= read -r secret; do
            [ -z "$secret" ] && continue
            echo "Deleting: $secret"
            gcloud secrets delete "$secret" --project="$PROJECT_ID" --quiet 2>/dev/null || echo "  (already deleted or inaccessible)"
        done <<< "$FILTERED_SECRETS"

        # Verify deletion
        REMAINING=$(gcloud secrets list --project="$PROJECT_ID" --format="value(name)" 2>/dev/null || echo "")
        STILL_THERE=""
        while IFS= read -r secret; do
            [ -z "$secret" ] && continue
            SHORT_NAME=$(basename "$secret")
            if [[ "$SHORT_NAME" == CORCO_* ]]; then
                STILL_THERE="${STILL_THERE}${SHORT_NAME}"$'\n'
            fi
        done <<< "$REMAINING"

        if [ -z "$STILL_THERE" ]; then
            log_success "Secrets deleted and verified"
        else
            log_warning "Some secrets could not be deleted"
            echo "Remaining:"
            while IFS= read -r remaining_secret; do
                [ -z "$remaining_secret" ] && continue
                echo "  • $remaining_secret"
            done <<< "$STILL_THERE"
        fi
    else
        echo "No CORCO_* secrets found (already deleted or none existed)"
    fi
else
    log_step "Secrets Preserved"
    echo "Existing secrets were NOT deleted. They can be reused on reinstall."
    echo "Use --delete-secrets flag to also delete secrets."
fi

# -----------------------------------------------------------------------------
# Update Local Registry (if present)
# -----------------------------------------------------------------------------

if [ -f "$REGISTRY_FILE" ]; then
    log_step "Updating Local Registry"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    DEPLOYER=$(gcloud config get-value account 2>/dev/null || echo "unknown")
    
    if [ "$DELETE_CONFIG" == "true" ]; then
        # Full wipe - remove the deployment entry entirely
        jq --arg domain "$DOMAIN" \
           --arg timestamp "$TIMESTAMP" \
           '
           del(.deployments[$domain]) |
           ._updated = $timestamp
           ' "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp" && mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"
        
        log_success "Local registry updated: $DOMAIN entry removed"
    else
        # Safe teardown - mark as torn down but keep entry
        jq --arg domain "$DOMAIN" \
           --arg timestamp "$TIMESTAMP" \
           --arg deployer "$DEPLOYER" \
           --argjson delete_data "$DELETE_DATA" \
           --argjson delete_secrets "$DELETE_SECRETS" \
           '
           .deployments[$domain].deployment.torn_down_at = $timestamp |
           .deployments[$domain].deployment.torn_down_by = $deployer |
           .deployments[$domain].deployment.status = "torn_down" |
           .deployments[$domain].teardown = {
             "completed_at": $timestamp,
             "delete_data": $delete_data,
             "delete_secrets": $delete_secrets
           } |
           ._updated = $timestamp
           ' "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp" && mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"
        
        log_success "Local registry updated: $DOMAIN marked as torn down"
    fi
fi

# -----------------------------------------------------------------------------
# Notify Corco: Teardown Completed
# -----------------------------------------------------------------------------

# Notify Corco (silent)
if command -v curl &> /dev/null; then
    curl -s -X POST "$TEARDOWN_CALLBACK_URL/complete" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain\": \"$DOMAIN\",
            \"token\": \"$TEARDOWN_TOKEN\",
            \"delete_data\": $DELETE_DATA,
            \"delete_secrets\": $DELETE_SECRETS,
            \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"
        }" >/dev/null 2>&1 || true
fi

# -----------------------------------------------------------------------------
# Clean up tfvars (optional)
# -----------------------------------------------------------------------------

if [ "$DELETE_CONFIG" == "true" ]; then
    log_step "Deleting Configuration"
    rm -f "$TFVARS_FILE"
    log_success "Deleted: $TFVARS_FILE"
else
    echo ""
    echo -e "${GREEN}Configuration preserved:${NC} $TFVARS_FILE"
fi

# -----------------------------------------------------------------------------
# Clean up setup state file (for resume functionality)
# -----------------------------------------------------------------------------

STATE_FILE="$HOME/.corco-setup/${DOMAIN}.state"
if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    log_success "Cleared setup state file (resume data)"
fi

# -----------------------------------------------------------------------------
# Clean up Terraform state bucket (if --all and project not deleted)
# -----------------------------------------------------------------------------

if [ "$PROJECT_DELETED" == "true" ] || [ "$PROJECT_EXISTS" == "false" ]; then
    echo "Terraform state deleted with project (or project not accessible)."
elif [ "$DELETE_CONFIG" == "true" ]; then
    log_step "Cleaning Up Terraform State"
    
    # Delete the GCS bucket storing Terraform state
    TFSTATE_BUCKET="${PROJECT_ID}-tfstate"
    if gsutil ls -b "gs://${TFSTATE_BUCKET}" &>/dev/null 2>&1; then
        echo "Deleting Terraform state bucket: $TFSTATE_BUCKET"
        gsutil -m rm -r "gs://${TFSTATE_BUCKET}/**" 2>/dev/null || true
        gsutil rb "gs://${TFSTATE_BUCKET}" 2>/dev/null || true
        log_success "Terraform state bucket deleted"
    else
        echo "Terraform state bucket not found (already deleted)"
    fi
fi

# Clean up local Terraform files (always, regardless of project state)
if [ "$DELETE_CONFIG" == "true" ]; then
    if [ -d "$TERRAFORM_DIR/.terraform" ]; then
        rm -rf "$TERRAFORM_DIR/.terraform"
        log_success "Cleared local Terraform cache (.terraform/)"
    fi
    if [ -f "$TERRAFORM_DIR/.terraform.lock.hcl" ]; then
        rm -f "$TERRAFORM_DIR/.terraform.lock.hcl"
        log_success "Cleared Terraform lock file"
    fi
fi

# -----------------------------------------------------------------------------
# Restore Organization Policy (if --restore-org-policy and project not deleted)
# -----------------------------------------------------------------------------

if [ "$PROJECT_DELETED" == "true" ] || [ "$PROJECT_EXISTS" == "false" ]; then
    echo "Org policy deleted with project (or project not accessible)."
elif [ "$RESTORE_ORG_POLICY" == "true" ]; then
    log_step "Restoring Organization Policy"
    
    echo "Checking current org policy state..."
    
    CURRENT_POLICY=$(gcloud resource-manager org-policies describe iam.allowedPolicyMemberDomains \
        --project="$PROJECT_ID" --format='value(listPolicy.allValues)' 2>/dev/null || echo "")
    
    if [ "$CURRENT_POLICY" == "ALLOW" ]; then
        echo "Project has an exception allowing allUsers. Removing..."
        
        if gcloud resource-manager org-policies delete iam.allowedPolicyMemberDomains \
            --project="$PROJECT_ID" 2>&1; then
            log_success "Project-level org policy exception removed"
        else
            log_warning "Could not remove org policy exception (may already be removed)"
        fi
    else
        echo "No project-level allUsers exception found (already clean)"
    fi
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

echo ""
echo "Domain:  $DOMAIN"
echo "Project: $PROJECT_ID"
echo ""
echo "Summary:"
if [ "$KEEP_PROJECT" == "true" ]; then
    echo -e "  • Cloud Functions:   ${RED}DELETED${NC}"
    echo -e "  • Scheduler jobs:    ${RED}DELETED${NC}"
    echo -e "  • GCS buckets:       ${RED}DELETED${NC} (tfstate preserved)"
    if [ "$DELETE_DATA" == "true" ]; then
        echo -e "  • BigQuery data:     ${RED}DELETED${NC}"
    else
        echo -e "  • BigQuery data:     ${GREEN}PRESERVED${NC}"
    fi
    if [ "$DELETE_SECRETS" == "true" ]; then
        if [ "$SECRETS_DELETE_VERIFIED" == "true" ]; then
            echo -e "  • Secrets:           ${RED}DELETED${NC}"
        else
            echo -e "  • Secrets:           ${YELLOW}PARTIAL${NC} (check remaining list above)"
        fi
    else
        echo -e "  • Secrets:           ${GREEN}PRESERVED${NC}"
    fi
    echo -e "  • Service accounts:  ${GREEN}PRESERVED${NC}"
    echo -e "  • GCP Project:       ${GREEN}PRESERVED${NC}"
    echo -e "  • Billing:           ${GREEN}PRESERVED${NC}"
else
    echo "  • Infrastructure: DELETED"
    if [ "$DELETE_DATA" == "true" ]; then
        echo -e "  • BigQuery data: ${RED}DELETED${NC}"
    else
        echo -e "  • BigQuery data: ${GREEN}PRESERVED${NC}"
    fi
    if [ "$DELETE_SECRETS" == "true" ]; then
        echo -e "  • Secrets: ${RED}DELETED${NC}"
    else
        echo -e "  • Secrets: ${GREEN}PRESERVED${NC}"
    fi
    if [ "$DELETE_CONFIG" == "true" ]; then
        echo -e "  • Configuration: ${RED}DELETED${NC}"
    else
        echo -e "  • Configuration: ${GREEN}PRESERVED${NC}"
    fi
fi
if [ "$RESTORE_ORG_POLICY" == "true" ]; then
    echo -e "  • Org policy exception: ${RED}REMOVED${NC} (allUsers blocked)"
fi
echo ""

if [ "$KEEP_PROJECT" == "true" ]; then
    echo -e "  • GCP Project: ${GREEN}PRESERVED${NC} (with billing)"
    echo ""
    echo -e "${GREEN}Resource cleanup complete.${NC} Project preserved and ready for fresh install."
    echo ""
    echo "To reinstall:"
    echo "  Run setup.sh with your token (project and billing are intact)"
elif [ "$DELETE_DATA" == "true" ] && [ "$DELETE_SECRETS" == "true" ] && [ "$DELETE_CONFIG" == "true" ]; then
    echo -e "  • GCP Project: ${RED}DELETED${NC}"
    echo ""
    echo -e "${GREEN}Full cleanup complete.${NC} The project is ready for a fresh install."
    echo ""
    echo "Everything removed:"
    echo "  • GCP resources (functions, schedulers, buckets, etc.)"
    echo "  • BigQuery dataset and all data"
    echo "  • All CORCO_* secrets"
    echo "  • Terraform state (local and GCS)"
    echo "  • Configuration files (tfvars)"
    echo "  • Setup state (resume data)"
    echo ""
    echo "To reinstall from scratch:"
    echo "  1. Complete manual DWD cleanup (see above)"
    echo "  2. Run setup.sh with a new token"
else
    echo -e "${GREEN}Safe teardown complete.${NC} Data and secrets preserved for reinstall."
    echo ""
    echo "To reinstall:"
    echo "  1. Complete manual DWD cleanup (see above)"
    echo "  2. Run: ./setup.sh --domain=$DOMAIN --resume"
    echo ""
    echo "To fully wipe later:"
    echo "  ./teardown.sh $DOMAIN --all"
fi
echo ""

