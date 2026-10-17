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
corco-installer repository as TEARDOWN.md, and record its sha256 in that
repository's teardown.provenance.json in the same commit; Cloud Shell renders it as
the interactive tutorial behind the teardown link, and the copy in that public repo
is the one customers actually open. A test in each repository fails when the copy
differs from this file or from its recorded sha256.
-->

## 1. Teardown Your AI Ingestion Deployment

This will remove your Corco AI Ingestion deployment from Google Cloud.

### 1.1. What Gets Deleted

By default, the teardown removes ONLY the infrastructure:
- Cloud Functions and schedulers
- Storage buckets (recordings, voice samples)
- Service accounts
- The Telegram webhook, if a Telegram bot is connected

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

./teardown.sh
```

The script asks for your domain, then for your teardown token. Paste the token from your teardown link at the prompt; it is not shown on screen as you paste it.

The script will:
1. Show exactly what will be deleted
2. Ask you to confirm by typing the domain name
3. Tell Corco that the teardown has started
4. Show the Terraform plan, ask you to confirm it, and then run Terraform destroy to remove the infrastructure
5. Tell Corco that the teardown is complete, but only after every step has succeeded. If a step fails, the script stops and tells Corco that the teardown failed, and at which step.

The default teardown keeps your Google Cloud project, so it removes the deployment with Terraform. For this it needs the deployment files that setup unpacked into the `corco-installer` folder beside the script. If these files are not in this Cloud Shell, the script stops before it changes anything and shows "Nothing has been deleted". Then contact your Corco consultant, or delete the whole project as in the optional step below.

### 1.4. Step 2: Manual Cleanup (Domain-Wide Delegation)

After the automated teardown, you need to manually remove one Google Workspace setting:

1. Open: https://admin.google.com/ac/owl/domainwidedelegation
2. Find the entry for `gmail-sync-sa@YOUR-PROJECT.iam.gserviceaccount.com`
3. Click the trash icon to delete it

This is required because Google Workspace doesn't provide an API for Domain-Wide Delegation management.

### 1.5. Optional: Delete Data

If you want to PERMANENTLY delete all your data (this cannot be undone):

```bash
./teardown.sh --delete-data --delete-secrets --all
```

You are asked for your domain and your teardown token exactly as above. Then you must type the project ID to confirm that the whole project is deleted.

This will delete the whole Google Cloud project, including anything in it that Corco did not create, and with it:
- All BigQuery tables (communications history)
- All secrets (you'll need to re-enter API keys on reinstall)
- Configuration files

To delete all Corco resources and data but keep the project, add `--keep-project`. Like the default teardown, this needs the deployment files that setup unpacked.

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
