#!/usr/bin/env bash
# Debian 12/13 APT mirror benchmark and safe switch
# Supports traditional .list and DEB822 .sources files.
set -Eeuo pipefail
export LC_ALL=C

readonly APT_DIR=/etc/apt
readonly OFFICIAL_SECURITY='https://security.debian.org/debian-security'
REPEATS=3
MIRROR_SECURITY=0
DRY_RUN=0
CURL_FAMILY=()
BACKUP_DIR=''
BACKUP_TAR=''
ROLLBACK_NEEDED=0
CHANGED_FILES=0
RECOGNIZED_FILES=0

usage() {
  cat <<'HELP'
Usage: bash debian-fastest-apt-mirror.sh [options]

  --mirror-security  Also switch the security updates repository to the
                     selected mirror (may delay availability of fixes).
  --repeats=N        Number of download measurements per mirror (1-8; default 3).
  --ipv4             Force IPv4 for the benchmark.
  --dry-run          Benchmark and display the winner without changing APT.
  -h, --help         Show this help.

After a successful run, a rollback archive is saved under
/var/backups/debian-apt-mirror-*/sources.tar.
HELP
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

on_exit() {
  local code=$1
  trap - EXIT
  if (( ROLLBACK_NEEDED )) && [[ -n "$BACKUP_TAR" && -f "$BACKUP_TAR" ]]; then
    warn 'Unfinished mirror switch: restoring original APT sources.'
    if ! tar -C "$APT_DIR" -xpf "$BACKUP_TAR"; then
      warn "Automatic restore failed; restore manually: tar -C $APT_DIR -xpf $BACKUP_TAR"
    fi
  fi
  exit "$code"
}
trap 'on_exit "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for arg in "$@"; do
  case "$arg" in
    --mirror-security) MIRROR_SECURITY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --ipv4) CURL_FAMILY=(-4) ;;
    --repeats=*) REPEATS=${arg#*=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unrecognized argument: $arg" ;;
  esac
done
[[ "$REPEATS" =~ ^[1-8]$ ]] || die '--repeats must be an integer between 1 and 8.'
(( EUID == 0 || DRY_RUN == 1 )) || die 'Run as root (or use --dry-run for benchmarking only).'
[[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release.'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == debian ]] || die 'Only Debian is supported; never run on a PVE host or Ubuntu.'
if command -v pveversion >/dev/null 2>&1 && [[ -d /etc/pve ]]; then
  die 'Detected a Proxmox VE host. Run this script inside the Debian guest/container instead.'
fi
CODENAME=${VERSION_CODENAME:-}
[[ "$CODENAME" == bookworm || "$CODENAME" == trixie ]] || die "Unsupported Debian codename: $CODENAME (only bookworm and trixie are supported)."
for dep in curl awk sed grep tar mktemp sort cmp; do
  command -v "$dep" >/dev/null 2>&1 || die "Missing dependency: $dep. Install it before running this script."
done
(( DRY_RUN )) || command -v apt-get >/dev/null 2>&1 || die 'apt-get not found.'

# Do not point external repos at a Debian mirror.
# The mapping below only replaces URLs ending in /debian or /debian-security
# (optionally beneath a /repository/ prefix, as used by Huawei Cloud).
NAMES=('Debian CDN' 'Aliyun' 'TUNA' 'USTC' 'Huawei')
BASES=(
  'https://deb.debian.org/debian'
  'https://mirrors.aliyun.com/debian'
  'https://mirrors.tuna.tsinghua.edu.cn/debian'
  'https://mirrors.ustc.edu.cn/debian'
  'https://mirrors.huaweicloud.com/repository/debian'
)
SECURITIES=(
  'https://security.debian.org/debian-security'
  'https://mirrors.aliyun.com/debian-security'
  'https://mirrors.tuna.tsinghua.edu.cn/debian-security'
  'https://mirrors.ustc.edu.cn/debian-security'
  'https://mirrors.huaweicloud.com/repository/debian-security'
)

# CURL metrics: HTTP status, total seconds, time to first byte (s), bytes.
# Only 2xx successful downloads (curl -f) of signed Release metadata count.
probe() {
  local url=$1 result code total ttfb bytes
  result=$(curl "${CURL_FAMILY[@]}" -fsSL \
    --connect-timeout 5 --max-time 15 \
    --proto '=https' --proto-redir '=https' \
    -o /dev/null \
    -w '%{http_code} %{time_total} %{time_starttransfer} %{size_download}' \
    "$url" 2>/dev/null) || return 1
  read -r code total ttfb bytes <<< "$result"
  [[ "$code" == 200 && "$bytes" =~ ^[0-9]+$ ]] || return 1
  (( bytes >= 1024 )) || return 1
  printf '%s %s %s\n' "$total" "$ttfb" "$bytes"
}

make_backup() {
  mkdir -p /var/backups
  BACKUP_DIR=$(mktemp -d /var/backups/debian-apt-mirror-XXXXXXXX)
  BACKUP_TAR="$BACKUP_DIR/sources.tar"
  local include=()
  [[ ! -e "$APT_DIR/sources.list" ]] || include+=(sources.list)
  [[ ! -d "$APT_DIR/sources.list.d" ]] || include+=(sources.list.d)
  (( ${#include[@]} > 0 )) || die 'No APT source configuration found.'
  tar -C "$APT_DIR" -cpf "$BACKUP_TAR" "${include[@]}"
  chmod 600 "$BACKUP_TAR"
}

restore_backup() {
  tar -C "$APT_DIR" -xpf "$BACKUP_TAR"
  ROLLBACK_NEEDED=0
}

rewrite_file() {
  local path=$1 main=$2 sec=$3 temp
  temp=$(mktemp "${path}.switch-XXXXXXXX")
  # Preserve the owner and mode; GNU sed only replaces active deb/deb-src or
  # DEB822 URIs lines. Suites, components, keys and non-Debian URLs remain.
  cp -p -- "$path" "$temp"
  if grep -Eq '^[[:space:]]*((deb|deb-src)[[:space:]].*|URIs:[[:space:]].*)https?://[^[:space:]]+/(repository/)?debian(-security)?/?([[:space:]]|$)' "$path"; then
    RECOGNIZED_FILES=$((RECOGNIZED_FILES + 1))
  fi
  if ! sed -E \
    -e '/^[[:space:]]*(deb|deb-src)[[:space:]]|^[[:space:]]*URIs[[:space:]]*:/s#https?://[^/[:space:]]+/(repository/)?debian-security/?([[:space:]]|$)#'"$sec"'\2#g' \
    -e '/^[[:space:]]*(deb|deb-src)[[:space:]]|^[[:space:]]*URIs[[:space:]]*:/s#https?://[^/[:space:]]+/(repository/)?debian/?([[:space:]]|$)#'"$main"'\2#g' \
    "$path" > "$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  if cmp -s -- "$path" "$temp"; then
    rm -f -- "$temp"
  else
    mv -f -- "$temp" "$path"
    CHANGED_FILES=$((CHANGED_FILES + 1))
    printf '  modified: %s\n' "$path"
  fi
}

apply_mirror() {
  local main=$1 sec=$2 f
  CHANGED_FILES=0
  RECOGNIZED_FILES=0
  if [[ -f "$APT_DIR/sources.list" ]]; then
    rewrite_file "$APT_DIR/sources.list" "$main" "$sec" || return 1
  fi
  shopt -s nullglob
  for f in "$APT_DIR"/sources.list.d/*.list "$APT_DIR"/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    rewrite_file "$f" "$main" "$sec" || return 1
  done
  shopt -u nullglob
  # Also succeed when the selected mirror is already configured.
  (( RECOGNIZED_FILES > 0 )) || return 1
}

log "Debian: ${PRETTY_NAME:-$CODENAME}"
log "Main mirror selection: fastest tested candidate"
if (( MIRROR_SECURITY )); then
  warn 'Security updates will use the selected mirror; it can lag behind upstream.'
else
  log 'Security updates: official security.debian.org (freshness-first default)'
fi
log "Repeats per mirror: $REPEATS; download probe: InRelease metadata"
log ''
printf '%-12s %12s %14s %15s %s\n' 'Mirror' 'Avg TTFB' 'Avg speed' 'Avg duration' 'Status'
printf '%-12s %12s %14s %15s %s\n' '------------' '------------' '--------------' '---------------' '------'

rank=$(mktemp)
trap 'rc=$?; rm -f -- "$rank"; on_exit "$rc"' EXIT

for ((i=0; i<${#NAMES[@]}; i++)); do
  base=${BASES[$i]}
  sec=${SECURITIES[$i]}
  ok=1
  # Check both APT update metadata endpoints before running speed tests.
  probe "$base/dists/$CODENAME-updates/InRelease" >/dev/null || ok=0
  probe "$sec/dists/$CODENAME-security/InRelease" >/dev/null || ok=0
  sum_total=0; sum_ttfb=0; sum_bytes=0
  if (( ok )); then
    for ((j=0; j<REPEATS; j++)); do
      if metric=$(probe "$base/dists/$CODENAME/InRelease"); then
        read -r elapsed ttfb bytes <<< "$metric"
        sum_total=$(awk -v a="$sum_total" -v b="$elapsed" 'BEGIN{printf "%.6f",a+b}')
        sum_ttfb=$(awk -v a="$sum_ttfb" -v b="$ttfb" 'BEGIN{printf "%.6f",a+b}')
        sum_bytes=$((sum_bytes + bytes))
      else
        ok=0
        break
      fi
    done
  fi
  if (( ok )); then
    # InRelease is a small real downloaded file. Ranking by transfer completion
    # time balances connection latency and file throughput.
    score=$(awk -v t="$sum_total" -v n="$REPEATS" 'BEGIN{printf "%.3f",1000*t/n}')
    latency=$(awk -v t="$sum_ttfb" -v n="$REPEATS" 'BEGIN{printf "%.0f",1000*t/n}')
    kibps=$(awk -v b="$sum_bytes" -v t="$sum_total" 'BEGIN{if(t>0)printf "%.1f",b/t/1024;else print "0"}')
    printf '%-12s %9s ms %10s KiB/s %10s ms %s\n' "${NAMES[$i]}" "$latency" "$kibps" "$score" 'OK'
    printf '%s\t%s\n' "$score" "$i" >> "$rank"
  else
    printf '%-12s %12s %14s %15s %s\n' "${NAMES[$i]}" '-' '-' '-' 'FAILED/TIMEOUT'
  fi
done

[[ -s "$rank" ]] || die 'All mirrors failed. APT configuration was not changed.'
winning_index=$(sort -n -k1,1 "$rank" | head -n1 | cut -f2)
log ''
log "Benchmark winner: ${NAMES[$winning_index]} (${BASES[$winning_index]})"
if (( DRY_RUN )); then
  log '--dry-run: no configuration changed.'
  exit 0
fi

make_backup
log "Backup archive: $BACKUP_TAR"
log ''

# Try the fastest mirror first; on apt failure, restore everything and try
# the next eligible candidate. Original sources are always restored on failure.
while IFS=$'\t' read -r score idx; do
  main=${BASES[$idx]}
  security=$OFFICIAL_SECURITY
  (( MIRROR_SECURITY )) && security=${SECURITIES[$idx]}
  log "Trying ${NAMES[$idx]} (${score} ms)..."
  ROLLBACK_NEEDED=1
  if ! apply_mirror "$main" "$security"; then
    warn "No recognized Debian repository entries found, or rewriting failed."
    restore_backup
    break
  fi
  update_log="$BACKUP_DIR/apt-update-${idx}.log"
  # Error-Mode=any treats unreachable repository indexes as real failures,
  # instead of silently leaving previously downloaded metadata in use.
  if apt-get -o APT::Update::Error-Mode=any update 2>&1 | tee "$update_log"; then
    ROLLBACK_NEEDED=0
    log ''
    log 'SUCCESS: apt update passed.'
    log "Selected mirror: ${NAMES[$idx]}"
    log "Main: $main"
    log "Security: $security"
    log "Changed files: $CHANGED_FILES"
    log "Original sources backup: $BACKUP_TAR"
    log 'To restore original sources:'
    printf '  sudo tar -C /etc/apt -xpf %q && sudo apt-get update\n' "$BACKUP_TAR"
    exit 0
  fi
  warn "apt update failed with ${NAMES[$idx]}; restoring and trying next mirror."
  restore_backup
done < <(sort -n -k1,1 "$rank")

die "No candidate passed the final apt update. Original sources were restored. Backup: $BACKUP_TAR"
