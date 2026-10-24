# Steward

Run [Claude Code](https://code.claude.com) as an always-on service on your Unraid server, and drive it from the Claude app on your phone or from claude.ai/code through Remote Control.

Steward does not depend on the array or on Docker. It keeps working while the array is stopped, while disks are spun down, and across reboots. Everything it owns lives on the boot device under `/boot/steward`.

> Steward is an independent, community-maintained project. It is not affiliated with, endorsed by, or sponsored by Anthropic PBC or Lime Technology, Inc. "Claude" and "Claude Code" are trademarks of Anthropic PBC; "Unraid" is a trademark of Lime Technology, Inc. Steward downloads the unmodified Claude Code binary from Anthropic's release server, pinned to one version and verified against its published SHA256, and runs it as a background service. You sign in with your own Claude subscription through Anthropic's own login flow. Steward never sees, stores, or forwards your credentials, and all usage is billed to your own account.

## What you get

- **Always-on Remote Control.** A supervisor keeps `claude remote-control` running, restarts it if it exits, and backs off on repeated failures. Your server shows up in the Claude app's Code tab and at claude.ai/code.
- **Survives reboots with no network.** The Claude Code binary is cached on the boot device and restored into RAM at boot, so the service comes up even before the internet does.
- **Array-aware.** When the array is about to stop, Steward ends any of its own processes that hold `/mnt`, so the array can unmount.
- **Automatic Claude Code updates.** In remote-control mode Claude Code does not update itself. Steward checks the stable channel once a day after 08:00, installs new releases, and restarts the service only when no session has been active for 15 minutes.
- **Guardrails for a root shell.** Claude runs as root directly on the host. Steward ships a permission policy and a command-inspecting hook that block disk-wiping tools and secret files outright, and ask before deletions, shutdowns, or writes to `/boot/config`.
- **Verified binary.** The first install downloads one pinned Claude Code version straight from Anthropic's release server and installs it only if its SHA256 matches the value built into the plugin; no installer script is run. Every later update is checked against the SHA256 Anthropic publishes for that version before it is kept, and the backup on the boot device is checked before it is restored.
- **A Settings page.** Settings -> Steward shows status and the current connection link, and has Start / Stop / Restart and a guided first-time sign-in.

## Requirements

- Unraid **7.3.0 or newer** with **Internal Boot** (`/boot` on ZFS). USB (FAT) boot is not supported: Steward stores credentials on the boot device and needs real file permissions and symlinks, which FAT cannot provide. The installer checks this and refuses otherwise.
- A Claude subscription that includes Claude Code and Remote Control. You sign in through claude.ai; API keys are not supported for Remote Control.
- Outbound internet access for the first install and for updates. About 300 MB of free space on the boot device for the binary cache.
- Do not install alongside another plugin that also provides `/usr/local/bin/claude`. The installer detects `claude-code.plg` and stops.

## Install

**From the webGUI (recommended)**

1. Open **Plugins -> Install Plugin**, paste the URL below, and click **Install**.

   ```
   https://raw.githubusercontent.com/hom-wang/steward/main/steward.plg
   ```

2. Open **Settings -> Steward** and click the sign-in button. A terminal window opens and walks you through two steps: signing in to claude.ai, and running Remote Control once in the foreground to answer its one-time prompts. When the connection link appears, open the Claude app's Code tab or claude.ai/code and confirm you can see the server, then press Ctrl+C. Answer **Y** to enable the service and start it at boot.

   If the browser blocks the pop-up, allow pop-ups for the Unraid site, or run `steward setup` from the Unraid terminal or SSH instead.

**From a shell**

The plugin file contains the whole script. If you prefer not to use the plugin system:

```sh
bash steward.sh install   # creates /boot/steward, hooks go/stop/cron, fetches Claude Code
steward setup             # sign in and enable the service
```

Pick one method; do not install both.

## Everyday use

The service runs on its own. Each session you open from the phone or browser is a separate `claude` process in `/boot/steward/workspace`. Up to four sessions can run at once by default.

```
steward status        service, sign-in, versions, latest connection link
steward logs [-f|N]   service log
steward restart       restart after editing steward.conf
steward stop          stop and disable autostart
steward start         start and enable autostart
steward update        update Claude Code now (normally automatic)
steward setup         sign in again or redo the first-time prompts
steward uninstall     remove hooks and stop the service; data is kept
```

Steward posts Unraid notifications when the service cannot start and when Claude Code has been updated. New installs also enable Claude's own "input needed" push notification, so the Claude app tells you when a session is waiting on you.

## Where things live

```
/boot/steward/
  steward.sh            the script (the plugin runs this same file)
  steward.conf          arguments passed to claude remote-control
  enabled               present = start at boot
  home/                 CLAUDE_CONFIG_DIR: credentials, settings.json, CLAUDE.md, transcripts
  hooks/bash-guard.sh   PreToolUse hook that inspects every shell command
  workspace/            working directory of every session
  cache/                Claude Code binaries, restored into RAM at boot
  backups/              backups made before Steward changes anything under /boot/config
```

Steward deliberately keeps its data **outside** `/boot/config`. Unraid Connect's Flash Backup uploads all of `/boot/config` to the cloud, and credentials should not travel with it. The only things under `/boot/config` are hooks with no secrets in them: one line in `stop`, the watchdog cron file, and either one line in `go` (script install) or `plugins/steward.plg` (plugin install).

Two caveats remain:

- The webGUI's local **Flash Backup** zips the whole boot device, including `/boot/steward/home`. Treat that zip as a secret.
- If the boot device is exported over SMB, the credentials are reachable over SMB. The installer warns about this; set the flash share's Export to **No** under Main -> Boot Device.

Session transcripts are stored in plain text under `home/projects/` and are synced to Anthropic as part of normal Claude Code operation. The shipped `CLAUDE.md` tells Claude never to read or print password hashes, keys or tokens for this reason.

## Configuration

### Remote Control arguments: `steward.conf`

```sh
RC_ARGS=(--spawn same-dir --capacity 4)
```

- `--spawn same-dir` makes new sessions run directly in `workspace/`. Without it, Claude Code notices that `/boot` is a git repository (it is on every system that uses Connect Flash Backup) and runs sessions in a worktree copy instead.
- `--capacity` is the number of concurrent sessions. Each one is a separate process and uses memory.
- `--permission-mode auto` lets Claude Code's classifier approve low-risk actions and prompt you for the rest. The `deny` and `ask` rules in `settings.json` and the bash-guard hook stay in force. If your plan does not support auto mode, Claude Code falls back to asking for everything and the session shows "auto mode is unavailable".
- `--permission-mode acceptEdits` auto-approves file edits only.

Run `steward restart` after editing.

### Rules for Claude: `home/CLAUDE.md`

Instructions Claude reads at the start of every session: how Unraid's RAM root and `/boot` work, never mixing `/mnt/user` with `/mnt/diskN`, which operations need explicit consent, and which it must never run. Edit it to match your setup. The shipped version is a starting point, not a complete safety policy.

### Permissions: `home/settings.json`

Standard Claude Code settings. The shipped file sets:

- `deny` rules for disk-wiping tools, ZFS pool destruction, New Config, and reading password hashes, SSH/SSL/WireGuard keys, Samba secrets and Steward's own credential files.
- `ask` rules for array control, reboot and shutdown, Docker/VM/share removal, plugin and OS updates, and edits to Steward's own guard files.
- `allow` rules for common read-only commands (ignored in auto mode, where the classifier decides).
- `dialogExpiry` of 10 minutes, so an unanswered permission prompt times out instead of hanging a session.
- The `bash-guard.sh` PreToolUse hook.

Steward only writes these files if they do not exist. Upgrades add newly introduced keys to an existing `settings.json` and leave a backup named `settings.json.before-<version>`; everything you changed is kept.

### The bash-guard hook: `hooks/bash-guard.sh`

Claude Code's own permission rules match the start of a command. The hook looks at the whole command text, so full paths, `sh -c`, pipes and `;` chains are all visible to it. It:

- **denies** disk-wiping and formatting tools, ZFS pool destruction and label clearing, and any command that touches password-hash, key or token paths;
- **asks** before `rm`, `dd`, `truncate`, `mdcmd`/`emcmd`, shutdown and reboot commands, deletion through `xargs`/`find`, removal of ZFS/Docker/VM resources, indirect execution (`eval`, `sh -c`, `base64 -d`), shell writes into `/boot/config`, `git` commands that rewrite the working tree of the `/boot` repository, and changes to the guard files themselves.

Known limits, by design: it matches text, so a harmless command that merely mentions a keyword (for example `echo rm`) is also asked about; and it does not look inside scripts that a command executes. Treat it as a second line of defence behind `settings.json`, not as a sandbox. There is no isolation: Claude runs as root on the host.

## Optional skills

Steward can also give Claude written guides, as Claude Code skills. None are installed by default: a fresh install is the service, the guardrails and nothing else. Install the ones you want:

```
steward skills list              # what is available: skill version, Unraid version it was verified on, range it applies to
steward skills install unraid    # one or more names
steward skills remove unraid     # removes the skill and any backups kept next to it
```

| Skill | What Claude gets |
|---|---|
| `unraid` | How Unraid is put together (RAM root, boot device, array, pools, user shares), what must never be done, what needs your consent, how to change configuration safely, Docker and VM conventions, logs, the API. |
| `unraid-docs` | Where to find correct information for the installed version and how to tell outdated advice apart: the machine's own help text and scripts first, then docs.unraid.net and release notes, then forums. |
| `unraid-tools` | Which command-line tools exist on a stock Unraid and which do not, with full paths for the Unraid-specific ones. |
| `unraid-health` | A read-only health check (array, parity, SMART, pools, boot device, memory, log partition, Docker, syslog) and the report format. |

Each skill records the Unraid version it was verified on and the range it is meant for, and tells Claude to check `/etc/unraid-version` before trusting version-specific details. Installed skills are plain Markdown under `/boot/steward/home/skills/<name>/SKILL.md`; edit them freely. `list` tells you when your copy differs from the shipped one, and reinstalling keeps your edited copy as a backup next to the new file. The files are shipped inside the plugin, so listing and installing need no network; a script install (no plugin) fetches them from this repository instead, and `list` may show "not available offline" there.

## Updates

- **Steward itself** updates through the Plugins page like any other plugin. Your data and configuration are untouched.
- **Claude Code** is checked once a day after 08:00 by the watchdog. A new stable release is installed with Claude Code's own updater (`claude install <version>`), verified against the SHA256 Anthropic publishes for that version, cached to the boot device, and applied by restarting the service once no session has written a transcript for 15 minutes. If sessions are busy, Steward tries again an hour later; if the binary does not verify, it is removed, the previous version stays in use and you get a notification. `steward status` shows both the installed version and the one the running service is using. `steward update` runs the updater right away with the same checks, and restarts the service if the version changed.
- **The pinned first-install version** (`CLAUDE_PIN_VERSION` and its SHA256 in `steward.sh`) moves forward with each Steward release. It only matters for a fresh install or a lost backup; existing installs keep updating through the updater.

## Upgrading from claude-unraid

Install Steward. The installer moves `/boot/claude-code` to `/boot/steward`, leaves a symlink at the old path, removes the old hooks and plugin file, rewrites paths in `settings.json` and `CLAUDE.md` (keeping `.before-steward` backups), and restarts the service under the new name.

## Uninstall

Remove the plugin from the Plugins page, or run `steward uninstall` for a script install. This stops the service and removes the hooks. Credentials, transcripts, settings and the binary cache stay in `/boot/steward` so you can reinstall later; delete that directory yourself if you want them gone.

## Troubleshooting

- `steward status` first, then `steward logs -f`.
- **Server not listed in the app.** Make sure the sign-in used claude.ai, not an API key. Run `steward setup` again to redo the one-time Remote Control confirmation.
- **Sessions run in a worktree copy.** `--spawn same-dir` is missing from `steward.conf`.
- **"auto mode is unavailable".** Your plan does not include auto mode. Remove `--permission-mode auto` from `steward.conf` or switch to `acceptEdits`.
- **Service stops when the array stops.** It does not. If a session was holding a path under `/mnt`, only that session is ended so the array can unmount.
- **No pop-up window from the Settings page.** Allow pop-ups for the Unraid site, or run `steward setup` in a terminal.

## Development

The plugin is a single `steward.plg` with `steward.sh` embedded in it. Keep both in sync; `tests/run-all.sh` fails if they differ.

```sh
tests/run-all.sh           # syntax, XML, plg/script sync, hook cases, auto-update scenarios, smoke test
tests/run-all.sh --quick   # skip the smoke test
```

All tests are safe to run on a live server: the hook test only feeds JSON to the hook, the auto-update test uses mocks, and the smoke test runs against a fake root directory (`STEWARD_TEST_ROOT`) and never starts a service.

Merging to `main` publishes a release. Versioning and the release checklist are in [RELEASING.md](RELEASING.md).

## License

MIT. See [LICENSE](LICENSE).

Trademark notice: "Claude" and "Claude Code" are trademarks of Anthropic PBC. "Unraid" is a trademark of Lime Technology, Inc. Steward is not affiliated with either company.
