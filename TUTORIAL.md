# Corco Utterances Setup

<walkthrough-tutorial-duration duration="5"></walkthrough-tutorial-duration>

## Run Setup

Copy the **setup command** from your setup page, paste it in the terminal, and press
**Enter**. It already contains your setup token.

If you would rather not go back to that page, run the script on its own and it will ask
for the token:

```sh
./setup.sh
```

Either way the script detects your domain and configures everything from there.

## Public Setup Options

The public bootstrap accepts `--token=<token>` and the six forwarding options below.
It rejects every other argument before downloading or running a release.

| Option | Behavior |
|--------|----------|
| `--resume` | Continues from saved checkpoints. Completed steps are skipped, but setup may ask for missing answers or new decisions. |
| `--reuse-saved` | Implies `--resume`. Reuses all saved answers without confirmations and stops if any required answer is missing, invalid or inconsistent. |
| `--upgrade` | Implies both `--resume` and `--reuse-saved`. Reconciles an existing completed deployment with the downloaded release. |
| `--approve-destructive-plan=<sha256>` | Approves the exact non-protected deletion manifest whose lowercase SHA-256 was printed by a blocked setup plan. |
| `--allow-destructive-plan=<sha256>` | Compatibility alias normalized by the bootstrap to `--approve-destructive-plan=<sha256>` before the verified release is launched. |
| `--telegram-webhook-cutover-from=<https-url>` | Authorizes moving the bot only when Telegram's live current webhook exactly matches this URL. The approval is ephemeral and is never saved or reused. |

Use the `--token=<token>` form with an equals sign. `--token <token>`, bare approval
flags, values attached to mode flags such as `--resume=true`, and unknown options are not
part of the public interface.

### Resume an Interactive Run

Use `--resume` when a previous run stopped and you are available to answer anything that
was not saved:

```sh
./setup.sh --token=<original-token> --resume
```

### Reuse Every Saved Answer

Use `--reuse-saved` for a previously configured, incomplete run when you do not want to
reconfirm existing choices:

```sh
./setup.sh --token=<original-token> --reuse-saved
```

This reuses saved company details, project, integration choices, folder IDs, caller ID
and import settings, and verifies that enabled credentials still exist in Secret
Manager. It stops instead of guessing if saved state is missing or a new manual,
security or destructive decision is required.

### Upgrade an Existing Deployment

Use `--upgrade` to apply the downloaded release to a setup already marked complete:

```sh
./setup.sh --token=<original-token> --upgrade
```

Upgrade restores and validates the saved answers, reruns infrastructure reconciliation
and registration, and does not repeat checkpointed historical imports or welcome steps.
It is an in-place reconciliation, not a clean reinstall.

The modes are nested: `--upgrade` includes `--reuse-saved`, which includes `--resume`.
Pass the strongest single mode you need. Supplying multiple modes is redundant; the
bootstrap forwards them unchanged and the downloaded installer remains the authority on
their combination.

The original token is required on every rerun. It is not recovered from saved setup
state.

If setup reports that a Telegram bot belongs to another deployment, inspect the live
URL it prints. Only after confirming that the old deployment should relinquish the bot,
rerun with the exact compare-and-set gate:

```sh
./setup.sh --token=<original-token> --upgrade --telegram-webhook-cutover-from=<exact-current-https-url>
```

An empty, different or subsequently changed live URL invalidates the approval. The flag
is intentionally excluded from saved-answer state so a later rerun cannot repeat an old
cutover decision.

## Approve a Reviewed Deletion Manifest

Upgrade saves and checks a Terraform plan before applying it. Protected BigQuery
resources, storage buckets and secrets cannot be approved for deletion through either
approval flag. Other deletions stop setup and print the saved plan path plus a canonical
manifest SHA-256.

Review that saved plan, then rerun the same command with the exact printed hash:

```sh
./setup.sh --token=<original-token> --upgrade \
  --approve-destructive-plan=<printed-lowercase-sha256>
```

The hash value must be exactly 64 lowercase hexadecimal characters. A bare flag, an
empty value, the wrong length or uppercase characters are rejected by the downloaded
installer. The approval applies only to that exact manifest: if an address, action or
resource identity changes, the hash changes and setup stops for a new review.

The legacy spelling is equivalent. The bootstrap normalizes it to the canonical spelling,
so it also works with releases that expose only the canonical public option:

```sh
./setup.sh --token=<original-token> --upgrade \
  --allow-destructive-plan=<printed-lowercase-sha256>
```

Do not supply either approval flag before setup has printed the hash for the plan you
reviewed.

## Release Compatibility

These options do not select a release version. The setup service chooses the package,
and the bootstrap verifies its published SHA-256 before extracting anything.

Before launch, the bootstrap checks the downloaded
`deployment/scripts/setup.sh` for every requested mode. Either destructive-plan spelling
also requires that release to advertise hash-bound destructive-plan support. Capability
detection is based on the downloaded script, not on a minimum or maximum SemVer: a lower
reported version that contains the capability is forwarded, while a higher reported
version without it is rejected.

If any requested option is unsupported, the bootstrap reports the downloaded release
version and exits without running its setup script. This can occur when the public
bootstrap is updated before a compatible platform release is promoted. Wait for the
compatible release, then rerun the same command; do not remove a safety flag merely to
bypass the compatibility check.
