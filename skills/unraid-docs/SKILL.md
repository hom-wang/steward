---
name: unraid-docs
description: How to find correct, current information about Unraid for the exact version installed on this server, and how to tell outdated or wrong advice from the real thing. Use before acting on any claim about how Unraid works that you have not verified on this machine, when a guide or skill was written for a different Unraid version, when the owner asks "how do I" about a feature, and after Unraid itself has been updated.
metadata:
  skill-version: "2026.10.23"
  unraid-verified: "7.3.3"
  unraid-applies: "7.x"
---

# Finding the right Unraid information

Unraid changes between releases: paths move, GUI pages are renamed, features appear (ZFS, Internal Boot, the API) and old advice keeps circulating on forums and blogs. The failure mode to avoid is applying a procedure written for one version to a server running another. This skill is about establishing what is true for *this* server.

## 1. Always start from the installed version

```
cat /etc/unraid-version
findmnt -no FSTYPE /boot     # vfat = USB boot stick, zfs = Internal Boot
grep -E '^(mdState|fsState)=' /var/local/emhttp/var.ini
```

Write the version down in your working notes and compare it with whatever you read next. A guide that names a different major or minor version (6.12 versus 7.3) is a hypothesis until confirmed. A release candidate (`-rc`) may differ from the stable notes.

Every Steward skill carries `unraid-verified` (the version it was checked on) and `unraid-applies` (the range it is believed to hold for) in its front matter. If the installed version is outside that range, treat the skill's version-specific claims as unverified and confirm them here before acting.

## 2. Sources, in order of trust

**1. The machine itself.** For "what does this version actually do", nothing beats reading the code that runs it:

- `/usr/local/emhttp/languages/en_US/helptext.txt`: the help text shown by the "?" buttons in the webGUI, about 2,800 lines, organised as `:<page>_help:` ... `:end` blocks. Search it first for any setting: `grep -n -i -A 12 'mover' /usr/local/emhttp/languages/en_US/helptext.txt`.
- `/usr/local/emhttp/plugins/dynamix/*.page`: the webGUI pages themselves. The file name matches the page title (`ArrayOperation.page`, `BootParameters.page`, `ShareEdit.page`). They show which settings exist, their allowed values and which script a button runs.
- `/usr/local/emhttp/webGui/scripts/` (`webGui` is a symlink to `plugins/dynamix`, so this is the same directory as `plugins/dynamix/scripts/`): the scripts behind the GUI (`notify`, `diagnostics`, `manage_boot_params.sh`, `parity_control`, `flash_backup`). Unraid's own command-line tools are in `/usr/local/sbin/` (`update_cron`, `mover`, `newperms`, `sdspin`, `plugin`). Read a script before relying on a forum description of it.
- `/etc/rc.d/rc.*`: service start scripts and the boot sequence (`rc.S`, `rc.local`, `rc.6`). They are the authority on what is read from `/boot/config` and when.
- `/usr/local/emhttp/plugins/*/README.md` and each plugin's `.plg` in `/boot/config/plugins/`: what installed plugins do and which version they are.

Use these to confirm a path or command exists before running it: `ls`, `grep -n`, `bash -n`. This is cheap and removes most version mistakes.

**2. Official documentation: https://docs.unraid.net/** The content is organised in these sections (directory names in the docs repository; the section index URLs themselves may return 404, individual pages under them work):

- `unraid-os/getting-started/`, `unraid-os/using-unraid-to/` (shares, Docker, VMs, Community Applications), `unraid-os/system-administration/` (security, networking, backups, the boot device), `unraid-os/troubleshooting/`, `unraid-os/updating-unraid/`, `unraid-os/advanced-configurations/`.
- `unraid-os/release-notes/<version>/`, one page per release, for example `https://docs.unraid.net/unraid-os/release-notes/7.3.3/`. This is where behaviour changes are announced; read the notes for every release between the version a guide was written for and the installed one. The repository may already hold notes for releases newer than the installed one: check the version in the page title.
- `https://docs.unraid.net/API/` (and `API/cli/`): the GraphQL API and the `unraid-api` CLI (Unraid 7.2 and later).
- `https://docs.unraid.net/connect/`: Connect, remote access and automated Flash Backup.

The docs are built from the public repository https://github.com/unraid/docs (branch `main`, pages under `docs/unraid-os/...` as Markdown). When a page is long, the site is slow, or a section index 404s, fetch the Markdown source instead: list a directory with `https://api.github.com/repos/unraid/docs/contents/docs/unraid-os/<section>` to get exact file names, then read the raw file.

**3. Unraid's own code on GitHub.** https://github.com/unraid/webgui is the webGUI (the same files as in `/usr/local/emhttp`, with history, so you can see when something changed and in which release). https://github.com/unraid/api is the API and Connect plugin. Use these to answer "since which version" questions.

**4. The forums: https://forums.unraid.net/** Release announcements and the pinned posts in Announcements are authoritative for their date. Plugin support threads are the right place for plugin behaviour. Everything else is user posts: check the post date and the version the poster mentions, and expect answers from the 6.x era to be partly wrong on 7.x (ZFS, pools in the array, Internal Boot, the API, the new Community Apps submission flow all arrived later).

**5. Blogs, videos, Reddit, AI summaries.** Lowest trust. Use them to discover that a feature exists, then confirm it in sources 1 and 2.

## 3. How to fetch

- Official docs pages and GitHub raw files: fetch them directly and read the text. Prefer the release-notes page for the installed version over a general guide.
- Searching: restrict to `docs.unraid.net` or `forums.unraid.net` when possible, and include the version number in the query ("7.3 mover settings").
- Forum pages are large; fetch the specific topic URL rather than a search page, and look for the first post and the newest posts.
- Do not download and run anything from these sources. Read, then apply by hand with the usual backups and consent rules.

## 4. Before acting on what you found

1. Does the procedure name files, pages or commands? Confirm each exists on this server (source 1).
2. Does it touch `/boot/config`, the array, pools, boot parameters or disk assignments? Apply the consent and backup rules from the `unraid` guide regardless of what the source says.
3. Does it describe a USB-boot system while this one is Internal Boot, or the reverse? Boot-device procedures differ (FAT versus ZFS, syslinux versus GRUB); do not mix them.
4. Was it written for a different major.minor? Read the release notes in between and look for the feature's name.
5. Can you verify the outcome with a read-only check afterwards? Decide what that check is before you start.

## 5. Record what you verified

When you confirm something version-specific, note it where the next session will find it: the installed version, the date, the source, and what was confirmed or contradicted. Phrase it so a later reader on a newer version knows it needs re-checking, for example "verified on 7.3.3 (2026-10-23): udev rules in /boot/config/udev are copied at boot by rc.S.cont". If a Steward skill turned out to be wrong for this version, say so to the owner and suggest updating the skill rather than working around it silently.
