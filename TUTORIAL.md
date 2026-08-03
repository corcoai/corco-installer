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

## Resume Without Reconfirming Saved Answers

If a previous run already completed the configuration steps, append
`--reuse-saved` to the original setup command. The bootstrap forwards the flag to the
verified installer package:

```sh
./setup.sh --token=<original-token> --reuse-saved
```

This reuses the saved company details, project, integration choices, folder IDs, caller
ID and import settings, and verifies that enabled credentials still exist in Secret
Manager. It stops instead of guessing if saved state is missing or a new manual,
security or destructive decision is required.
