#!/usr/bin/env bash
#
# restore-stacks-v2.sh — Automated restore of stacks archived by
# backup-stacks-v2.sh, including services.conf "builtin" restores.
#
# For each archive:
#   - Extracts it into STACKS_DIR
#   - Looks up the stack in services.conf (copied alongside the archives
#     by backup-stacks-v2.sh)
#   - If method=builtin: brings up the full stack, waits for the target
#     container, copies the app-backup/ artifact back in, and runs the
#     recorded restore_cmd
#   - Otherwise (generic / not listed): brings up just the DB service
#     first, waits, restores the auto-detected postgres/mysql/redis dump,
#     then brings up the full stack — same as v1
#
# Usage:
#   ./restore-stacks-v2.sh
#
# Configure the variables below before running.

set -uo pipefail

# Widen PATH to cover common docker install locations. A script run
# non-interactively (even via sudo ./script.sh) doesn't source your
# shell's rc files, so it can end up with a much narrower PATH than your
# interactive terminal has — this is a common cause of "docker: command
# not found" inside a script when `docker` works fine typed directly.
for p in /run/current-system/sw/bin /etc/profiles/per-user/root/bin /usr/local/bin /usr/bin /bin /snap/bin; do
  case ":$PATH:" in
    *":$p:"*) ;;                # already present
    *) [ -d "$p" ] && PATH="$PATH:$p" ;;
  esac
done
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INCOMING_DIR="$SCRIPT_DIR"                        # drop the .tar.gz archives + services.conf right next to this script
STACKS_DIR="${SCRIPT_DIR}/stacks"                 # restored stacks land in a "stacks" folder next to this script
MANIFEST_CONF="${INCOMING_DIR}/services.conf"   # backup-stacks-v2.sh copies this alongside the archives
LOG_FILE="${INCOMING_DIR}/restore.log"

mkdir -p "$STACKS_DIR"

# Same rerun-friendliness as backup-stacks-v2.sh — keep the previous run's
# log as a dated backup, start this run with a clean one.
if [ -f "$LOG_FILE" ]; then
  mv "$LOG_FILE" "${LOG_FILE}.$(date -r "$LOG_FILE" '+%Y%m%d-%H%M%S').old" 2>/dev/null
fi
: > "$LOG_FILE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Finds whichever compose filename convention this stack actually uses —
# same as backup-stacks-v2.sh, needed since we can't assume docker-compose.yml.
find_compose_file() {
  local stack_dir="$1"
  local fname
  for fname in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [ -f "${stack_dir}${fname}" ]; then
      echo "$fname"
      return 0
    fi
  done
  return 1
}

# Finds network names declared "external: true" in a compose file — these
# are expected to already exist on the host (created once, outside any
# single stack) and `docker compose up` fails immediately if they don't.
# On a fresh host nothing has ever created them, so we create whatever
# this stack references, idempotently, before bringing it up.
collect_external_networks() {
  local compose_file="$1"
  awk '
    /^networks:/ { in_net=1; next }
    in_net && /^[^[:space:]]/ { in_net=0 }
    in_net && /^  [a-zA-Z0-9_.-]+:[[:space:]]*$/ {
      name=$1; sub(/:$/, "", name); pending=name; next
    }
    in_net && /external:[[:space:]]*true/ && pending != "" {
      print pending; pending=""
    }
  ' "$compose_file"
}

ensure_external_networks() {
  local compose_file="$1"
  while IFS= read -r net; do
    [ -z "$net" ] && continue
    if ! docker network inspect "$net" >/dev/null 2>&1; then
      log "Creating external network '${net}' (referenced by $(basename "$compose_file") as external, but not found on this host)"
      docker network create "$net" >>"$LOG_FILE" 2>&1
    fi
  done < <(collect_external_networks "$compose_file")
}

# Same lookup as backup-stacks-v2.sh — reads the same file format.
# Prints: container|method|backup_cmd|artifact_path|restore_cmd
lookup_manifest() {
  local stack_name="$1"
  [ -f "$MANIFEST_CONF" ] || { echo "|generic|||"; return; }

  local line
  line=$(grep -v '^\s*#' "$MANIFEST_CONF" | grep -v '^\s*$' | awk -F'|' -v s="$stack_name" '$1 == s {print; exit}')

  if [ -z "$line" ]; then
    echo "|generic|||"
    return
  fi

  local container method backup_cmd artifact_path restore_cmd
  IFS='|' read -r _ container method backup_cmd artifact_path restore_cmd <<< "$line"
  echo "${container}|${method:-generic}|${backup_cmd}|${artifact_path}|${restore_cmd}"
}

first_running_container() {
  local stack_dir="$1"
  local cfile
  cfile=$(find_compose_file "$stack_dir") || return 1
  docker compose -f "${stack_dir}${cfile}" ps -q 2>/dev/null | head -n1 \
    | xargs -r docker inspect --format '{{.Name}}' 2>/dev/null | sed 's#^/##'
}

wait_for_container_healthy() {
  local cname="$1" retries="${2:-30}"
  for _ in $(seq 1 "$retries"); do
    status=$(docker inspect --format '{{.State.Status}}' "$cname" 2>/dev/null)
    if [ "$status" = "running" ]; then
      sleep 3   # give the process inside a moment after the container reports running
      return 0
    fi
    sleep 2
  done
  return 1
}

# --- generic (auto-detected DB) restore, same as v1 ---
restore_database_generic() {
  local cname="$1" engine="$2" dump_dir="$3"
  case "$engine" in
    postgres)
      [ -f "${dump_dir}/dump.sql" ] || return 1
      docker exec -i "$cname" psql -U "${POSTGRES_USER:-postgres}" < "${dump_dir}/dump.sql" >>"$LOG_FILE" 2>&1
      ;;
    mysql)
      [ -f "${dump_dir}/dump.sql" ] || return 1
      # Mirror backup-stacks-v2.sh's preference order: it now dumps just
      # the app's own database using its own credentials by default (no
      # --all-databases, so no CREATE DATABASE/USE statement in the dump)
      # — meaning restore must explicitly target that same database name.
      # Only if that's unavailable does backup fall back to a root,
      # self-contained --all-databases dump, which doesn't need a dbname.
      if docker exec "$cname" sh -c 'test -n "$MYSQL_USER" && test -n "$MYSQL_PASSWORD" && test -n "$MYSQL_DATABASE"' 2>/dev/null; then
        if docker exec -i "$cname" sh -c 'exec mysql -h 127.0.0.1 -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' < "${dump_dir}/dump.sql" >>"$LOG_FILE" 2>&1; then
          return 0
        fi
        log "WARNING: mysql restore with app credentials failed for ${cname}, trying root..."
      fi
      if docker exec -i "$cname" sh -c 'exec mysql -h 127.0.0.1 -u root -p"${MYSQL_ROOT_PASSWORD}"' < "${dump_dir}/dump.sql" >>"$LOG_FILE" 2>&1; then
        return 0
      fi
      log "WARNING: mysql restore with MYSQL_ROOT_PASSWORD failed for ${cname}, trying MARIADB_ROOT_PASSWORD..."
      docker exec -i "$cname" sh -c 'exec mysql -h 127.0.0.1 -u root -p"${MARIADB_ROOT_PASSWORD}"' < "${dump_dir}/dump.sql" >>"$LOG_FILE" 2>&1
      ;;
    redis)
      [ -f "${dump_dir}/dump.rdb" ] || return 1
      docker cp "${dump_dir}/dump.rdb" "${cname}:/data/dump.rdb" >>"$LOG_FILE" 2>&1
      docker restart "$cname" >>"$LOG_FILE" 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

detect_db_service_name() {
  local compose_file="$1"
  grep -E '^\s*image:\s*.*(postgres|mysql|mariadb|redis)' -B 20 "$compose_file" \
    | grep -E '^\s{2}[a-zA-Z0-9_-]+:\s*$' | tail -1 | sed 's/[: ]//g'
}

# --- builtin (manifest-driven) restore ---
run_builtin_restore() {
  local cname="$1" artifact_path="$2" restore_cmd="$3" app_backup_dir="$4"

  if [ ! -e "$app_backup_dir" ] || [ -z "$(ls -A "$app_backup_dir" 2>/dev/null)" ]; then
    log "WARNING: no app-backup artifact found at ${app_backup_dir} — nothing to restore"
    return 1
  fi

  log "Copying artifact from ${app_backup_dir} into ${cname}:${artifact_path}"
  if ! docker cp "${app_backup_dir}/." "${cname}:${artifact_path}" >>"$LOG_FILE" 2>&1; then
    log "WARNING: docker cp into ${cname} failed"
    return 1
  fi

  if [ -z "$restore_cmd" ]; then
    log "WARNING: no restore_cmd recorded in services.conf for this stack — artifact copied in, but you must run the restore command manually"
    return 1
  fi

  log "Running restore command in ${cname}: ${restore_cmd}"
  docker exec "$cname" sh -c "$restore_cmd" >>"$LOG_FILE" 2>&1
}

total=0
ok=0
manual_followup=0

for archive in "$INCOMING_DIR"/*.tar.gz; do
  [ -f "$archive" ] || continue
  stack_name=$(basename "$archive" .tar.gz)
  total=$((total+1))
  log "=== Restoring ${stack_name} ==="

  # --- Extraction: the archive can contain TWO kinds of top-level entries —
  # the stack folder itself (relative to STACKS_DIR), and any bind-mount
  # paths backup-stacks-v2.sh captured from their real absolute location
  # (e.g. "Docker_Data/Files/AppData/Config/Radarr"). Extracting the whole
  # archive into STACKS_DIR would nest that bind-mount data in the wrong
  # place — it needs to go back to "/" so it lands at its real original
  # path. This assumes the new host has the same absolute directory
  # layout as the old one; if it doesn't, relocate these manually after.
  mapfile -t top_level_entries < <(tar -tzf "$archive" 2>>"$LOG_FILE" | awk -F'/' '{print $1}' | sort -u)

  if printf '%s\n' "${top_level_entries[@]}" | grep -qx "$stack_name"; then
    tar -xzf "$archive" -C "$STACKS_DIR" "$stack_name" 2>>"$LOG_FILE"
  else
    log "WARNING: archive ${archive} has no top-level '${stack_name}/' entry — compose file may be missing"
  fi

  for entry in "${top_level_entries[@]}"; do
    [ "$entry" = "$stack_name" ] && continue
    [ -z "$entry" ] && continue
    log "Restoring bind-mount data to its original location: /${entry}"
    tar -xzf "$archive" -C / "$entry" 2>>"$LOG_FILE"
  done

  stack_path="${STACKS_DIR}/${stack_name}/"
  compose_file=$(find_compose_file "$stack_path") || {
    log "WARNING: no compose file found for ${stack_name}, skipping"
    continue
  }
  compose_file="${stack_path}${compose_file}"
  ensure_external_networks "$compose_file"

  IFS='|' read -r m_container m_method m_backup_cmd m_artifact m_restore <<< "$(lookup_manifest "$stack_name")"

  if [ "$m_method" = "builtin" ]; then
    log "Bringing up full stack ${stack_name} (builtin restore needs it running)..."
    (cd "$stack_path" && docker compose up -d) >>"$LOG_FILE" 2>&1

    cname="$m_container"
    [ -z "$cname" ] && cname=$(first_running_container "$stack_path")

    if [ -z "$cname" ] || ! wait_for_container_healthy "$cname"; then
      log "WARNING: container for ${stack_name} never became ready — restore manually from ${stack_path}app-backup"
      manual_followup=$((manual_followup+1))
    elif run_builtin_restore "$cname" "$m_artifact" "$m_restore" "${stack_path}app-backup"; then
      log "Builtin restore succeeded for ${stack_name}"
      ok=$((ok+1))
    else
      log "WARNING: builtin restore incomplete for ${stack_name} — see log above, may need manual follow-up"
      manual_followup=$((manual_followup+1))
    fi

  else
    # generic path — same behavior as v1
    dump_dir="${stack_path}db-backup"
    if [ -d "$dump_dir" ]; then
      db_service=$(detect_db_service_name "$compose_file")
      if [ -n "$db_service" ]; then
        log "Bringing up DB service '${db_service}' for ${stack_name}..."
        (cd "$stack_path" && docker compose up -d "$db_service") >>"$LOG_FILE" 2>&1

        db_cname=$(cd "$stack_path" && docker compose ps -q "$db_service" | xargs -I{} docker inspect --format '{{.Name}}' {} 2>/dev/null | sed 's#^/##')

        if [ -n "$db_cname" ] && wait_for_container_healthy "$db_cname"; then
          engine="postgres"
          [ -f "${dump_dir}/dump.rdb" ] && engine="redis"
          grep -qi mysql "$compose_file" && engine="mysql"

          log "Restoring ${engine} dump into ${db_cname}..."
          if restore_database_generic "$db_cname" "$engine" "$dump_dir"; then
            log "DB restore succeeded for ${stack_name}"
          else
            log "WARNING: DB restore failed for ${stack_name} — restore manually from ${dump_dir}"
            manual_followup=$((manual_followup+1))
          fi
        else
          log "WARNING: DB container for ${stack_name} never became ready — restore manually"
          manual_followup=$((manual_followup+1))
        fi
      else
        log "WARNING: could not auto-detect DB service name for ${stack_name} — restore ${dump_dir} manually"
        manual_followup=$((manual_followup+1))
      fi
    fi

    log "Bringing up full stack ${stack_name}..."
    if (cd "$stack_path" && docker compose up -d) >>"$LOG_FILE" 2>&1; then
      ok=$((ok+1))
      log "${stack_name} is up."
    else
      log "WARNING: ${stack_name} failed to start — check ${LOG_FILE}"
      manual_followup=$((manual_followup+1))
    fi
  fi

  log "=== Done with ${stack_name} ==="
  echo "" >> "$LOG_FILE"
done

log "Restore complete: ${ok}/${total} stacks brought up successfully."
log "${manual_followup} stack(s) need manual follow-up — review WARNING lines in ${LOG_FILE}."
