Title: [Plugin] Steward - run Claude Code as an always-on Remote Control service

**Steward** runs [Claude Code](https://code.claude.com) as an always-on service on your Unraid server. You then drive it from the Claude app on your phone or from claude.ai/code through Remote Control, and it acts as a resident admin assistant for the box.

GitHub: https://github.com/hom-wang/steward
Install URL (Plugins -> Install Plugin): `https://raw.githubusercontent.com/hom-wang/steward/main/steward.plg`

**What it does**

- Keeps `claude remote-control` running under a supervisor, restarts it if it exits, and brings it up at boot before the array starts.
- Independent of the array and Docker. Keeps working while the array is stopped or disks are spun down. If a session holds a path under `/mnt` when the array is stopping, only that session is ended.
- Caches the Claude Code binary on the boot device, so the service comes up after a reboot even with no network.
- Updates Claude Code automatically once a day, and restarts the service only when no session has been active for 15 minutes.
- Ships guardrails for a root shell: a permission policy plus a hook that inspects every shell command. Disk-wiping tools and secret files are blocked outright; deletions, shutdowns, array control and writes to `/boot/config` ask you first. Also a starter `CLAUDE.md` that explains Unraid's layout and rules to the model.
- Settings -> Steward page: status, current connection link, Start / Stop / Restart, and a guided first-time sign-in.

**Requirements**

- Unraid 7.3.0 or newer with Internal Boot (`/boot` on ZFS). USB (FAT) boot is not supported: the plugin keeps credentials on the boot device and needs real file permissions. The installer checks this and refuses otherwise.
- A Claude subscription that includes Claude Code and Remote Control. You sign in through claude.ai; API keys are not supported for Remote Control. All usage is billed to your own account.

**Things to know before installing**

- Claude runs as root directly on the host. There is no container. The guardrails are a second line of defence, not a sandbox. Read the README's security section and adjust `CLAUDE.md` and `settings.json` to your comfort level.
- Credentials and session transcripts live in `/boot/steward/home`, deliberately outside `/boot/config` so Connect's cloud Flash Backup does not upload them. The local Flash Backup zip does contain them; treat it as a secret. If your flash is exported over SMB, set Export to No.
- Transcripts are plain text and are synced to Anthropic as part of normal Claude Code operation.

**Getting started**

1. Install the plugin.
2. Settings -> Steward -> "Sign in & first-time setup". A terminal window walks you through signing in and confirming Remote Control once.
3. Open the Claude app's Code tab or claude.ai/code. Your server is listed; start a session.

Full documentation, configuration options and troubleshooting are in the README on GitHub. Bug reports and feature requests are welcome here or on the GitHub issue tracker.

Steward is an independent, community-maintained project. It is not affiliated with, endorsed by, or sponsored by Anthropic PBC or Lime Technology, Inc. "Claude" and "Claude Code" are trademarks of Anthropic PBC; "Unraid" is a trademark of Lime Technology, Inc. Steward downloads the unmodified Claude Code binary from Anthropic's release server, pinned to one version and verified against its published SHA256, and never sees, stores or forwards your credentials.
