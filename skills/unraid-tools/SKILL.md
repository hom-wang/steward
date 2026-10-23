---
name: unraid-tools
description: Which command-line tools exist on a stock Unraid server and which do not, with full paths for the Unraid-specific ones, so you can pick a working tool instead of probing for it. Use when deciding how to parse, fetch, inspect or script something, and before assuming a tool such as python, nc or tmux is present.
metadata:
  skill-version: "2026.10.23"
  unraid-verified: "7.3.3"
  unraid-applies: "7.x"
---

# Tools available on Unraid

Unraid is a Slackware-based appliance. The installed tool set is fixed by the release, lives in RAM, and cannot be extended persistently with a package manager. What is listed as present below was checked with `command -v` on Unraid 7.3.3. On another version, a quick `command -v <tool>` settles it; the installed package list is `ls /var/log/packages`.

## Present and safe to rely on

**Shell and text.** `bash` 5.3 (`/bin/sh` is bash), GNU coreutils, `gawk` (as `awk`), GNU `sed`, GNU `grep` 3.12 (with `-P`) and `pcregrep`, `find`, `xargs`, `sort`, `diff`, `patch`, `less`, `nano`, `vi` (which is `elvis`, not vim), `file`, `fromdos`/`todos` (no `dos2unix`), `base64`, `md5sum`/`sha256sum`, `openssl`, `timeout`, `flock`, `setsid`, `nohup`, `watch`, `logger`.

**About `grep` inside Claude Code.** In Claude Code's Bash tool, plain `grep` is a shell function that runs a bundled `ugrep`, not GNU grep. It rejects moderately complex patterns ("exceeds complexity limits"), skips binary files, and honours ignore files. For `-P`, long alternations, binary files (`-a`) or anything that behaves oddly, call GNU grep explicitly: `command grep ...` or `/bin/grep ...`.

**Data formats.** `jq` 1.8 for JSON, `xmllint` for XML (validate with `xmllint --noout`, query with `--xpath`), `php` 8.4 CLI (the webGUI language, handy for INI parsing: `php -r '$v = parse_ini_file("/var/local/emhttp/var.ini"); echo $v["mdState"], "\n";'`; never dump `var.ini` whole, it contains `csrf_token` and registration GUIDs), `perl` 5. `node` 22 and `npm` are present because the built-in Unraid API ships them (they arrive with the `dynamix.unraid.net` package, not as a Slackware package); fine for one-off scripts, but not something to build on for older versions.

**Archives.** `tar`, `gzip`, `bzip2`, `xz`, `zstd`, `lz4`, `zip`/`unzip`, `cpio`. No `7z`, no `pigz`.

**Network.** `curl` 8 (with HTTPS), `wget`, `ssh`/`scp`/`rsync`, `ip`, `ss`, `netstat`, `ping`, `traceroute`, `dig`/`nslookup`/`host`, `ethtool`, `arp`, `iptables`, `wg` (WireGuard), `avahi-browse`, `smbclient`, `showmount`. Nothing for packet capture or port scanning.

**Disks and filesystems.** `lsblk`, `blkid`, `smartctl` 7.5 (`-n standby` to avoid waking disks), `hdparm`, `sdparm`, `nvme`, `zpool`/`zfs` 2.4, `btrfs` 7, `xfs_info`, `xfs_repair`, `cryptsetup`, `lsof`, `fuser`, `df`, `du`. The destructive ones (`mkfs.*`, `wipefs`, `sgdisk`, `fdisk`, `parted`, `xfs_repair` without `-n`) also exist; they are never to be used by you, and the shipped bash-guard hook blocks the worst of them.

**System.** `htop`, `top`, `iotop`, `iostat`, `vmstat`, `free`, `uptime`, `sensors`, `lscpu`, `lspci`, `lsusb`, `dmidecode`, `mcelog`, `at`, `crontab` (but see cron below).

**Containers and VMs.** `docker` 29 (no `docker compose` plugin by default), `containerd`, `runc`, `virsh`, `qemu-img`.

**Version control.** `git` 2.56. No `gh`.

## Unraid-specific commands

On `PATH` (`/usr/local/sbin`, `/usr/local/bin`):

| Command | What it is | Notes |
|---|---|---|
| `mdcmd` | array driver control | `mdcmd status` is read-only; anything else changes array state and needs consent. Prefer reading `/proc/mdstat` or `var.ini`. |
| `emcmd` | send a command to `emhttpd` the way the GUI does | Same caution as `mdcmd`. |
| `plugin` | plugin manager | `plugin install <file or URL>`, `plugin check <name>.plg`, `plugin remove <name>.plg`, `plugin update <name>.plg`. Installing or removing plugins needs consent. |
| `unraid-api` | the GraphQL API CLI (7.2 and later) | `unraid-api --help`; API keys via `unraid-api apikey`. |
| `diagnostics` | builds the diagnostics zip into `/boot/logs/` | Read-only; takes a minute. |
| `mover` | the mover | `mover status` is safe; `mover start` moves data and should be the owner's call. |
| `update_cron` | rebuilds the single crontab `/etc/cron.d/root` from `/boot/config/plugins/dynamix/*.cron` and the `.cron` files of installed plugins | Run after adding a `.cron` file. Anything else in `/etc/cron.d` is discarded. |
| `newperms` | the "New Permissions" tool | Recursive chown/chmod; owner only. |
| `sdspin` | Unraid's spin state helper: `sdspin sdX status` (exit 2 = spun down, ATA only), `sdspin sdX up|down` | Status is safe; up/down changes state. |
| `powerdown` | deprecated wrapper around `/sbin/init 0` (`-r` reboots) | All shutdown commands end in `/etc/rc.d/rc.6`, which stops the array and runs `/boot/config/stop`. Consent required; prefer the webGUI. |

Not on `PATH`, call by full path (`webGui` is a symlink to `plugins/dynamix`, so both spellings reach the same scripts):

| Path | Purpose |
|---|---|
| `/usr/local/emhttp/webGui/scripts/notify` | create an Unraid notification: `notify -e "Steward" -s "<subject>" -d "<text>" -i normal` |
| `/usr/local/emhttp/webGui/scripts/parity_control` | pause/resume a running parity check (`pause`, `resume`); consent required |
| `/usr/local/emhttp/webGui/scripts/flash_backup` | the Main -> Flash "Flash backup" button: zips the whole boot device, by default into `/` (RAM); owner's tool, the zip contains secrets |
| `/usr/local/emhttp/webGui/scripts/reload_services` | internal helper: runs service `update` steps only when the webGUI queued a job with `at`; a no-op otherwise, so not a way to apply hand edits |
| `/usr/local/emhttp/plugins/dynamix/scripts/manage_boot_params.sh` | boot parameters (Internal Boot and USB); consent required, never edit grub.cfg by hand |

To apply a hand edit: `/etc/rc.d/rc.samba reload` after `smb-extra.conf`, `/etc/rc.d/rc.nfsd reload` for NFS exports. Share settings (`shares/*.cfg`) have no command-line reload; they are webGUI only.

The rest of `/usr/local/emhttp/webGui/scripts/` are the scripts behind GUI buttons. Read them before using them; most assume the GUI's context.

## Absent (do not try)

`python`/`python3`, `ruby`, `lua`, `bc`, `yq`, `xmlstarlet`, `dos2unix`, `vim` (use `nano` or `elvis`), `tmux`/`screen`, `nc`/`netcat`, `nmap`, `tcpdump`, `mtr`, `nft`, `strace`, `gdb`, `shellcheck`, `gh`, `ncdu`, `docker-compose`, `virt-install`, `sshpass`, `strings`.

Needs that would normally call for one of these:

- Arithmetic: bash `$(( ))`, `awk`, or `jq -n`.
- YAML: there is no parser; treat it as text, or use `node` with care.
- Text extraction from binaries: `grep -a` or `od`.
- Terminal multiplexing or detaching a long job: `setsid nohup <cmd> >log 2>&1 &`, or `at`.
- Port checks: `curl -sS --connect-timeout 3 host:port`, `ss -ltnp`, or `bash -c '</dev/tcp/host/port'`.
- Downloading and running tools: a static binary dropped under `/usr/local/bin` works until reboot. Persisting it means a `go` entry or a plugin, which is the owner's decision. Community plugins (NerdTools, un-get) add packages the same way.

## Things that behave differently from a desktop Linux

- `cron`: dcron. `update_cron` writes one crontab, `/etc/cron.d/root`, from the `.cron` files under `/boot/config/plugins/`; other files in `/etc/cron.d` and `crontab -e` edits are lost on the next run or reboot.
- `sudo` exists but you are already root; there are no other interactive users by default.
- No `systemctl`. Services are `/etc/rc.d/rc.<name> start|stop|restart|status`.
- `/tmp`, `/var/log`, `/root`, `/usr/local/bin` are RAM. `/boot` and `/mnt` are the only places that persist.
- Locales: `C`, `POSIX` and `en_US.UTF-8` only. `C.UTF-8` does not exist, and a shell that exports it makes `perl` and `virsh` print locale warnings. Use `LANG=en_US.UTF-8` for UTF-8 work.
- `/proc/mdstat` is Unraid's `key=value` array status, not the standard Linux md format.
- Docker's data root is a loopback image or directory on a pool (see `/boot/config/docker.cfg`), mounted at `/var/lib/docker`; `df -h /var/lib/docker` shows how full it is.
