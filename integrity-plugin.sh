#!/bin/bash
# integrity-plugin.sh
# auditd plugin: when an audit event tagged key="integrity" completes,
# diff each file named in that event against its baseline copy and
# append the diff (plus who made the change) to the alert log.
#
# Install to: /usr/local/sbin/integrity-plugin.sh   (chmod 755, owner root)
# Baselines:  $CLEAN + <real path>, e.g. /root/clean/etc/ssh/sshd_config

CLEAN=/root/clean
LOG=/var/log/integrity-alerts.log

# State is tracked per audit event serial number so that interleaved
# events can't contaminate each other.
#   paths[serial] = file paths seen in that event
#   hit[serial]   = 1 if the event carried the integrity key
#   who[serial]   = the SYSCALL line (auid, uid, exe, comm, ...)
#   last[file]    = hash of the last diff logged for that file (dedupe)
declare -A paths hit who last

while read -r line; do
  # Extract the event serial from msg=audit(timestamp:SERIAL)
  s=${line#*msg=audit(}
  s=${s%%)*}
  s=${s##*:}

  case "$line" in
    type=PATH*)
      p=${line#*name=\"}
      p=${p%%\"*}
      paths[$s]="${paths[$s]} $p" ;;

    type=SYSCALL*key=\"integrity\"*)
      hit[$s]=1
      who[$s]=$line ;;

    type=EOE*)
      # End of event: everything for this serial has arrived.
      if [ "${hit[$s]}" = 1 ]; then
        for f in ${paths[$s]}; do
          # Only regular files that have a baseline are diffed
          # (skips directories and unmonitored paths).
          if [ -f "$CLEAN$f" ]; then
            d=$(diff -u "$CLEAN$f" "$f" 2>&1)
            if [ -z "$d" ]; then
              # File matches baseline again: forget its last hash
              unset "last[$f]"
            else
              h=$(echo "$d" | sha256sum)
              # Log only if this diff differs from the last one logged
              if [ "${last[$f]}" != "$h" ]; then
                last[$f]=$h
                {
                  echo "===== $(date) $f ====="
                  echo "${who[$s]}"
                  echo "$d"
                } >> "$LOG"
              fi
            fi
          fi
        done
      fi
      unset "paths[$s]" "hit[$s]" "who[$s]" ;;
  esac
done
