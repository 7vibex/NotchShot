# Security Policy

## Reporting a vulnerability

Do not open a public issue for security problems. Report privately through GitHub:

https://github.com/7vibex/NotchShot/security/advisories/new

Include the app version or commit, macOS version, reproduction steps, and the impact you
believe the issue has. You will get a response as soon as possible; please allow time
before disclosing publicly.

## Scope

NotchShot runs with the permissions the user grants it, and its threat model is built
around keeping capture data local:

- **Screen Recording** output, recordings, OCR text, transcripts, and history stay in
  `~/Library/Application Support/NotchShot` or a user-chosen folder.
- **No telemetry, no account, no backend.** The only outbound network paths are the
  documented Spotify artwork fetch, Open-Meteo weather refresh, LocalSend transfers the
  user initiates, and the signed Sparkle update feed in configured public builds.
- **Local automation is attacker-relevant.** The `notchshot://` URL scheme accepts only a
  documented set of parameters, validates and canonicalizes file paths, rate-limits
  requests, and requires foreground confirmation.
- **External helpers are opt-in and untrusted by default.** The MediaRemote adapter is a
  user-supplied executable; the OSD replacement uses a bundled recovery watchdog that
  restores the native overlay on quit, crash, or force-quit.

In scope: privilege escalation, sandbox or TCC bypass, capture-exclusion bypass (the app
appearing in its own or others' output), redaction bypass where hidden content remains
recoverable from an exported file, path traversal or inode validation bypass in file
handling, URL-scheme abuse, and authentication or signing issues in the update path.

Out of scope: findings that require an already-compromised Mac, issues in the optional
user-supplied MediaRemote adapter itself, and reports that depend on unsupported
configurations (App Sandbox with the OSD replacement enabled is documented as
incompatible).

## Supported versions

Fixes land on `main` and are included in the next release. Pre-1.0 snapshots are not
patched separately.
