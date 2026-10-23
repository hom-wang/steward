---
name: unraid-health
description: Run a read-only health check of an Unraid server (array, parity, disks and SMART, pools, boot device, memory, log partition, Docker, recent errors) and report it as a short table. Use when asked how the server is doing, before risky maintenance, or when something feels slow or wrong.
metadata:
  skill-version: "2026.10.23"
  unraid-verified: "7.3.3"
  unraid-applies: "7.x"
---

# Unraid health check

Everything here is read-only. None of these commands change state, spin up sleeping disks, or need consent. Run them all, then report in the format at the end.

**Version check first:** `cat /etc/unraid-version`. The field names in `var.ini` and `disks.ini` below were verified on 7.3.3. On another major version, confirm a field exists (`grep -c '^mdState=' /var/local/emhttp/var.ini`) before reading it, and consult the `unraid-docs` skill if it does not.

## 1. Array and parity

```
grep -E '^(mdState|fsState|mdNumDisks|mdNumInvalid|mdNumMissing|mdNumDisabled|mdResync|mdResyncAction|mdResyncPos|mdResyncSize|mdResyncDt|mdResyncDb|sbSynced|sbSyncErrs|sbSyncExit|shareMoverActive)=' /var/local/emhttp/var.ini
```

- Healthy: `mdState=STARTED`, `fsState=Started`, and no degraded slot in section 2. Do not judge degradation from `mdNumInvalid`/`mdNumDisabled`/`mdNumMissing`: an empty parity slot raises those counters on a healthy array. `/proc/mdstat` holds the same `key=value` data if `var.ini` is stale.
- Parity check or rebuild in progress: `mdResync` greater than 0. Progress is `mdResyncPos / mdResyncSize`; `mdResyncAction` tells check versus rebuild, and `P` or `Q` means which parity.
- Last parity check: `sbSynced` is its start and `sbSynced2` its end, both Unix timestamps (`date -d @<value>`); `sbSyncErrs` is the error count, `sbSyncExit` the exit code (0 means it finished). A `sbSyncErrs` above 0 is worth flagging even if everything else looks fine.
- `fsNumUnmountable` above 0: a disk or pool did not mount; section 2 shows which.
- `shareMoverActive=yes`: the mover is running, which explains disk activity and slow shares.

## 2. Disks

```
awk -F= '/^\[/{d=$0} /^(device|status|color|rotational|temp|numErrors|fsStatus|fsFree|fsSize|spundown|warning|critical)=/{print d, $0}' /var/local/emhttp/disks.ini
```

- Judge each slot the way the webGUI does, from `status` and `color` together. `status=DISK_OK` with `color=green-on` is good. A `status` containing `_MISSING`, `DISK_DSBL` or `DISK_INVALID`, or a `color` starting with `red-` or `yellow-`, is a missing, disabled or emulated disk: the array is degraded, say so first. `status=DISK_NP_DSBL` with `color=grey-off` and an empty `device` is simply an unused slot (typically a second parity slot) and is not a problem.
- `numErrors` above 0: read errors seen by the md driver since boot. Check syslog for `md: disk<N> read error` and look at SMART.
- `temp` is Celsius; `*` means spun down. Thresholds are in `[display]` of `/boot/config/plugins/dynamix/dynamix.cfg`: `hot`/`max` for spinning disks (defaults 45/55) and `hotssd`/`maxssd` for SSD and NVMe (defaults 60/70); pick the pair from `rotational=` in `disks.ini`. A non-empty `warning`/`critical` on a disk overrides the global values for that disk. Read the thresholds before calling any temperature high.
- `fsStatus=Mounted` for every data disk and pool when the array is started. `Unmountable` is a problem, usually a filesystem that needs a check from the webGUI (Main -> disk -> Check Filesystem), never from the shell.
- Free space: compute `fsFree / fsSize` per disk. Flag anything under 5 percent; the share `floor` setting can make writes fail before 0.

**SMART, without waking sleeping disks.** `emhttpd` already keeps a recent SMART report per slot in `/var/local/emhttp/smart/<slot>`; read those first:

```
for f in /var/local/emhttp/smart/*; do echo "== $f ($(stat -c %y "$f" | cut -c1-16))"; command grep -E 'overall-health|SMART Health|Reallocated_Sector|Reported_Uncorrect|Current_Pending|Offline_Uncorrectable|UDMA_CRC|Percentage Used|Media and Data|Temperature' "$f"; done
```

Only for a device with no cached report, query it directly with `smartctl -n standby -H -A /dev/sdX`: `-n standby` prints a short notice and skips a disk that is spun down; report it as "not checked (spun down)" rather than waking it. `sdspin sdX status` (exit code 2 = spun down) or `hdparm -C /dev/sdX` shows the power state without touching the platters. The attributes to watch: 5 Reallocated, 187 Reported Uncorrectable, 197 Current Pending, 198 Offline Uncorrectable (any increase is bad), 199 UDMA CRC (cabling), and for NVMe "Percentage Used" and "Media and Data Integrity Errors".

## 3. Pools

```
zpool status -x 2>/dev/null; zpool list -o name,size,alloc,free,cap,health 2>/dev/null
btrfs filesystem show 2>/dev/null
for p in /mnt/*/; do case "$p" in /mnt/user/|/mnt/user0/|/mnt/disk*/|/mnt/addons/|/mnt/remotes/|/mnt/rootshare/) ;; *) btrfs device stats "$p" 2>/dev/null | grep -v ' 0$';; esac; done
```

- ZFS: `all pools are healthy` is the answer you want. Anything else, show `zpool status` for that pool and say whether a scrub is running or a device is faulted.
- btrfs: `btrfs device stats` lines that are not zero are accumulated errors; corruption and generation errors matter most.
- Capacity: a pool above 90 percent slows down and can stall Docker and VMs if appdata or the Docker image lives there.

## 4. Boot device, memory, log partition

```
df -h /boot /var/log /
free -m
uptime
ls -laS /var/log | head -n 5
```

- `/var/log` is a small RAM filesystem. Above 80 percent, find what is filling it (the `ls -laS` line) before it hits 100 and services start failing silently.
- `/` (RAM root) filling up usually means something is writing to a path that is not under `/mnt` or `/boot`, often a container with a bad volume mapping or downloads going to `/tmp`.
- Memory: Unraid uses free RAM as page cache, so low "free" is normal; look at `available` and at swap (there usually is none). A ZFS ARC can hold a large share; `awk '/^(size|c_max) /{printf "%s %.1f GiB\n", $1, $3/1073741824}' /proc/spl/kstat/zfs/arcstats` shows its current size and cap (there is no `arc_summary` on Unraid).
- Load average far above the core count with no parity check running points at a stuck process on `/mnt`; `ps -eo pid,stat,wchan:20,cmd | grep ' D '` lists processes in uninterruptible wait.

## 5. Docker and VMs

```
docker ps -a --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null
df -h /var/lib/docker 2>/dev/null
docker system df 2>/dev/null
virsh list --all 2>/dev/null
```

- Containers that show `Restarting`, `Exited (non-zero)` or `Created` (never started, or failed to start) are the ones to look at: `docker logs --tail 50 <name>`.
- `df -h /var/lib/docker` is the fill level of the Docker image or directory (its size is set in Settings -> Docker). Above 80 percent, say so; the fix is the owner's (bigger image, or a container writing inside itself). `docker system df` only tells what is reclaimable.

## 6. Recent errors in the log

```
grep -iE 'error|fail|warn|call trace|oom|read error|segfault' /var/log/syslog | grep -viE 'steward|audit|ntpd' | tail -n 40
```

Group what you find by subsystem (md, filesystem, network, docker, kernel). Do not paste raw log walls; quote the two or three lines that explain a problem and say when they happened.

## 7. Report format

Lead with the verdict in one line: "All healthy", or "Attention: <the one or two things that matter>". Then a table:

| Area | State | Note |
|---|---|---|
| Array | STARTED, 0 invalid/missing | last parity check <date>, 0 errors |
| Disks | all DISK_OK, max 38 C | disk3 at 92 percent full |
| SMART | no reallocated/pending sectors | disk5 spun down, not checked |
| Pools | cache: healthy, 61 percent | |
| Boot / logs | /boot 28G free, /var/log 12 percent | |
| Memory / load | 9.1G available, load 0.8 | |
| Docker / VMs | 14 running, 1 exited | nginx exited (1) 2 h ago |
| Syslog | 3 warnings | all from ntpd, harmless |

Finish with the actions you recommend, each marked as "I can do this now", "needs your OK", or "webGUI only". Do not start any of them inside the health check.
