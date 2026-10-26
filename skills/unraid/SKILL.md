---
name: unraid
description: Operating guide for working as a root admin assistant on an Unraid server. Use whenever a task touches the array, pools, shares, Docker, VMs, /boot/config, boot parameters, notifications, logs or the Unraid API, before deciding how to do it or whether to ask first.
metadata:
  skill-version: "2026.10.23"
  unraid-verified: "7.3.3"
  unraid-applies: "7.2 - 7.3"
---

# Unraid operating guide

You are running directly on the host as root. There is no container around you. Everything here is about doing the job without breaking the array, losing data, or leaving the server in a state the owner cannot recover from remotely.

## 0. Check the version first

This guide was verified on Unraid 7.3.3 and is written for 7.2 through 7.3. Before relying on it:

```
cat /etc/unraid-version
```

If the installed version is outside that range, or newer than the `unraid-verified` value above, treat every path, file name and GUI location here as a hypothesis: confirm it on the machine or in the release notes with the `unraid-docs` skill before acting. Things known to differ in older releases: no Unraid API before 7.2, no `go.safemode` or `/boot/config/udev` handling before 7.2, no Internal Boot on 6.x.

## 1. How the system is put together

**Root filesystem lives in RAM.** Unraid boots from the boot device, unpacks the OS into RAM, and runs from there. Anything you change outside `/boot` and `/mnt` is gone at the next reboot: packages, files in `/etc`, `/usr`, `/root`, cron entries, users. Persistent configuration has two homes:

- `/boot/config/`: Unraid's own configuration. Read at boot, partly rewritten by the webGUI.
- `/boot/config/go`: a shell script run late in boot. The traditional place to re-apply customisations. There is also `go.safemode` (run instead of `go` in safe mode) and `stop` (run at shutdown).

**The boot device.** Either a USB stick (FAT, `/boot` mounted with limited permissions) or, on newer systems, Internal Boot (a ZFS pool mounted at `/boot`). Check with `stat -f -c %T /boot`. It is small and stays mounted when the array is stopped. Do not fill it with large files.

**Array, pools, shares.**

- The *array* is the parity-protected set of data disks: `/mnt/disk1`, `/mnt/disk2`, ... with up to two parity disks that have no mount point.
- *Pools* (cache and others) are separate devices or groups: `/mnt/<poolname>`. They can be btrfs, XFS or ZFS.
- *User shares* are the merged view at `/mnt/user/<share>`: one directory tree that spans the disks and pools included in that share. Files physically live on exactly one disk or pool; the share view is a FUSE overlay.
- The *mover* moves files between a pool and the array on a schedule according to each share's cache setting.

The single most important data rule: **never mix `/mnt/user/...` and `/mnt/diskN/...` (or `/mnt/<pool>/...`) in one copy or move command.** The user-share view and the underlying disk can refer to the same file; copying between them can truncate it to zero bytes. Pick one namespace per command.

**Array state.** `/var/local/emhttp/var.ini` is the live state file written by `emhttpd`. The lines that matter:

```
grep -E '^(mdState|fsState|mdResync|mdResyncAction|mdResyncPos|mdResyncSize|mdNumInvalid|mdNumMissing|mdNumDisabled|sbSynced|sbSyncErrs|shareMoverActive)=' /var/local/emhttp/var.ini
```

- `mdState=STARTED` and `fsState=Started`: array up, shares mounted.
- `mdState=STOPPED`: `/mnt/user`, `/mnt/disk*` and pools are gone; Docker and VMs are down.
- `mdResync` greater than 0: a parity check or rebuild is running; `mdResyncAction` says which, `mdResyncPos`/`mdResyncSize` give progress.
- Whether the array is *degraded* is decided per slot in `disks.ini`, the same way the webGUI does it: a `status` containing `_MISSING`, `DISK_DSBL` or `DISK_INVALID`, or a `color` starting with `red-` or `yellow-`, means a missing, disabled or emulated disk. Say so before doing anything else. Do not use the `mdNumInvalid`/`mdNumDisabled`/`mdNumMissing` counters for this: an empty parity slot (`status=DISK_NP_DSBL`, `color=grey-off`, no `device`) raises them on a perfectly healthy array.
- `/proc/mdstat` on Unraid is not the usual Linux format; it is the same `key=value` list as the `md*`/`sb*` keys in `var.ini`.

Other state files in `/var/local/emhttp/`: `disks.ini` (per-disk device, temperature, error counts, filesystem, free space, and the GUI `color`: `green-on` normal, `grey-off` empty or spun-down slot, `blue-*` new, `yellow-*` emulated or warning, `red-*` disabled or error), `shares.ini` (per-share settings and usage), `network.ini`, `users.ini`, and a cached SMART report per slot in `smart/<slot>`. They are INI files; read them with `grep`/`awk`, do not write them.

**The webGUI and emhttpd.** The webGUI (`/usr/local/emhttp`, nginx + PHP) talks to `emhttpd`, which owns the array. Starting or stopping the array, assigning disks, formatting, parity operations and share settings all go through it. Scripts that back the GUI live in `/usr/local/emhttp/webGui/scripts/` and `/usr/local/emhttp/plugins/dynamix/scripts/`; a few are safe and useful from the shell (see section 6).

## 2. What you must never do, and what needs consent

**Never, under any instruction:**

- New Config, clearing or formatting a disk, `mkfs`, `wipefs`, `sgdisk --zap`, `blkdiscard`, `zpool destroy`, `zpool labelclear`. The owner does these in the webGUI, deliberately.
- Edit `/boot/config/super.dat`, `disk.cfg`, `pools/`: these are the disk assignments. A wrong edit means the array will not start or parity is rebuilt over good data.
- Read or print password hashes, keys, tokens, WireGuard private keys, API keys. The conversation is stored in plain text and synced off the machine.
- Stop the array with `mdcmd stop` or unmount disks by hand. If the array must stop, the owner does it from Main.
- Edit `/boot/grub/grub.cfg` or create `/boot/syslinux/syslinux.cfg` on an Internal Boot system. Boot parameters go through Main -> Flash -> Boot Parameters (backed by `manage_boot_params.sh`). The GUI's CPU-pinning code, the OS updater and `diagnostics` all look for `/boot/syslinux/syslinux.cfg` first and fall back to `grub.cfg`; a stray `syslinux.cfg` makes them write kernel options into a file GRUB never reads.

**Explain the impact and get an explicit yes, one action at a time:**

- Starting or stopping the array; rebooting or shutting down.
- Starting, pausing or cancelling a parity check; any rebuild.
- Changing disk assignments, adding or removing pool devices.
- Deleting a container, VM, share or appdata directory; removing a plugin.
- Updating Unraid itself or any plugin.
- Anything that writes under `/boot/config` (back it up first, see section 3).
- Running a scrub or balance on a pool (long, I/O heavy).

For everything else, prefer the read-only check first, then the smallest change that does the job.

## 3. Changing configuration

**Back up before you touch `/boot/config`.** Copy the file to `/boot/steward/backups/<YYYYMMDD-HHMMSS>/` keeping the relative path, then edit. Tell the owner what changed, how to restore it, and whether a service restart or reboot is needed.

**Three tiers of files under `/boot/config`:**

| Tier | Files | How to change |
|---|---|---|
| Meant for hand editing | `go`, `go.safemode` (optional), `stop`, `udev/*.rules`, `modprobe.d/*.conf`, `smb-extra.conf`, `network-extra.cfg`, `editor.cfg`; with the third-party User Scripts plugin also `plugins/user.scripts/scripts/` | Edit with a backup. Unraid reads them; the webGUI does not rewrite them. |
| Rewritten by the webGUI | `ident.cfg`, `network.cfg`, `share.cfg`, `shares/*.cfg`, `docker.cfg`, `domain.cfg`, `plugins/dockerMan/templates-user/my-*.xml`, `plugins/dynamix/dynamix.cfg`, `plugins/dynamix/monitor.ini`, `plugins/dynamix/*.cron` | Use the webGUI when there is a page for it. A hand edit works until the next Apply on that page, and it does not take effect until the matching service reloads. `shares/*.cfg` has no command-line reload at all: share settings are webGUI only. |
| Never by hand | `super.dat`, `disk.cfg`, `pools/`, `passwd`, `shadow`, `smbpasswd`, `secrets.tdb`, `ssh/`, `ssl/`, `wireguard/`, `*.key`, `machine-id`, `network-rules.cfg` | Only through the webGUI, or not at all. |

Notes:

- `rc.local` runs `go` through `fromdos` first, so Windows line endings are tolerated there. Other files are not so forgiving.
- Unraid's `rc.local` may itself rewrite `go` (it strips certain lines and leaves `go~` behind). A change to `go` in the Flash Backup history is not necessarily human.
- Scripts kept on `/boot` should be run as `bash /boot/path/script.sh` rather than relying on the execute bit.
- Cron: drop a file into `/boot/config/plugins/dynamix/<name>.cron` and run `/usr/local/sbin/update_cron`. It concatenates those files (plus the `.cron` files of installed plugins) into the single crontab `/etc/cron.d/root`, so anything else placed in `/etc/cron.d` is discarded on the next run, and `crontab -e` edits RAM.

**Services.** Most are SysV-style under `/etc/rc.d/`: `rc.samba`, `rc.nfsd`, `rc.docker`, `rc.libvirt`, `rc.nginx`, `rc.sshd`, `rc.ntpd`, `rc.avahidaemon`. Use `restart` or `reload` sparingly and say which clients will be interrupted. After editing `smb-extra.conf` by hand, `/etc/rc.d/rc.samba reload` regenerates the Samba configuration and reloads it without dropping sessions; `/etc/rc.d/rc.nfsd reload` does the same for NFS exports. `/usr/local/emhttp/webGui/scripts/reload_services` is not a general reload: it only runs when the webGUI has queued a job with `at`, and does nothing otherwise.

## 4. Docker

Containers on Unraid are defined by templates: `/boot/config/plugins/dockerMan/templates-user/my-<name>.xml`. The webGUI builds the `docker run` from the template, and only containers with a template can be edited, updated or re-created from the Docker page.

- Do not create long-lived containers with `docker run` by hand. They will work, but they have no template, so the owner cannot manage them in the webGUI and they are lost on the next "update all". Create them in the webGUI (Add Container, or Community Applications) or write a template and let the owner apply it.
- Read-only inspection is fine and useful: `docker ps -a`, `docker logs --tail 200 <name>`, `docker inspect <name>`, `docker stats --no-stream`, `docker image ls`, `docker system df`.
- Starting, stopping and restarting a container is a routine operation: `docker start|stop|restart <name>`. Say what depends on it first (reverse proxy, databases).
- Removing containers, images, volumes or networks needs consent. `docker system prune` and `docker volume rm` destroy data.
- Updates: the Docker page's "check for updates" and Community Applications handle image updates so the template stays in sync. `docker pull` by hand leaves the webGUI showing stale state.
- appdata lives in the share set by `docker.cfg` (usually `/mnt/user/appdata` on a pool). Treat it as the container's database: back it up before changing it, never `chmod -R` it.
- The Docker image or directory itself (`docker.cfg`: `DOCKER_IMAGE_FILE`) must not be deleted or resized by hand.

## 5. Virtual machines

libvirt manages VMs; definitions are in `/etc/libvirt/qemu/*.xml`, persisted to the libvirt image on the pool. `virsh list --all`, `virsh dominfo <vm>`, `virsh domstats <vm>` are safe. `virsh shutdown <vm>` is a graceful request and acceptable with consent; `virsh destroy <vm>` is a hard power-off and `virsh undefine <vm>` deletes the definition: both need explicit consent. VM disks (vdisks) live under the domains share; never delete or shrink them.

## 6. Useful commands that are safe

```
cat /etc/unraid-version                                   # OS version
grep -E '^(mdState|fsState)=' /var/local/emhttp/var.ini   # array state
df -h /boot /var/log                                      # boot device and the RAM log partition
free -m; uptime                                           # memory, load
zpool status; zpool list                                  # ZFS pools (if any)
btrfs filesystem show; btrfs device stats /mnt/<pool>     # btrfs pools
smartctl -n standby -H -A /dev/sdX                        # SMART without spinning up a sleeping disk
tail -n 200 /var/log/syslog                               # system log (RAM; the previous boot's log is /boot/logs/syslog-previous)
diagnostics                                               # anonymised diagnostics zip into /boot/logs (never -a without the owner)
command grep -P '...' file                                # GNU grep; plain "grep" inside Claude Code is a ugrep shim with pattern limits
/usr/local/emhttp/webGui/scripts/notify -e "Steward" -s "<subject>" -d "<text>" -i normal   # Unraid notification
```

Things that look harmless but are not:

- `mdcmd` anything: it is the array control interface. Even `mdcmd status` is fine, but it is simpler to read `/proc/mdstat` or `var.ini`. Never `mdcmd stop`, `mdcmd nocheck`, `mdcmd check` without consent.
- `smartctl` without `-n standby` spins up sleeping disks. `hdparm -C /dev/sdX` shows the power state without waking it.
- `du` or `find` across `/mnt/user` spins up every disk and can take hours. Ask before scanning whole shares; prefer `shares.ini` for usage numbers.
- A shell whose working directory is under `/mnt` prevents the array from stopping. Use absolute paths and keep `cd` out of `/mnt`.

## 7. Files you create on shares

New files under `/mnt/user/...` are owned by root and SMB users cannot open them. After creating files there: `chown nobody:users <files>` and `chmod ug+rw <files>`, only on the files you created. Never run `chown -R` or `chmod -R` on appdata, system, domains or a whole share; the Unraid "New Permissions" tool exists for that and the owner runs it. Avoid `cp -a`/`rsync -a` from root-owned sources into shares for the same reason.

## 8. Logs and diagnostics

- `/var/log/syslog` is in RAM and limited in size. If `/var/log` is full (`df -h /var/log`), something is logging in a loop; find it with `ls -laS /var/log` before anything else.
- By default the syslog is copied to the boot device at shutdown and shows up as `/boot/logs/syslog-previous` after the next boot. Continuous mirroring to the boot device or a remote server is a separate setting under Settings -> Syslog Server.
- `diagnostics` writes `/boot/logs/<host>-diagnostics-<date>.zip`. The default run anonymises IPs, user names and registration data; `diagnostics -a` does not. Tell the owner before sending it anywhere.
- Container logs: `docker logs`. VM logs: `/var/log/libvirt/qemu/<vm>.log`. Mover: enable mover logging in Settings -> Scheduler, then grep syslog for `move:`.
- When a report says "disk error", look at `disks.ini` `numErrors` and the SMART attributes (5, 187, 197, 198, 199) before concluding anything. Read errors during a parity check are logged as `md: disk<N> read error` lines.

## 9. The Unraid API

Unraid 7.2 and later include a GraphQL API with a CLI: `unraid-api --help`. Docs: https://docs.unraid.net/API/. Creating an API key is `unraid-api apikey --create`: ask the owner first, use the narrowest role that works, store the key at `/boot/steward/home/unraid-api.key` with mode 600, and never print it. The API is the right tool when you need structured data (array, disks, shares, containers, notifications) rather than parsing INI files.

## 10. Reporting back

Lead with the state that matters (array degraded, disk errors, pool near full), then what you did, then what you did not do and why. For anything long-running or anything that now needs a decision, send an Unraid notification so the owner sees it without opening the conversation. Keep numbers in a short table. Say plainly when something could not be verified.
