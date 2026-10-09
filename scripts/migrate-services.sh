#!/usr/bin/env bash
#
# migrate-services.sh — move the services backed up from vmc01 (Docker Compose)
# onto this host's vexos server modules.
#
# What it does, per service FOUND IN THE BACKUP (services that aren't in the
# backup are never touched, so nothing is enabled that has no data to restore):
#   1. adds   vexos.server.<module>.enable = true;   to /etc/nixos/server-services.nix
#   2. runs   just rebuild
#   3. stops the service, moves any data already there aside
#      (<dest>.pre-restore-<time>), copies the backed-up data into the module's
#      real data location, fixes ownership, starts the service again
#
# It does NOT run the backup script's restore mode and never starts compose stacks.
#
# Usage:
#   ./migrate-services.sh  <vmc01-migration.zip | folder-with-.tar.gz-files>          # dry run (changes nothing)
#   ./migrate-services.sh  --apply  <vmc01-migration.zip | folder>                    # do it
#
# Options:
#   --apply            actually make changes (default is a dry run)
#   --only a,b,c       only these services (sonarr,radarr,lidarr,prowlarr,sabnzbd,bazarr,
#                      maintainerr,tautulli,code-server,wishlist,grimmory)
#   --skip a,b         leave these out
#   --skip-rebuild     don't run `just rebuild` (you already did, or will)
#   --force            redo a service even if it was already migrated by this script
#   --repo DIR         where your vexos-nix checkout (with the justfile) is
#   --services-file F  default /etc/nixos/server-services.nix
#   --keep-staging     don't delete the extracted backup when finished
#   --test-root DIR    (testing only) treat DIR as / and skip systemctl/chown/docker/rebuild
#
# Run it as your normal user (it uses sudo where needed).

set -uo pipefail

APPLY=0; SKIP_REBUILD=0; FORCE=0; KEEP=0
ONLY=""; SKIP=""; REPO=""; SERVICES_FILE=""; TEST_ROOT=""; SOURCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --only) ONLY="$2"; shift ;;
    --skip) SKIP="$2"; shift ;;
    --skip-rebuild) SKIP_REBUILD=1 ;;
    --force) FORCE=1 ;;
    --repo) REPO="$2"; shift ;;
    --services-file) SERVICES_FILE="$2"; shift ;;
    --keep-staging) KEEP=1 ;;
    --test-root) TEST_ROOT="$2"; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) SOURCE="$1" ;;
  esac
  shift
done

[ -n "$SOURCE" ] || { echo "Give me the backup zip (or the folder holding the .tar.gz files). Try --help." >&2; exit 2; }
[ -e "$SOURCE" ] || { echo "Not found: $SOURCE" >&2; exit 2; }

ROOT="$TEST_ROOT"
if [ -n "$ROOT" ] || [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
[ -n "$SERVICES_FILE" ] || SERVICES_FILE="$ROOT/etc/nixos/server-services.nix"
TS="$(date +%Y%m%d-%H%M%S)"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
doit() { # doit <description> <cmd...>   (prints in dry run, runs on --apply)
  local d="$1"; shift
  if [ "$APPLY" -eq 1 ]; then "$@"; else say "  [dry-run] $d"; fi
}

RESULTS=()
result() { RESULTS+=("$1|$2|$3"); }
NOTES=()
note() { NOTES+=("$1"); }

# ---------------------------------------------------------------------------
# Work area
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vexos-migrate.XXXXXX")" || exit 1
META="$WORK/meta"; mkdir -p "$META"
STAGE="/var/tmp/vexos-migrate-stage-$TS"
[ -n "$ROOT" ] && STAGE="$ROOT/var/tmp/vexos-migrate-stage-$TS"
cleanup() {
  rm -rf "$WORK"
  if [ "$APPLY" -eq 1 ] && [ "$KEEP" -eq 0 ] && [ -d "$STAGE" ]; then $SUDO rm -rf "$STAGE"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Find the .tar.gz archives (unzip first if given a zip)
# ---------------------------------------------------------------------------
extract_zip() { # extract_zip <zip> <dest>
  local z="$1" d="$2"
  mkdir -p "$d"
  if command -v unzip >/dev/null 2>&1; then unzip -q -o "$z" -d "$d" && return 0; fi
  if command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$z" -C "$d" && return 0; fi
  if command -v python3 >/dev/null 2>&1; then python3 -m zipfile -e "$z" "$d" && return 0; fi
  if command -v nix >/dev/null 2>&1; then
    nix shell nixpkgs#unzip -c unzip -q -o "$z" -d "$d" && return 0
  fi
  return 1
}

step "Reading the backup"
if [ -d "$SOURCE" ]; then
  ARCH_ROOT="$SOURCE"
else
  say "Unzipping $(basename "$SOURCE") ..."
  ARCH_ROOT="$WORK/zip"
  extract_zip "$SOURCE" "$ARCH_ROOT" || { echo "Couldn't unzip it (no unzip/bsdtar/python3/nix found)." >&2; exit 1; }
fi

ARCHIVES=()
while IFS= read -r f; do ARCHIVES+=("$f"); done < <(find "$ARCH_ROOT" -name '*.tar.gz' -type f | sort)
[ "${#ARCHIVES[@]}" -gt 0 ] || { echo "No .tar.gz archives found in $SOURCE" >&2; exit 1; }
say "Found ${#ARCHIVES[@]} service archives."

# ---------------------------------------------------------------------------
# 2. Compose-file parser (POSIX awk; handles .env substitution)
# ---------------------------------------------------------------------------
cat > "$WORK/parse.awk" <<'AWK'
function subst(s,   out, m, name, def, hasdef, v) {
  out = ""
  while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_]*(:?-[^}]*)?\}|\$[A-Za-z_][A-Za-z0-9_]*/)) {
    m = substr(s, RSTART, RLENGTH)
    out = out substr(s, 1, RSTART - 1)
    s = substr(s, RSTART + RLENGTH)
    hasdef = 0; def = ""
    if (substr(m, 2, 1) == "{") {
      m = substr(m, 3, length(m) - 3)
      if (match(m, /:?-/)) { def = substr(m, RSTART + RLENGTH); name = substr(m, 1, RSTART - 1); hasdef = 1 }
      else name = m
    } else name = substr(m, 2)
    if ((name in env) && env[name] != "") v = env[name]
    else if (hasdef) v = def
    else v = ""
    out = out v
  }
  return out s
}
function unq(v) { gsub(/^["']|["']$/, "", v); return v }
FILENAME == envf {
  l = $0
  if (l ~ /^[ \t]*#/ || l !~ /=/) next
  sub(/^[ \t]*(export[ \t]+)?/, "", l)
  k = substr(l, 1, index(l, "=") - 1)
  v = substr(l, index(l, "=") + 1)
  sub(/[ \t]+$/, "", v)
  env[k] = unq(v)
  next
}
{
  line = $0
  sub(/^[ \t]*#.*/, "", line)
  sub(/[ \t]+#.*$/, "", line)
  if (line ~ /^[ \t]*$/) next
  match(line, /^[ \t]*/); ind = RLENGTH
  txt = substr(line, ind + 1); sub(/[ \t]+$/, "", txt)
  if (ind == 0) { insvc = (txt ~ /^services:/); svcind = -1; cur = ""; invol = 0; inenv = 0; next }
  if (!insvc) next
  if (svcind < 0) svcind = ind
  if (ind == svcind) {
    if (txt ~ /:$/) { cur = unq(substr(txt, 1, length(txt) - 1)); invol = 0; inenv = 0; keyind = -1; print "SVC|" cur }
    next
  }
  if (cur == "") next
  if (keyind < 0) keyind = ind
  if (ind == keyind) {
    invol = 0; inenv = 0
    if (txt ~ /^image:/) { v = txt; sub(/^image:[ \t]*/, "", v); print "IMG|" cur "|" subst(unq(v)) }
    else if (txt ~ /^volumes:[ \t]*$/) invol = 1
    else if (txt ~ /^environment:[ \t]*$/) inenv = 1
    next
  }
  if (ind > keyind) {
    if (invol && txt ~ /^-/) {
      v = txt; sub(/^-[ \t]*/, "", v)
      if (v ~ /^type:/) { print "WARN|" cur "|long-syntax volume entry not parsed"; next }
      v = subst(unq(v))
      n = split(v, p, ":")
      if (n >= 2) {
        src = p[1]; dst = p[2]
        if (src ~ /^\//) kind = "bind"
        else if (src ~ /^\./) kind = "rel"
        else kind = "named"
        if (kind == "rel") { if (src == ".") src = ""; sub(/^\.\//, "", src) }
        print "MNT|" cur "|" kind "|" src "|" dst
      }
    } else if (inenv) {
      v = txt; sub(/^-[ \t]*/, "", v); v = unq(v)
      i = match(v, /[=:]/)
      if (i > 0) {
        key = substr(v, 1, i - 1); val = substr(v, i + 1); sub(/^[ \t]+/, "", val)
        if (key ~ /^(DOMAINS|IP4_DOMAINS|IP6_DOMAINS|CF_DOMAINS)$/) print "ENV|" cur "|" key "|" subst(unq(val))
      }
    }
  }
}
AWK

COMPOSE_NAMES="compose.yaml compose.yml docker-compose.yaml docker-compose.yml"

# ---------------------------------------------------------------------------
# 3. Look inside every archive: list contents, read compose + .env, parse
# ---------------------------------------------------------------------------
STACKS=()
for a in "${ARCHIVES[@]}"; do
  s="$(basename "$a" .tar.gz)"
  STACKS+=("$s")
  mkdir -p "$META/$s"
  tar -tzf "$a" 2>/dev/null | sed 's#^\./##' > "$META/$s/list.txt"
  for c in $COMPOSE_NAMES .env; do
    tar -xzf "$a" -C "$META/$s" "$s/$c" 2>/dev/null || true
  done
  cf=""
  for c in $COMPOSE_NAMES; do [ -f "$META/$s/$s/$c" ] && { cf="$META/$s/$s/$c"; break; }; done
  envf="$META/$s/$s/.env"; [ -f "$envf" ] || { envf="$META/$s/empty.env"; : > "$envf"; }
  if [ -n "$cf" ]; then
    awk -v envf="$envf" -f "$WORK/parse.awk" "$envf" "$cf" > "$META/$s/parsed.txt" 2>/dev/null || : > "$META/$s/parsed.txt"
  else
    : > "$META/$s/parsed.txt"
    warn "$s: no compose file in the archive — can't work out where its data goes"
  fi
done

# ---------------------------------------------------------------------------
# 4. Work out which service each container is
# ---------------------------------------------------------------------------
# classify <image> <svc> <stack>  ->  app key, "db", or "skip:<why>"
classify() {
  local img svc stk probe
  img="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  svc="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  stk="$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')"
  case "$img" in
    *mariadb*|*mysql*|*postgres*|*redis*|*valkey*) echo db; return ;;
  esac
  for probe in "$img" "$svc" "$stk"; do
    case "$probe" in
      *homepage*)              echo "skip:homepage (you're not using it)"; return ;;
      *mealie*)                echo "skip:mealie (already restored)"; return ;;
      *humidor*)               echo "skip:humidor (already restored)"; return ;;
      *home-registry*|*homeregistry*) echo "skip:home-registry (already restored)"; return ;;
      *sonarr*)                echo sonarr; return ;;
      *radarr*)                echo radarr; return ;;
      *lidarr*)                echo lidarr; return ;;
      *prowlarr*)              echo prowlarr; return ;;
      *sabnzbd*)               echo sabnzbd; return ;;
      *bazarr*)                echo bazarr; return ;;
      *maintainerr*)           echo maintainerr; return ;;
      *qbittorrent*)           echo qbittorrent; return ;;
      *tautulli*)              echo tautulli; return ;;
      *code-server*)           echo code-server; return ;;
      *wishlist*)              echo wishlist; return ;;
      *grimmory*|*booklore*)   echo grimmory; return ;;
      *cloudflare*ddns*|*cloudflare-ddns*|*ddns-updater*) echo cloudflare-ddns; return ;;
      *bookshelf*)             echo bookshelf; return ;;
      *watchtower*|*rustdesk*|*nextcloud*|*jellyseerr*|*overseerr*|*homebox*|*diun*|*calibre*|*dockge*|*readarr*)
                               echo "skip:deprecated"; return ;;
    esac
  done
  echo "unknown"
}

declare -A APP_STACK APP_SVC APP_IMAGE
FOUND_APPS=()
UNKNOWN=()
SKIPPED=()
for s in "${STACKS[@]}"; do
  P="$META/$s/parsed.txt"
  while IFS='|' read -r tag svc img; do
    [ "$tag" = "IMG" ] || continue
    k="$(classify "$img" "$svc" "$s")"
    case "$k" in
      db) ;;
      skip:*) if [ "$s" = "$svc" ]; then SKIPPED+=("$s → ${k#skip:}"); else SKIPPED+=("$s/$svc → ${k#skip:}"); fi ;;
      unknown) UNKNOWN+=("$s/$svc ($img)") ;;
      *) if [ -z "${APP_STACK[$k]:-}" ]; then
           APP_STACK[$k]="$s"; APP_SVC[$k]="$svc"; APP_IMAGE[$k]="$img"; FOUND_APPS+=("$k")
         fi ;;
    esac
  done < <(grep '^IMG|' "$P")
  # a stack with no readable image line: fall back to the stack name
  if ! grep -q '^IMG|' "$P"; then
    k="$(classify "" "" "$s")"
    case "$k" in
      db|unknown) UNKNOWN+=("$s (couldn't read it)") ;;
      skip:*) SKIPPED+=("$s → ${k#skip:}") ;;
      *) APP_STACK[$k]="$s"; APP_SVC[$k]=""; APP_IMAGE[$k]=""; FOUND_APPS+=("$k") ;;
    esac
  fi
done

want() { # want <app>   honours --only / --skip
  local a="$1"
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$a,"*) ;; *) return 1 ;; esac; fi
  if [ -n "$SKIP" ]; then case ",$SKIP," in *",$a,"*) return 1 ;; esac; fi
  return 0
}

# ---------------------------------------------------------------------------
# helpers: where is a mount's data inside the extracted backup?
# ---------------------------------------------------------------------------
# mount_src <app> <container-path>  -> prints "kind|archive-relative-path" or nothing
mount_src() {
  local app="$1" cpath="$2" s svc
  s="${APP_STACK[$app]}"; svc="${APP_SVC[$app]}"
  awk -F'|' -v svc="$svc" -v dst="$cpath" '
    $1=="MNT" && ($2==svc || svc=="") && $5==dst { print $3 "|" $4; exit }' "$META/$s/parsed.txt" |
  while IFS='|' read -r kind src; do
    case "$kind" in
      bind)  echo "bind|${src#/}" ;;
      rel)   if [ -n "$src" ]; then echo "rel|$s/$src"; else echo "rel|$s"; fi ;;
      named) echo "named|$src" ;;
    esac
  done
}
in_archive() { # in_archive <stack> <path>
  awk -v p="${2%/}" '$0==p || $0==p"/" || index($0, p"/")==1 { f=1; exit } END { exit !f }' "$META/$1/list.txt"
}
# resolve <app> <container-path>  -> sets R_KIND R_PATH R_OK(0/1) R_WHY
resolve() {
  local out; R_KIND=""; R_PATH=""; R_OK=1; R_WHY=""
  out="$(mount_src "$1" "$2")"
  if [ -z "$out" ]; then R_WHY="no mount for $2 in the old compose file"; return; fi
  R_KIND="${out%%|*}"; R_PATH="${out#*|}"
  case "$R_KIND" in
    named) R_WHY="was a Docker named volume ('$R_PATH') — the backup script doesn't capture those" ; return ;;
  esac
  if in_archive "${APP_STACK[$1]}" "$R_PATH"; then R_OK=0
  else R_WHY="not in the archive (/$R_PATH) — shared media paths like /goliath are skipped by the backup on purpose"; fi
}

extract_stack() { # extract_stack <stack>   (apply only; once per stack)
  local s="$1" a
  [ -d "$STAGE/$s" ] && return 0
  for a in "${ARCHIVES[@]}"; do
    [ "$(basename "$a" .tar.gz)" = "$s" ] || continue
    $SUDO mkdir -p "$STAGE/$s" && $SUDO tar -xzf "$a" -C "$STAGE/$s" || return 1
  done
}
staged() { echo "$STAGE/${APP_STACK[$1]}/$R_PATH"; }  # after resolve()

# ---------------------------------------------------------------------------
# helpers: units, volumes, placing data
# ---------------------------------------------------------------------------
unit_of() { # unit_of <native-name> [oci]   -> prints the systemd unit that exists (or the best guess)
  local n="$1" kind="${2:-native}"
  if [ "$kind" = native ]; then echo "$n"; return; fi
  if [ -n "$ROOT" ]; then echo "docker-$n"; return; fi
  if systemctl list-unit-files "docker-$n.service" >/dev/null 2>&1 && systemctl cat "docker-$n.service" >/dev/null 2>&1; then echo "docker-$n"
  elif systemctl cat "podman-$n.service" >/dev/null 2>&1; then echo "podman-$n"
  else echo "docker-$n"; fi
}
svc_stop()  { [ -n "$ROOT" ] && return 0; $SUDO systemctl stop "$1.service" 2>/dev/null || true; }
svc_start() { [ -n "$ROOT" ] && return 0; $SUDO systemctl start "$1.service" 2>&1 || warn "couldn't start $1 — check: journalctl -u $1 -n 50"; }
do_chown()  { [ -n "$ROOT" ] && return 0; $SUDO chown -R "$1" "$2"; }

container_cli() { if command -v docker >/dev/null 2>&1; then echo docker; elif command -v podman >/dev/null 2>&1; then echo podman; fi; }
volume_path() { # volume_path <name> -> host mountpoint (creates the volume if needed)
  local cli; cli="$(container_cli)"
  [ -n "$ROOT" ] && { echo "$ROOT/var/lib/docker/volumes/$1/_data"; return; }
  [ -n "$cli" ] || return 1
  $SUDO "$cli" volume create "$1" >/dev/null 2>&1
  $SUDO "$cli" volume inspect -f '{{.Mountpoint}}' "$1"
}

marker() { echo "$ROOT/var/lib/vexos-migrate/done/$1"; }
is_done() { [ "$FORCE" -eq 0 ] && [ -e "$(marker "$1")" ]; }
mark_done() { $SUDO mkdir -p "$ROOT/var/lib/vexos-migrate/done" && $SUDO touch "$(marker "$1")"; }

# place_dir <src-dir> <dest-dir> [chown-spec] [chown-target]
#   move existing dest aside, copy src contents in, fix ownership
place_dir() {
  local src="$1" dest="$2" own="${3:-}" ownroot="${4:-$2}"
  if [ -d "$dest" ] && [ -n "$($SUDO ls -A "$dest" 2>/dev/null)" ]; then
    $SUDO mv "$dest" "$dest.pre-restore-$TS" || return 1
    say "    moved existing data aside → $dest.pre-restore-$TS"
  fi
  $SUDO mkdir -p "$dest" || return 1
  $SUDO cp -a "$src"/. "$dest"/ || return 1
  [ -n "$own" ] && do_chown "$own" "$ownroot"
  return 0
}

# ---------------------------------------------------------------------------
# 5. The plan
# ---------------------------------------------------------------------------
# module option line for each app (empty = no module / manual)
module_opt() {
  case "$1" in
    sonarr|radarr|lidarr|prowlarr|sabnzbd|bazarr|maintainerr) echo "vexos.server.arr.$1.enable" ;;
    tautulli|wishlist|grimmory|code-server) echo "vexos.server.$1.enable" ;;
    *) echo "" ;;
  esac
}
handled() { # apps this script knows how to restore
  case "$1" in sonarr|radarr|lidarr|prowlarr|sabnzbd|bazarr|maintainerr|tautulli|wishlist|grimmory|code-server) return 0 ;; *) return 1 ;; esac
}

PLAN_APPS=()
step "What's in the backup"
for a in "${FOUND_APPS[@]}"; do
  if ! want "$a"; then say "  - $a: left out (--only/--skip)"; continue; fi
  case "$a" in
    qbittorrent) say "  - qbittorrent: config layout differs from the module's — set it up fresh (not migrated)"; result qbittorrent manual "set up fresh"; continue ;;
    bookshelf)   say "  - bookshelf: on hold (fresh vs. copy still undecided) — not touched"; result bookshelf skipped "on hold"; continue ;;
    cloudflare-ddns) PLAN_APPS+=("$a"); say "  - cloudflare-ddns: settings only (no data to copy)"; continue ;;
  esac
  if ! handled "$a"; then say "  - $a: no restore rule for this one"; continue; fi
  if is_done "$a"; then say "  - $a: already migrated earlier (use --force to redo)"; result "$a" skipped "already migrated"; continue; fi
  PLAN_APPS+=("$a")
  say "  - $a  (from ${APP_STACK[$a]})"
done
for x in "${SKIPPED[@]:-}"; do [ -n "$x" ] && say "  - skipping $x"; done
for x in "${UNKNOWN[@]:-}"; do [ -n "$x" ] && say "  - not recognised, left alone: $x"; done

if [ "${#PLAN_APPS[@]}" -eq 0 ]; then say; say "Nothing to do."; exit 0; fi

# ---------------------------------------------------------------------------
# 6. Enable the modules
# ---------------------------------------------------------------------------
enable_option() { # enable_option <option>
  local opt="$1" f="$SERVICES_FILE"
  if $SUDO grep -Eq "^[[:space:]]*${opt//./\\.}[[:space:]]*=[[:space:]]*true;" "$f" 2>/dev/null; then
    say "    $opt already enabled"; return 0
  fi
  if $SUDO grep -Eq "^[[:space:]]*${opt//./\\.}[[:space:]]*=[[:space:]]*false;" "$f" 2>/dev/null; then
    $SUDO sed -i -E "s|^([[:space:]]*${opt//./\\.}[[:space:]]*=[[:space:]]*)false;|\1true;|" "$f"
  else
    $SUDO sed -i "\$ s|^}|  ${opt} = true;\n}|" "$f"
  fi
  say "    enabled $opt"
}

step "Enabling modules in $SERVICES_FILE"
NEED_REBUILD=0
if [ ! -f "$SERVICES_FILE" ]; then
  warn "$SERVICES_FILE doesn't exist — is this a vexos server? Skipping module enabling."
else
  [ "$APPLY" -eq 1 ] && $SUDO cp -a "$SERVICES_FILE" "$SERVICES_FILE.pre-migrate-$TS"
  for a in "${PLAN_APPS[@]}"; do
    opt="$(module_opt "$a")"; [ -n "$opt" ] || continue
    if [ "$a" = "code-server" ] && ! $SUDO grep -Eq 'code-server\.hashedPassword[[:space:]]*=[[:space:]]*"[^"]+"' "$SERVICES_FILE"; then
      warn "code-server: NOT enabled — the module needs a password hash first (see the note at the end)."
      note "code-server: generate a hash with:  echo -n 'yourpassword' | nix run nixpkgs#libargon2 -- \"\$(head -c 20 /dev/random | base64)\" -e
      then add to $SERVICES_FILE:   vexos.server.code-server.hashedPassword = \"<hash>\";   vexos.server.code-server.enable = true;
      then run:  just rebuild   (your files are already in /home/code-server)"
      continue
    fi
    if [ "$APPLY" -eq 1 ]; then enable_option "$opt"; NEED_REBUILD=1; else say "  [dry-run] would enable $opt"; fi
  done
fi

# ---------------------------------------------------------------------------
# 7. Rebuild
# ---------------------------------------------------------------------------
find_repo() {
  local d
  for d in "$REPO" "$PWD" "$HOME/vexos-nix" "$HOME/Projects/vexos-nix" "$HOME/projects/vexos-nix" "$HOME/Documents/vexos-nix" "/etc/nixos"; do
    [ -n "$d" ] && [ -f "$d/justfile" ] && { echo "$d"; return 0; }
  done
  return 1
}

step "Rebuilding"
if [ "$SKIP_REBUILD" -eq 1 ] || [ -n "$ROOT" ]; then
  say "  skipped (--skip-rebuild)"
elif [ "$APPLY" -eq 0 ]; then
  say "  [dry-run] would run: just rebuild"
elif [ "$NEED_REBUILD" -eq 0 ]; then
  say "  nothing new to enable — no rebuild needed"
else
  RDIR="$(find_repo)" || { echo "Couldn't find your vexos-nix checkout (the folder with the justfile). Re-run with --repo /path/to/vexos-nix, or run 'just rebuild' yourself and re-run this with --skip-rebuild." >&2; exit 1; }
  say "  running 'just rebuild' in $RDIR (this can take a while) ..."
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then (cd "$RDIR" && sudo -u "$SUDO_USER" just rebuild); else (cd "$RDIR" && just rebuild); fi \
    || { echo "The rebuild failed, so I stopped before touching any data. Fix the error above and re-run (use --skip-rebuild once it builds)." >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# 8. Restore data, one app at a time
# ---------------------------------------------------------------------------
# restore_simple <app> <unit> <container-path> <dest> [chown] [chown-root]
restore_simple() {
  local app="$1" unit="$2" cpath="$3" dest="$4" own="${5:-}" ownroot="${6:-}"
  resolve "$app" "$cpath"
  if [ "$R_OK" -ne 0 ]; then say "    ✗ $R_WHY"; result "$app" "no data" "$R_WHY"; return 1; fi
  if [ "$APPLY" -eq 0 ]; then say "  [dry-run] $app: /$R_PATH  →  $dest   (stop $unit, move old aside, copy, chown ${own:-keep}, start)"; return 0; fi
  extract_stack "${APP_STACK[$app]}" || { result "$app" FAILED "couldn't extract archive"; return 1; }
  local src; src="$(staged "$app")"
  svc_stop "$unit"
  if place_dir "$src" "$dest" "$own" "${ownroot:-$dest}"; then
    svc_start "$unit"; mark_done "$app"; result "$app" restored "$dest"
  else
    svc_start "$unit"; result "$app" FAILED "copy to $dest failed"; return 1
  fi
}

restore_grimmory() {
  local app=grimmory stack="${APP_STACK[grimmory]}" base="$ROOT/var/lib/grimmory"
  local app_unit db_unit; app_unit="$(unit_of grimmory oci)"; db_unit="$(unit_of grimmory-db oci)"
  local dump="$STAGE/$stack/$stack/db-backup/dump.sql" have_dump=0
  in_archive "$stack" "$stack/db-backup/dump.sql" && have_dump=1
  local parts=("/app/data:app-data" "/books:books" "/bookdrop:bookdrop")
  if [ "$APPLY" -eq 0 ]; then
    local p; for p in "${parts[@]}"; do
      resolve grimmory "${p%%:*}"
      if [ "$R_OK" -eq 0 ]; then say "  [dry-run] grimmory: /$R_PATH → $base/${p##*:}"; else say "    - ${p%%:*}: $R_WHY"; fi
    done
    if [ "$have_dump" -eq 1 ]; then say "  [dry-run] grimmory: database dump → recreate 'grimmory' db in container grimmory-db and import it"
    else say "    - no db-backup/dump.sql in the archive — database would NOT be restored"; fi
    return 0
  fi
  extract_stack "$stack" || { result grimmory FAILED "couldn't extract archive"; return 1; }
  svc_stop "$app_unit"
  local p ok_any=0
  for p in "${parts[@]}"; do
    resolve grimmory "${p%%:*}"
    if [ "$R_OK" -eq 0 ]; then
      place_dir "$(staged grimmory)" "$base/${p##*:}" "1000:1000" && { ok_any=1; say "    copied ${p%%:*} → $base/${p##*:}"; }
    else say "    - ${p%%:*}: $R_WHY"; fi
  done
  if [ "$have_dump" -eq 1 ] && [ -z "$ROOT" ]; then
    local cli; cli="$(container_cli)"
    local envf="$base/secrets/grimmory-env" rootpw
    rootpw="$($SUDO grep -m1 '^MYSQL_ROOT_PASSWORD=' "$envf" 2>/dev/null | cut -d= -f2-)"
    svc_start "$db_unit"
    if [ -z "$rootpw" ]; then
      warn "grimmory: couldn't read the database password from $envf — database NOT restored"
      result grimmory partial "files copied, database NOT restored (no password file)"
    else
      say "    waiting for the database ..."
      local i ready=0
      for i in $(seq 1 60); do
        $SUDO "$cli" exec grimmory-db mariadb -uroot -p"$rootpw" -e 'select 1' >/dev/null 2>&1 && { ready=1; break; }
        sleep 2
      done
      if [ "$ready" -eq 0 ]; then
        warn "grimmory: database never became ready — not restored"; result grimmory partial "files copied, database not ready"
      else
        # Keep only the app's database from the dump and aim it at 'grimmory'.
        # (If the dump was made with --all-databases we must not import mysql's own system tables.)
        local filtered="$WORK/grimmory.sql"
        $SUDO awk '
          /^-- Current Database: / { db=$0; sub(/^-- Current Database: `/,"",db); sub(/`.*$/,"",db)
                                     skip = (db=="mysql"||db=="information_schema"||db=="performance_schema"||db=="sys"); seen=1 }
          !seen || !skip { if ($0 !~ /^CREATE DATABASE/ && $0 !~ /^USE /) print }
        ' "$dump" > "$filtered"
        if [ ! -s "$filtered" ]; then
          warn "grimmory: the dump was empty after filtering — not restored"; result grimmory partial "files copied, dump empty"
        elif $SUDO "$cli" exec -i grimmory-db mariadb -uroot -p"$rootpw" -e 'DROP DATABASE IF EXISTS grimmory; CREATE DATABASE grimmory;' \
             && $SUDO "$cli" exec -i grimmory-db mariadb -uroot -p"$rootpw" grimmory < "$filtered"; then
          say "    database imported"; mark_done grimmory; result grimmory restored "files + database"
        else
          result grimmory FAILED "database import failed (files were copied)"
        fi
      fi
    fi
  elif [ "$have_dump" -eq 0 ]; then
    warn "grimmory: no database dump in the archive — only files were copied"
    result grimmory partial "files copied, no database dump in backup"
  else
    result grimmory restored "files (test mode)"
  fi
  svc_start "$app_unit"
}

restore_code_server() {
  local app=code-server dest="$ROOT/home/code-server"
  local unit; unit="$(unit_of code-server oci)"
  resolve "$app" /home/coder
  if [ "$R_OK" -eq 0 ]; then
    restore_simple "$app" "$unit" /home/coder "$dest" "1000:1000"
    return
  fi
  # linuxserver-style image keeps everything in /config — different layout, so don't mix it into $HOME
  resolve "$app" /config
  if [ "$R_OK" -eq 0 ]; then
    dest="$dest/migrated-from-linuxserver"
    if [ "$APPLY" -eq 0 ]; then say "  [dry-run] code-server: /$R_PATH → $dest  (old image used a different layout, so it's kept in a subfolder for you to pick through)"; return 0; fi
    extract_stack "${APP_STACK[$app]}" || { result "$app" FAILED "couldn't extract"; return 1; }
    place_dir "$(staged "$app")" "$dest" "1000:1000" "$ROOT/home/code-server" \
      && { mark_done "$app"; result "$app" restored "$dest (different layout — see notes)"; \
           note "code-server: the old container used a different folder layout, so your files are in /home/code-server/migrated-from-linuxserver (workspace/ has your projects). Settings/extensions were not mapped."; }
    return
  fi
  say "    ✗ $R_WHY"; result "$app" "no data" "$R_WHY"
}

restore_cloudflare() {
  local s="${APP_STACK[cloudflare-ddns]}" d
  d="$(awk -F'|' '$1=="ENV" && $3 ~ /DOMAINS/ {print $4; exit}' "$META/$s/parsed.txt")"
  say "  cloudflare-ddns has no data — it only needs settings. Not enabled automatically (the module requires a zone and token file)."
  [ -n "$d" ] && say "    your old container updated: $d"
  note "cloudflare-ddns: not enabled. It needs your zone and an API-token file. Old domains: ${d:-<see the old compose .env in the backup>}. The token is in that stack's .env inside the backup."
  result cloudflare-ddns manual "needs zone + token"
}

step "Restoring data"
for a in "${PLAN_APPS[@]}"; do
  say; say "$a:"
  case "$a" in
    sonarr)   restore_simple sonarr   sonarr   /config "$ROOT/var/lib/sonarr/.config/NzbDrone" sonarr:sonarr "$ROOT/var/lib/sonarr" ;;
    radarr)   restore_simple radarr   radarr   /config "$ROOT/var/lib/radarr/.config/Radarr"   radarr:radarr "$ROOT/var/lib/radarr" ;;
    lidarr)   restore_simple lidarr   lidarr   /config "$ROOT/var/lib/lidarr/.config/Lidarr"   lidarr:lidarr "$ROOT/var/lib/lidarr" ;;
    bazarr)   restore_simple bazarr   bazarr   /config "$ROOT/var/lib/bazarr" bazarr:bazarr ;;
    sabnzbd)  restore_simple sabnzbd  sabnzbd  /config "$ROOT/var/lib/sabnzbd" sabnzbd:sabnzbd ;;
    prowlarr)
      # DynamicUser: the real directory is under /var/lib/private; systemd re-owns it on start
      pdest="$ROOT/var/lib/prowlarr"; [ -z "$ROOT" ] && pdest="$(readlink -f /var/lib/prowlarr 2>/dev/null || echo /var/lib/prowlarr)"
      restore_simple prowlarr prowlarr /config "$pdest" ;;
    tautulli)
      restore_simple tautulli "$(unit_of tautulli oci)" /config "$ROOT/var/lib/plexpy" 1000:1000 ;;
    wishlist)
      wu="$(unit_of wishlist oci)"
      if [ "$APPLY" -eq 0 ]; then
        for pair in /usr/src/app/data:data /usr/src/app/uploads:uploads; do
          resolve wishlist "${pair%%:*}"
          if [ "$R_OK" -eq 0 ]; then say "  [dry-run] wishlist: /$R_PATH → $ROOT/var/lib/wishlist/${pair##*:}"; else say "    - ${pair%%:*}: $R_WHY"; fi
        done
      else
        extract_stack "${APP_STACK[wishlist]}" || { result wishlist FAILED "couldn't extract"; continue; }
        svc_stop "$wu"; okc=0
        for pair in /usr/src/app/data:data /usr/src/app/uploads:uploads; do
          resolve wishlist "${pair%%:*}"
          if [ "$R_OK" -eq 0 ]; then place_dir "$(staged wishlist)" "$ROOT/var/lib/wishlist/${pair##*:}" 1000:1000 && okc=1 && say "    copied ${pair##*:}"
          else say "    - ${pair%%:*}: $R_WHY"; fi
        done
        svc_start "$wu"
        if [ "$okc" -eq 1 ]; then mark_done wishlist; result wishlist restored "$ROOT/var/lib/wishlist"; else result wishlist "no data" "nothing found in backup"; fi
      fi ;;
    maintainerr)
      mu="$(unit_of maintainerr oci)"
      resolve maintainerr /opt/data
      if [ "$R_OK" -ne 0 ]; then say "    ✗ $R_WHY"; result maintainerr "no data" "$R_WHY"
      elif [ "$APPLY" -eq 0 ]; then say "  [dry-run] maintainerr: /$R_PATH → Docker volume 'maintainerr-data'"
      else
        extract_stack "${APP_STACK[maintainerr]}" || { result maintainerr FAILED "couldn't extract"; continue; }
        vp="$(volume_path maintainerr-data)" || { result maintainerr FAILED "no docker/podman to find the volume"; continue; }
        svc_stop "$mu"
        place_dir "$(staged maintainerr)" "$vp" && { mark_done maintainerr; result maintainerr restored "$vp"; }
        svc_start "$mu"
      fi ;;
    grimmory)        restore_grimmory ;;
    code-server)     restore_code_server ;;
    cloudflare-ddns) restore_cloudflare ;;
  esac
done

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
case " ${PLAN_APPS[*]} " in *" sonarr "*|*" radarr "*|*" lidarr "*|*" prowlarr "*|*" sabnzbd "*|*" bazarr "*)
  note "Arr apps / SABnzbd: the restored settings still point at the OLD container world. Open each one and check Download Clients (host names like 'sabnzbd' or container IPs → this host's address and port), Root Folders / media paths, and Prowlarr → Apps (the Sonarr/Radarr URLs). SABnzbd's download folders also need to point at real paths on this host." ;;
esac
case " ${PLAN_APPS[*]} " in *" tautulli "*) note "Tautulli: check Settings → Plex Media Server — the Plex address changes when Plex moves." ;; esac
case " ${PLAN_APPS[*]} " in *" wishlist "*) note "Wishlist: the module's ORIGIN defaults to http://<hostname>:3280. If you reach it by another name or through the reverse proxy, set vexos.server.wishlist.origin." ;; esac

step "Summary"
if [ "$APPLY" -eq 0 ]; then
  say "That was a dry run — nothing was changed. Run again with --apply to do it."
else
  printf '%-16s %-10s %s\n' SERVICE STATUS DETAIL
  for r in "${RESULTS[@]:-}"; do [ -n "$r" ] && IFS='|' read -r a b c <<<"$r" && printf '%-16s %-10s %s\n' "$a" "$b" "$c"; done
fi
if [ "${#NOTES[@]}" -gt 0 ]; then
  say; say "Things to check by hand:"
  for n in "${NOTES[@]}"; do say "  • $n"; done
fi
if [ "$APPLY" -eq 1 ]; then
  say; say "Old data that was already on this host was kept next to the new data as *.pre-restore-$TS."
  [ "$KEEP" -eq 1 ] && say "The extracted backup is still in $STAGE (delete it when you're happy)."
fi
exit 0