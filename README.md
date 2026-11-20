# File Integrity Monitor with auditd

Detect changes to important files (starting with `/etc/ssh/sshd_config`) and log **who** changed them and **exactly what** changed.

## How it works

```
file is modified
      │
      ▼
kernel audit rule (-w ... -k integrity)   → logs the event, stamps key="integrity"
      │
      ▼
auditd streams the event to the plugin    → integrity-plugin.sh (long-running)
      │
      ▼
plugin collects the event's file paths, and when the event ends (EOE)
diffs each file against its clean baseline copy
      │
      ▼
/var/log/integrity-alerts.log             → who-line + unified diff
```

| Piece | Location | Purpose |
|---|---|---|
| Watch rule | `/etc/audit/rules.d/integrity.rules` | Tells the kernel which files to watch and tags events with `integrity` |
| Baselines | `/root/clean/<real path>` | Known-good copies, mirroring real paths |
| Plugin | `/usr/local/sbin/integrity-plugin.sh` | Reads events, diffs changed files, writes alerts |
| Plugin config | `/etc/audit/plugins.d/integrity.conf` | Tells auditd to start the plugin |
| Alert log | `/var/log/integrity-alerts.log` | Output: who, when, and the diff |

The plugin script lives in its own file next to this document: **[`integrity-plugin.sh`](./integrity-plugin.sh)**.

> Run every command below as root (`sudo -i`).

---

## 1. Install and start auditd

**Fedora / RHEL**
```bash
dnf install -y audit
systemctl enable --now auditd
```

**Debian / Ubuntu**
```bash
apt-get update && apt-get install -y auditd
systemctl enable --now auditd
```

## 2. Fedora only: disable the "never audit" default

Fedora ships a rule (`-a task,never`) that suppresses syscall auditing, so no watch rule can fire until it is removed. Skip this step on Debian/Ubuntu.

```bash
grep -rn "task" /etc/audit/rules.d/
sed -i 's/^-a task,never/#&/' /etc/audit/rules.d/audit.rules
grep -n "task" /etc/audit/rules.d/audit.rules
```

The last command should show the line starting with `#`. Other hits under `/etc/audit/audit.rules` and `/usr/share/audit-rules/` are generated or packaged copies and can be ignored.

## 3. Save a clean baseline

Baselines mirror the real path under `/root/clean`. The plugin finds a file's baseline by prepending `/root/clean` to its path.

```bash
mkdir -p /root/clean && chmod 700 /root/clean
cd / && cp -p --parents etc/ssh/sshd_config /root/clean/
```

This creates `/root/clean/etc/ssh/sshd_config`.

## 4. Install the plugin

Copy [`integrity-plugin.sh`](./integrity-plugin.sh) to its final location with root-only permissions:

```bash
install -m 755 -o root -g root integrity-plugin.sh /usr/local/sbin/integrity-plugin.sh
```

Check the syntax:

```bash
bash -n /usr/local/sbin/integrity-plugin.sh && echo "syntax ok"
```

## 5. Register the plugin with auditd

```bash
cat > /etc/audit/plugins.d/integrity.conf <<'EOF'
active = yes
direction = out
path = /usr/local/sbin/integrity-plugin.sh
type = always
format = string
EOF
```

> Older auditd versions use `/etc/audisp/plugins.d/` instead. Check with `ls -d /etc/audit/plugins.d /etc/audisp/plugins.d`.

## 6. Add the watch rule

```bash
echo '-w /etc/ssh/sshd_config -p wa -k integrity' > /etc/audit/rules.d/integrity.rules
```

`-p wa` logs writes and attribute changes. `-k integrity` is the key the plugin looks for.

## 7. Load the rules and restart auditd

```bash
augenrules --load
service auditd restart
```

Use `service`, not `systemctl`, which refuses to restart auditd.

Verify:

```bash
auditctl -l                           # should list the -w rule (and no "task,never" line)
ps -ef | grep [i]ntegrity-plugin      # should show /bin/bash /usr/local/sbin/integrity-plugin.sh
```

The warning "Old style watch rules are slower" is harmless.

## 8. Test it

```bash
echo "# test" | tee -a /etc/ssh/sshd_config
sleep 3
cat /var/log/integrity-alerts.log
```

Expected: a `=====` header with the date and file, the audit SYSCALL line (user, process), and a unified diff containing `+# test`.

`tee` is used because it is a fresh process and is certain to be audited. Revert the test change:

```bash
cp -p /root/clean/etc/ssh/sshd_config /etc/ssh/sshd_config
```

---

## Adding another file later

Example: `/etc/sudoers`. No plugin change or restart is needed.

```bash
cd / && cp -p --parents etc/sudoers /root/clean/
echo '-w /etc/sudoers -p wa -k integrity' >> /etc/audit/rules.d/integrity.rules
augenrules --load
```

Note `>>` (append), so existing rules are kept. For a directory, use `cp -rp --parents etc/sudoers.d /root/clean/`. Brand-new files in a watched directory have no baseline, so they appear in the audit log but are not diffed.

## After a legitimate edit

Refresh that file's baseline, or every later alert will keep showing the cumulative diff:

```bash
cd / && cp -p --parents etc/ssh/sshd_config /root/clean/
```

## Behavior notes

- **Diffs are cumulative** against the baseline, not against the previous change.
- **Duplicate suppression:** one save can produce several audit events. The plugin logs only when the diff for a file differs from the last one it logged, so a real new change is never suppressed.
- **Dedupe memory** lives in the running plugin and resets when auditd restarts. After a restart, an already-modified file is logged once more.
- **Metadata-only changes** (`chmod`, `touch`) leave the diff unchanged, so they are not logged here. Use `ausearch -k integrity -i` to see who did it.
- **Paths with spaces** are not handled by the plugin's `for` loop. Fine for typical config files.
- **Immutable rules (`-e 2`)** are optional hardening. Add them last in a file that sorts last (for example `99-finalize.rules`); after that, rule changes require a reboot.

## Hardening recommendations

- Keep a copy of `/root/clean` **off the machine**. A compromised root can edit the baseline too.
- Ship audit events to another host (`audisp-remote`) so the audit trail can't be rewritten locally.
- Check occasionally for dropped events: `auditctl -s` should show `lost: 0`.
- Optional safety net: a cron job such as `diff -rq /root/clean/etc/ssh /etc/ssh`, mailing any output, catches changes made while auditd was down.

---

## Troubleshooting

Work down this list; each step checks one link in the chain.

### 1. Is the rule loaded?
```bash
auditctl -l
```
Should list `-w /etc/ssh/sshd_config -p wa -k integrity`. If it shows `-a never,task` or `-a task,never`, repeat [step 2](#2-fedora-only-disable-the-never-audit-default), then force a reload:
```bash
augenrules
auditctl -D
auditctl -R /etc/audit/audit.rules
auditctl -l
```
(`auditctl -D` fails if rules are locked with `-e 2`; reboot in that case.)

### 2. Are events being logged with the key?
```bash
ausearch -k integrity -i | tail
```
No output means the rule isn't matching or auditing is suppressed. Check `auditctl -s` shows `enabled 1`.

### 3. Is the plugin running?
```bash
ps -ef | grep [i]ntegrity-plugin
```
If missing:
```bash
ls -l /usr/local/sbin/integrity-plugin.sh /etc/audit/plugins.d/
cat /etc/audit/plugins.d/integrity.conf
head -3 /usr/local/sbin/integrity-plugin.sh
bash -n /usr/local/sbin/integrity-plugin.sh; echo "syntax exit: $?"
/usr/local/sbin/integrity-plugin.sh </dev/null; echo "run exit: $?"
journalctl -u auditd -n 40 --no-pager
```
- The script must be executable and its first line exactly `#!/bin/bash`.
- `path =` in `integrity.conf` must match the script location exactly.
- Running it with empty input should exit immediately with `run exit: 0`; any error printed here explains why auditd can't keep it alive.
- The journal logs plugin start failures. If it complains about a line in `integrity.conf`, compare with a shipped config (`cat /etc/audit/plugins.d/syslog.conf`) and copy any fields yours lacks (such as `args =`). Newer auditd versions (4.x) handle plugins internally and can be stricter about these files.
- Plugins only start when auditd starts, so always `service auditd restart` after editing the plugin or its config.

### 4. Fedora: is SELinux blocking it?
```bash
getenforce
ausearch -m avc -ts recent | tail
```
Denials mentioning `auditd_t` mean SELinux is blocking the plugin from running, reading `/root/clean`, or writing the log. Diagnose temporarily with `setenforce 0`, restart auditd, and check `ps` again. If that fixes it, build a policy from the denials rather than leaving SELinux permissive:
```bash
dnf install -y policycoreutils-python-utils
ausearch -m avc -ts recent | audit2allow -M integrity
cat integrity.te          # review before loading
semodule -i integrity.pp
service auditd restart
```
This may take more than one cycle, since later denials only appear after earlier ones are fixed. If the plugin still doesn't run in permissive mode, SELinux isn't the cause.

### 5. Log file is empty or missing but the plugin runs
- Confirm the baseline exists at the mirrored path: `ls -l /root/clean/etc/ssh/sshd_config`.
- Confirm there is a real difference: `diff -u /root/clean/etc/ssh/sshd_config /etc/ssh/sshd_config`. An empty diff logs nothing.
- If the shell you're testing from predates the rule change, use a fresh process such as `tee` to trigger events.
- If `EOE` lines don't reach the plugin on your auditd version, the trigger can be switched to the `SYSCALL` line instead.

---

## Quick reference

| Task | Command |
|---|---|
| List loaded rules | `auditctl -l` |
| Show who/when for events | `ausearch -k integrity -i` |
| Restart auditd | `service auditd restart` |
| Reload rules from `rules.d` | `augenrules --load` |
| Check for dropped events | `auditctl -s` |
| Watch alerts live | `tail -f /var/log/integrity-alerts.log` |
