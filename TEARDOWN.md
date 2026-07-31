# Teardown Tutorial

## Table of Contents

<nav class="toc">
<div style="padding-left: 0px;"><a href="#1-teardown-your-ai-ingestion-deployment">1. Teardown Your AI Ingestion Deployment</a></div>
<div style="padding-left: 24px;"><a href="#11-what-gets-deleted">1.1. What Gets Deleted</a></div>
<div style="padding-left: 24px;"><a href="#12-before-you-begin">1.2. Before You Begin</a></div>
<div style="padding-left: 24px;"><a href="#13-step-1-run-the-teardown-script">1.3. Step 1: Run the Teardown Script</a></div>
<div style="padding-left: 24px;"><a href="#14-step-2-manual-cleanup-domain-wide-delegation">1.4. Step 2: Manual Cleanup (Domain-Wide Delegation)</a></div>
<div style="padding-left: 24px;"><a href="#15-optional-delete-data">1.5. Optional: Delete Data</a></div>
<div style="padding-left: 24px;"><a href="#16-reinstalling-later">1.6. Reinstalling Later</a></div>
<div style="padding-left: 24px;"><a href="#17-need-help">1.7. Need Help?</a></div>
<div style="padding-left: 0px;"><a href="#2-congratulations">2. Congratulations!</a></div>
</nav>

---

<!--
Publishing note, deliberately a comment: this document is what the customer reads,
so it must contain nothing addressed to us. Copy this file to the root of the
corco-installer repository as TEARDOWN.md; Cloud Shell renders it as the
interactive tutorial behind the teardown link, and the copy in that public repo is
the one customers actually open.
-->

## 1. Teardown Your AI Ingestion Deployment

This will remove your Corco AI Ingestion deployment from Google Cloud.

### 1.1. What Gets Deleted

By default, the teardown removes ONLY the infrastructure:
- Cloud Functions and schedulers
- Storage buckets (recordings, voice samples)
- Service accounts
- API credentials from Secret Manager

**Your data is preserved by default:**
- BigQuery tables (all communications data)
- Secrets (API keys, credentials)
- Configuration files

### 1.2. Before You Begin

Make sure you have:
- The teardown token from your email or the teardown link
- Access to the Google Cloud project as Owner or Editor

### 1.3. Step 1: Run the Teardown Script

```bash
<walkthrough-spotlight-pointer spotlightId="cloud-shell-terminal">
Click in the terminal below and run:
</walkthrough-spotlight-pointer>

./teardown.sh --token=YOUR_TOKEN
```

Replace `YOUR_TOKEN` with the token from your teardown link.

The script will:
1. Ask you to confirm by typing the domain name
2. Show exactly what will be deleted
3. Run Terraform destroy to remove infrastructure
4. Notify Corco that teardown is complete

### 1.4. Step 2: Manual Cleanup (Domain-Wide Delegation)

After the automated teardown, you need to manually remove one Google Workspace setting:

1. Open: https://admin.google.com/ac/owl/domainwidedelegation
2. Find the entry for `gmail-sync-sa@YOUR-PROJECT.iam.gserviceaccount.com`
3. Click the trash icon to delete it

This is required because Google Workspace doesn't provide an API for Domain-Wide Delegation management.

### 1.5. Optional: Delete Data

If you want to PERMANENTLY delete all your data (this cannot be undone):

```bash
./teardown.sh --token=YOUR_TOKEN --delete-data --delete-secrets --all
```

This will delete:
- All BigQuery tables (communications history)
- All secrets (you'll need to re-enter API keys on reinstall)
- Configuration files

### 1.6. Reinstalling Later

If you want to reinstall:

**If you kept data and secrets (default):**
Just contact your Corco consultant for a new setup link. Your data will still be there.

**If you deleted everything:**
You'll need to:
1. Get a new setup link from your consultant
2. Re-enter all API keys during setup
3. Start with empty BigQuery tables

### 1.7. Need Help?

Contact your Corco consultant or email support@corco.ai

---

## 2. Congratulations!

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

Your teardown is complete. The Corco team has been notified.
