#!/bin/bash
# build-raspap-webone.sh
# Debian tool: one flashable Raspberry Pi .img with official RaspAP 64-bit + WebOne.
# Uses dd(1). Resumable. Can build new or update an existing .img.
#
# No default login user/password. Wi-Fi password defaults to official RaspAP ChangeMe.
#
#   sudo ./build-cli.sh
#   sudo ./build-gui.sh
#   sudo ./build-cli.sh --new
#   sudo ./build-cli.sh --help
#
set -euo pipefail

DEVICE_NAME="${DEVICE_NAME:-}"
USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"
WIFI_SSID="${WIFI_SSID:-RaspAP}"
WIFI_PSK="${WIFI_PSK:-ChangeMe}"
WIFI_COUNTRY="${WIFI_COUNTRY:-CA}"
RASPAP_ADMIN_USER="${RASPAP_ADMIN_USER:-admin}"
RASPAP_ADMIN_PASS="${RASPAP_ADMIN_PASS:-secret}"

RASPAP_VERSION="${RASPAP_VERSION:-3.5.5}"
WEBONE_VERSION="${WEBONE_VERSION:-0.18.2}"
EXPAND_MIB="${EXPAND_MIB:-1024}"
WORKDIR="${WORKDIR:-}"
OUTDIR="${OUTDIR:-}"
SKIP_EXTRAS=0
SKIP_DOWNLOAD=0
SKIP_VERIFY=0
KEEP_WORK=0
FRESH=0
FORCE_APPLY=0
UPDATE_IN_PLACE=0
MODE="${MODE:-auto}"
UPDATE_IMG="${UPDATE_IMG:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_MODE="${SSH_MODE:-password}"
ENABLE_SSH="${ENABLE_SSH:-1}"
WANT_UI="${WANT_UI:-auto}"
STATE_FILE=""
CURRENT_STEP=0
PROGRESS_TOTAL=10
PROGRESS_UI_PID=""
PROGRESS_FILE=""

RASPAP_ZIP_URL="${RASPAP_ZIP_URL:-https://github.com/RaspAP/raspap-webgui/releases/download/${RASPAP_VERSION}/raspap-trixie-arm64-lite-${RASPAP_VERSION}.img.zip}"
RASPAP_ZIP_NAME="raspap-trixie-arm64-lite-${RASPAP_VERSION}.img.zip"
WEBONE_DEB_NAME="webone.${WEBONE_VERSION}.linux-arm64.deb"
RASPAP_SHA256_PIN="${RASPAP_SHA256:-56cf447e711ee890c00c6b437b58fcc25852d462dfc138ec224228daa08f5933}"
WEBONE_SHA256_PIN="${WEBONE_SHA256:-b98731cd373a8a3bf2353d1af8dbbabe46ea51eb5b3c6f28bb118c62bf9b03fe}"
WEBONE_DEB_URL="${WEBONE_DEB_URL:-https://github.com/atauenis/webone/releases/download/v${WEBONE_VERSION}/webone.${WEBONE_VERSION}.linux-arm64.deb}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROG="$(basename "$0")"
LOOPDEV=""
ROOTMNT=""
NEED_UMOUNT=0
IMG=""
IMG_FINAL=""

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] ==> %s\n' "$(ts)" "$*"; }
dbg()  { printf '[%s]     %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] !!  %s\n' "$(ts)" "$*" >&2; }
die()  {
    printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2
    if [[ -n "${WORKDIR:-}" ]]; then
        mkdir -p "$WORKDIR" 2>/dev/null || true
        printf '%s  %s\n' "$(ts)" "$*" >> "$WORKDIR/last-error.txt" 2>/dev/null || true
    fi
    printf '[%s] ERROR (this is why it stopped): %s\n' "$(ts)" "$*" >&2
    exit 1
}
progress_bar_text() {
    local pct="${1:-0}"
    local width="${2:-32}"
    local filled empty i
    [[ "$pct" -lt 0 ]] && pct=0
    [[ "$pct" -gt 100 ]] && pct=100
    filled=$(( pct * width / 100 ))
    empty=$(( width - filled ))
    local fillc="#" emptyc="-"
    case "${LC_ALL:-${LANG:-}}" in
        *UTF-8*|*utf8*) fillc="█"; emptyc="░" ;;
    esac
    printf '%s' "["
    for ((i=0; i<filled; i++)); do printf '%s' "$fillc"; done
    for ((i=0; i<empty; i++)); do printf '%s' "$emptyc"; done
    printf '%s' "]"
}

progress_draw() {
    local cur="${1:-0}"
    local total="${2:-$PROGRESS_TOTAL}"
    local msg="${3:-}"
    local pct=0
    [[ "$total" -gt 0 ]] || total=10
    pct=$(( cur * 100 / total ))
    [[ "$pct" -gt 100 ]] && pct=100
    [[ "$pct" -lt 0 ]] && pct=0
    CURRENT_STEP="$cur"
    PROGRESS_TOTAL="$total"
    if [[ -n "${PROGRESS_FILE:-}" ]]; then
        mkdir -p "$(dirname "$PROGRESS_FILE")" 2>/dev/null || true
        printf '%s/%s|%s|%s\n' "$cur" "$total" "$pct" "$msg" > "$PROGRESS_FILE" 2>/dev/null || true
    fi
    local bar
    bar="$(progress_bar_text "$pct" 32)"
    printf '[%s] %s %3d%%  %s/%s  %s\n' "$(ts)" "$bar" "$pct" "$cur" "$total" "$msg"
}

# Update the GUI bar inside the current step (0-99% of this step). No extra terminal spam.
progress_within_step() {
    local frac="${1:-0}"
    local msg="${2:-}"
    local cur="${CURRENT_STEP:-0}"
    local total="${PROGRESS_TOTAL:-10}"
    local base span pct
    [[ "$total" -gt 0 ]] || total=10
    [[ "$frac" -lt 0 ]] && frac=0
    [[ "$frac" -gt 99 ]] && frac=99
    if [[ "$cur" -gt 0 ]]; then
        base=$(( (cur - 1) * 100 / total ))
        span=$(( 100 / total ))
        pct=$(( base + frac * span / 100 ))
    else
        pct="$frac"
    fi
    [[ "$pct" -gt 99 ]] && pct=99
    if [[ -n "${PROGRESS_FILE:-}" ]]; then
        printf '%s/%s|%s|%s\n' "$cur" "$total" "$pct" "$msg" > "$PROGRESS_FILE" 2>/dev/null || true
    fi
}

# Background: watch a file grow and move the GUI bar. Prints the watcher PID.
progress_watch_bytes() {
    local file="$1"
    local expected="${2:-0}"
    local label="${3:-working}"
    (
        trap 'exit 0' TERM INT
        set +e
        while :; do
            have=0; frac=0; human=""
            [[ -f "$file" ]] && have="$(stat -c%s "$file" 2>/dev/null || echo 0)"
            if [[ "$expected" -gt 0 && "$have" -gt 0 ]]; then
                frac=$(( have * 100 / expected ))
            fi
            human="$(numfmt --to=iec --suffix=B "$have" 2>/dev/null || echo "${have} bytes")"
            progress_within_step "$frac" "$label  $human"
            sleep 0.5
        done
    ) >/dev/null 2>&1 &
    printf '%s\n' "$!"
}

stop_watch() {
    local pid="${1:-}"
    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

step() {
    local raw="$*"
    local msg="$raw"
    if [[ "$raw" =~ ^([0-9]+)/([0-9]+)[[:space:]]+(.*)$ ]]; then
        CURRENT_STEP="${BASH_REMATCH[1]}"
        PROGRESS_TOTAL="${BASH_REMATCH[2]}"
        msg="${BASH_REMATCH[3]}"
    else
        CURRENT_STEP=$((CURRENT_STEP + 1))
    fi
    printf '\n[%s] ======================================================================\n' "$(ts)"
    printf '[%s] STEP: %s/%s  %s\n' "$(ts)" "$CURRENT_STEP" "$PROGRESS_TOTAL" "$msg"
    progress_draw "$CURRENT_STEP" "$PROGRESS_TOTAL" "$msg"
    printf '[%s] ======================================================================\n' "$(ts)"
}

stop_progress_ui() {
    local pid=""
    if [[ -n "${PROGRESS_FILE:-}" && -f "${PROGRESS_FILE}.pid" ]]; then
        pid="$(tr -d ' \n' < "${PROGRESS_FILE}.pid" 2>/dev/null || true)"
        rm -f "${PROGRESS_FILE}.pid"
    fi
    if [[ -z "$pid" && -n "${PROGRESS_UI_PID:-}" ]]; then
        pid="$PROGRESS_UI_PID"
    fi
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    PROGRESS_UI_PID=""
}

start_progress_ui() {
    PROGRESS_FILE="${WORKDIR}/.build-progress"
    mkdir -p "$WORKDIR"
    printf '0/%s|0|Starting…\n' "$PROGRESS_TOTAL" > "$PROGRESS_FILE"
    [[ "${WANT_UI:-auto}" == "no" ]] && return 0
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 0
    python3 -c "import tkinter" >/dev/null 2>&1 || return 0

    local env_prefix=()
    if [[ -n "${SUDO_USER:-}" ]]; then
        env_prefix=(sudo -u "$SUDO_USER" env "DISPLAY=${DISPLAY}" \
            "XAUTHORITY=${XAUTHORITY:-/home/${SUDO_USER}/.Xauthority}" \
            "HOME=/home/${SUDO_USER}")
    fi
    "${env_prefix[@]+"${env_prefix[@]}"}" python3 - "$PROGRESS_FILE" <<'PY' &
import os, sys, tkinter as tk
from tkinter import ttk

path = sys.argv[1]
pidfile = path + ".pid"
try:
    open(pidfile, "w").write(str(os.getpid()))
except OSError:
    pass

root = tk.Tk()
root.title("Building")
root.configure(bg="#141b24")
root.minsize(420, 140)
root.geometry("480x150")
try:
    root.tk.call("tk", "scaling", 1.1)
except tk.TclError:
    pass

style = ttk.Style()
try:
    style.theme_use("clam")
except tk.TclError:
    pass
style.configure("TFrame", background="#141b24")
style.configure("TLabel", background="#141b24", foreground="#e8eef6")
style.configure("cyan.Horizontal.TProgressbar", troughcolor="#1e2834", background="#2a9d8f", bordercolor="#141b24", lightcolor="#2a9d8f", darkcolor="#2a9d8f")

frm = ttk.Frame(root, padding=18)
frm.pack(fill="both", expand=True)
ttk.Label(frm, text="Building", font=("sans-serif", 13, "bold")).pack(anchor="w")
status = ttk.Label(frm, text="Starting…")
status.pack(anchor="w", pady=(8, 8))
bar = ttk.Progressbar(frm, length=440, mode="determinate", maximum=100, style="cyan.Horizontal.TProgressbar")
bar.pack(fill="x")
pct_lbl = ttk.Label(frm, text="0%   0/10")
pct_lbl.pack(anchor="e", pady=(6, 0))

def read_progress():
    cur, total, pct, msg = 0, 10, 0, "Starting…"
    try:
        line = open(path, encoding="utf-8", errors="replace").read().strip().splitlines()[-1]
        left, pct_s, msg = line.split("|", 2)
        n_s, t_s = left.split("/", 1)
        cur, total, pct = int(n_s), int(t_s), int(float(pct_s))
    except Exception:
        pass
    return cur, total, pct, msg

def tick():
    cur, total, pct, msg = read_progress()
    bar["value"] = max(0, min(100, pct))
    status.configure(text=(msg or "Working…")[:140])
    pct_lbl.configure(text=f"{pct}%   {cur}/{total}")
    low = (msg or "").lower()
    if pct >= 100 and ("finished" in low or low.startswith("done") or "failed" in low):
        root.after(2800, root.destroy)
        return
    root.after(300, tick)

def on_close():
    try:
        os.remove(pidfile)
    except OSError:
        pass
    root.destroy()

root.protocol("WM_DELETE_WINDOW", on_close)
root.after(200, tick)
root.mainloop()
try:
    os.remove(pidfile)
except OSError:
    pass
PY
    PROGRESS_UI_PID=$!
    disown "$PROGRESS_UI_PID" 2>/dev/null || true
    dbg "progress window pid $PROGRESS_UI_PID"
}

runv() { dbg "+ $*"; "$@"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo -n "$@"; fi
}

usage() {
    cat <<EOF
$PROG — build a RaspAP 64-bit + WebOne Raspberry Pi image on Debian

USAGE
  sudo ./build-cli.sh                # text menu / flags
  sudo ./build-gui.sh                # graphical window
  sudo ./build-cli.sh --new
  sudo ./build-cli.sh --delete-all
  sudo ./build-cli.sh --update

If an .img already exists, the UI (or text menu) asks:
  New image / Update (check GitHub) / Delete all / Quit

OPTIONS
  --ui                 Open the graphical UI (tkinter) or whiptail
  --cli                Do not open a UI; use flags / text menu
  --new, --fresh       Wipe working files and rebuild from official RaspAP
  --delete-all         Delete work + output + downloads, then full rebuild
  --update [FILE]      Remount an existing .img, re-apply settings, and
                       install newer RaspAP / WebOne if GitHub has them
  --name NAME          Hostname (required; letters, digits, hyphen)
  --user USER          Login user (required; no default)
  --password PASS      Login password (required; no default)
  --ssid SSID          Hotspot SSID (default: $WIFI_SSID)
  --wifi-pass PSK      Hotspot PSK (default: ChangeMe; 8+ chars)
  --country CC         Wi-Fi country code (default: CA)
  --ssh                SSH on, password and public key
  --ssh-password       SSH on, password only (default)
  --ssh-pubkey         SSH on, public key only (needs --ssh-key)
  --no-ssh             SSH off
  --ssh-key FILE       Bake this .pub key (public-key SSH)
  --expand-mib N       Extra MiB via dd (default: $EXPAND_MIB)
  --workdir DIR        Scratch directory
  --outdir DIR         Output directory
  --skip-extras        WebOne only, no apt extras
  --skip-verify        Download without SHA-256 check
  --keep-work          Keep scratch dirs
  --install-launchers  Write build-cli.sh and build-gui.sh next to this script
  -h, --help           This help

SSH
  Choose password, public key, both, or off.
  Default is password.  Public key needs --ssh-key FILE (or Browse in the GUI).
  Off: Imager can still enable SSH later.
    OS -> Use custom -> this .img
    Next -> Edit OS customisation -> Services -> Enable SSH

PROGRESS
  Every step prints a percent bar. If you have a display, a progress
  window opens for the build (install python3-tk on Debian/Crostini).
  --cli skips the window; the terminal bar still prints.

RESUME
  Interrupted? Run the same command again. Or --new to start over.

EOF
}

cleanup() {
    local st=$?
    set +e
    if [[ "$NEED_UMOUNT" -eq 1 && -n "${ROOTMNT:-}" ]]; then
        dbg "cleanup: unmount $ROOTMNT"
        local p
        for p in proc sys dev/pts dev run; do
            as_root umount -l "$ROOTMNT/$p" 2>/dev/null
        done
        as_root umount -l "$ROOTMNT" 2>/dev/null
    fi
    if [[ -n "${LOOPDEV:-}" ]]; then
        dbg "cleanup: losetup -d $LOOPDEV"
        as_root losetup -d "$LOOPDEV" 2>/dev/null
    fi
    if [[ "$st" -ne 0 ]]; then
        warn "stopped (exit $st). Work kept in ${WORKDIR:-?} — run the same command again to resume."
        if [[ -f "${WORKDIR:-/dev/null}/last-error.txt" ]]; then
            warn "last error: $(tail -1 "$WORKDIR/last-error.txt")"
        fi
        warn "To start over:  sudo bash $PROG --new"
        if [[ -n "${PROGRESS_FILE:-}" ]]; then
            local last=""
            last="$(tail -1 "$WORKDIR/last-error.txt" 2>/dev/null || echo "stopped (exit $st)")"
            printf '%s/%s|%s|FAILED: %s\n' \
                "${CURRENT_STEP:-0}" "${PROGRESS_TOTAL:-10}" \
                "$(( CURRENT_STEP * 100 / ${PROGRESS_TOTAL:-10} ))" \
                "$last" > "$PROGRESS_FILE" 2>/dev/null || true
        fi
    else
        stop_progress_ui
    fi
    return 0
}
trap cleanup EXIT INT TERM

is_done() {
    local name="${1:-}"
    [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE}" && -n "$name" ]] && grep -qx "$name" "$STATE_FILE"
}
mark_done() {
    local name="${1:-}"
    [[ -n "${STATE_FILE:-}" && -n "$name" ]] || return 0
    mkdir -p "$(dirname "$STATE_FILE")"
    if ! is_done "$name"; then
        printf '%s\n' "$name" >> "$STATE_FILE"
    fi
    log "checkpoint: $name"
}
list_done() {
    if [[ -f "${STATE_FILE:-}" ]]; then
        tr '\n' ' ' < "$STATE_FILE"
    fi
}

write_launchers() {
    local dir="${SCRIPT_DIR}"
    cat > "$dir/build-cli.sh" <<'EOF'
#!/bin/bash
# Text-only launcher. Keep this file next to build-raspap-webone.sh
#   sudo ./build-cli.sh
#   ./build-cli.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/build-raspap-webone.sh"
[[ -f "$SCRIPT" ]] || { printf 'missing %s\n' "$SCRIPT" >&2; exit 1; }
if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$SCRIPT" --cli "$@"
fi
exec bash "$SCRIPT" --cli "$@"
EOF
    cat > "$dir/build-gui.sh" <<'EOF'
#!/bin/bash
# Graphical launcher. Keep this file next to build-raspap-webone.sh
#   sudo ./build-gui.sh
#   ./build-gui.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/build-raspap-webone.sh"
[[ -f "$SCRIPT" ]] || { printf 'missing %s\n' "$SCRIPT" >&2; exit 1; }
if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$SCRIPT" --ui "$@"
fi
exec bash "$SCRIPT" --ui "$@"
EOF
    chmod +x "$dir/build-cli.sh" "$dir/build-gui.sh"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)          DEVICE_NAME="$2"; shift 2 ;;
            --user)          USERNAME="$2"; shift 2 ;;
            --password)      PASSWORD="$2"; shift 2 ;;
            --ssid)          WIFI_SSID="$2"; shift 2 ;;
            --wifi-pass)     WIFI_PSK="$2"; shift 2 ;;
            --country)       WIFI_COUNTRY="$2"; shift 2 ;;
            --ssh)           SSH_MODE=both; ENABLE_SSH=1; shift ;;
            --ssh-password)  SSH_MODE=password; ENABLE_SSH=1; shift ;;
            --ssh-pubkey)    SSH_MODE=pubkey; ENABLE_SSH=1; shift ;;
            --no-ssh)        SSH_MODE=off; ENABLE_SSH=0; SSH_KEY=""; shift ;;
            --ssh-key)
                SSH_KEY="$2"
                ENABLE_SSH=1
                if [[ "${SSH_MODE:-password}" == "password" ]]; then
                    SSH_MODE=both
                elif [[ "${SSH_MODE:-}" != "both" ]]; then
                    SSH_MODE=pubkey
                fi
                shift 2
                ;;
            --expand-mib)    EXPAND_MIB="$2"; shift 2 ;;
            --workdir)       WORKDIR="$2"; shift 2 ;;
            --outdir)        OUTDIR="$2"; shift 2 ;;
            --skip-extras)   SKIP_EXTRAS=1; shift ;;
            --skip-verify)   SKIP_VERIFY=1; shift ;;
            --skip-download) SKIP_DOWNLOAD=1; shift ;;
            --keep-work)     KEEP_WORK=1; shift ;;
            --install-launchers) INSTALL_LAUNCHERS=1; shift ;;
            --ui)            WANT_UI=yes; shift ;;
            --cli)           WANT_UI=no; shift ;;
            --new|--fresh)   MODE=new; FRESH=1; WANT_UI=no; shift ;;
            --delete-all)    MODE=delete-all; FRESH=1; WANT_UI=no; shift ;;
            --update)
                MODE=update
                WANT_UI=no
                if [[ $# -ge 2 && "${2:0:1}" != "-" ]]; then
                    UPDATE_IMG="$2"; shift 2
                else
                    shift
                fi
                ;;
            --quiet)         shift ;;
            -h|--help)       usage; exit 0 ;;
            *) die "unknown option: $1 (try --help)" ;;
        esac
    done
}

ensure_loop() {
    [[ -n "${IMG:-}" && -f "$IMG" ]] || die "working image missing: ${IMG:-unset}"
    if [[ -n "${LOOPDEV:-}" && -b "${LOOPDEV}p2" ]]; then
        return 0
    fi
    local existing=""
    existing="$(losetup -j "$IMG" 2>/dev/null | awk -F: '{print $1; exit}')"
    if [[ -n "$existing" ]]; then
        LOOPDEV="$existing"
        dbg "reusing existing loop $LOOPDEV"
        if [[ ! -b "${LOOPDEV}p2" ]]; then
            warn "loop $LOOPDEV has no partitions — reattaching"
            as_root losetup -d "$LOOPDEV" || true
            LOOPDEV=""
        fi
    fi
    if [[ -z "${LOOPDEV:-}" ]]; then
        LOOPDEV="$(as_root losetup -f --show -P "$IMG")"
        log "attached $IMG -> $LOOPDEV"
    fi
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        [[ -b "${LOOPDEV}p2" ]] && return 0
        sleep 0.2
    done
    die "loop partition ${LOOPDEV}p2 did not appear"
}

ensure_mount() {
    ROOTMNT="$WORKDIR/root"
    mkdir -p "$ROOTMNT"
    if mountpoint -q "$ROOTMNT"; then
        NEED_UMOUNT=1
        dbg "rootfs already mounted at $ROOTMNT"
        return 0
    fi
    ensure_loop
    local p
    for p in proc sys dev/pts dev run; do
        if mountpoint -q "$ROOTMNT/$p"; then
            as_root umount -l "$ROOTMNT/$p" || true
        fi
    done
    runv as_root mount "${LOOPDEV}p2" "$ROOTMNT"
    NEED_UMOUNT=1
    log "mounted ${LOOPDEV}p2 on $ROOTMNT"
}

recover_stale_mounts() {
    ROOTMNT="$WORKDIR/root"
    if [[ -n "${IMG:-}" && -f "$IMG" ]]; then
        local existing=""
        existing="$(losetup -j "$IMG" 2>/dev/null | awk -F: '{print $1; exit}')"
        if [[ -n "$existing" ]]; then
            dbg "found leftover loop $existing"
            LOOPDEV="$existing"
        fi
    fi
    if [[ -d "${ROOTMNT:-}" ]] && mountpoint -q "$ROOTMNT"; then
        dbg "found leftover mount at $ROOTMNT"
        NEED_UMOUNT=1
    fi
}

install_host_deps() {
    step "1/10  Install Debian build tools on this host"
    export DEBIAN_FRONTEND=noninteractive
    export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"
    local missing=0 c
    for c in dd losetup parted resize2fs qemu-aarch64-static mdir openssl unzip wget python3; do
        command -v "$c" >/dev/null 2>&1 || missing=1
    done
    if [[ "$missing" -eq 0 && "$FRESH" -eq 0 ]]; then
        log "host tools already installed — skipping apt"
        mark_done host-deps
        return 0
    fi
    dbg "host: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}") $(uname -m)"
    df -h . | sed 's/^/[disk] /'
    runv as_root apt-get update
    runv as_root apt-get install -y --no-install-recommends \
        wget ca-certificates unzip openssl \
        util-linux fdisk parted e2fsprogs kpartx rsync \
        qemu-user-static binfmt-support mtools dosfstools \
        python3 python3-tk file
    for c in dd losetup parted resize2fs qemu-aarch64-static mdir openssl unzip wget python3; do
        dbg "found $c -> $(command -v "$c")"
        need_cmd "$c"
    done
    log "host tools OK"
    mark_done host-deps
}

register_qemu_binfmt() {
    step "2/10  Register qemu-aarch64 for arm64 chroot"
    if [[ ! -d /proc/sys/fs/binfmt_misc ]]; then
        as_root mkdir -p /proc/sys/fs/binfmt_misc
    fi
    if ! mountpoint -q /proc/sys/fs/binfmt_misc; then
        as_root mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true
    fi
    as_root update-binfmts --enable qemu-aarch64 2>/dev/null || true
    if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
        printf '%s\n' \
':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:CF' \
            | as_root tee /proc/sys/fs/binfmt_misc/register >/dev/null || true
    fi
    if [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
        log "qemu-aarch64 binfmt is registered"
    else
        warn "qemu binfmt not registered — extras install may extract-only"
    fi
    mark_done qemu-binfmt
}

github_asset_sha256() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys, urllib.request
repo, tag, name = sys.argv[1], sys.argv[2], sys.argv[3]
url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
req = urllib.request.Request(url, headers={"User-Agent": "raspap-webone-builder", "Accept": "application/vnd.github+json"})
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
except Exception:
    sys.exit(0)
for a in data.get("assets") or []:
    if a.get("name") == name:
        digest = a.get("digest") or ""
        if digest.startswith("sha256:"):
            print(digest.split(":", 1)[1].strip())
        break
PY
}

expected_raspap_sha256() {
    local got=""
    local name="raspap-trixie-arm64-lite-${RASPAP_VERSION}.img.zip"
    got="$(github_asset_sha256 RaspAP/raspap-webgui "$RASPAP_VERSION" "$name" 2>/dev/null || true)"
    if [[ -n "$got" ]]; then
        printf '%s\n' "$got"
        return 0
    fi
    if [[ "$RASPAP_VERSION" == "3.5.5" ]]; then
        printf '%s\n' "$RASPAP_SHA256_PIN"
    fi
}

expected_webone_sha256() {
    local got=""
    local name="webone.${WEBONE_VERSION}.linux-arm64.deb"
    got="$(github_asset_sha256 atauenis/webone "v${WEBONE_VERSION}" "$name" 2>/dev/null || true)"
    if [[ -n "$got" ]]; then
        printf '%s\n' "$got"
        return 0
    fi
    if [[ "$WEBONE_VERSION" == "0.18.2" ]]; then
        printf '%s\n' "$WEBONE_SHA256_PIN"
    fi
}

verify_sha256() {
    local file="$1" expect="$2" label="$3"
    [[ -s "$file" ]] || die "$label missing: $file"
    if [[ "${SKIP_VERIFY:-0}" -eq 1 ]]; then
        log "$label: skip verification"
        return 0
    fi
    log "verify $label"
    local got=""
    got="$(sha256sum "$file" | awk '{print $1}')"
    printf '%s  %s\n' "$got" "$(basename "$file")" > "${file}.sha256"
    log "$label sha256 $got"
    if [[ -n "${expect:-}" ]]; then
        if [[ "$got" != "$expect" ]]; then
            die "$label checksum mismatch (got $got want $expect). Delete $file and re-run, or use --skip-verify."
        fi
        log "$label checksum OK"
    else
        warn "$label: no published sha256 to compare; recorded ${file}.sha256"
    fi
}

download_sources() {
    step "3/10  Download and verify RaspAP zip + WebOne .deb"
    mkdir -p "$WORKDIR/dl"
    local zip="$WORKDIR/dl/raspap-arm64.img.zip"
    local deb="$WORKDIR/dl/webone.linux-arm64.deb"

    local want_wo want_rp
    want_wo="$(expected_webone_sha256 || true)"
    want_rp="$(expected_raspap_sha256 || true)"
    [[ -n "$want_wo" ]] && dbg "expected WebOne sha256 $want_wo"
    [[ -n "$want_rp" ]] && dbg "expected RaspAP sha256 $want_rp"

    if [[ "$MODE" == "update" ]]; then
        log "update mode: WebOne .deb only"
        if [[ ! -s "$deb" ]] || ! dpkg-deb -I "$deb" >/dev/null 2>&1; then
            local upid="" urc=0
            upid="$(progress_watch_bytes "$deb" 22000000 "Downloading WebOne .deb")"
            runv wget -c --show-progress --progress=bar:force:noscroll -O "$deb" "$WEBONE_DEB_URL" || urc=$?
            stop_watch "$upid"
            [[ "$urc" -eq 0 ]] || die "WebOne .deb download failed (exit $urc)"
        fi
        [[ -s "$deb" ]] || die "WebOne .deb download failed"
        dpkg-deb -I "$deb" >/dev/null 2>&1 || die "WebOne .deb is not a valid package"
        verify_sha256 "$deb" "$want_wo" "WebOne .deb"
        mark_done download
        return 0
    fi

    if [[ "$FRESH" -eq 0 && -s "$zip" && -s "$deb" ]] \
       && unzip -tqq "$zip" >/dev/null 2>&1 \
       && dpkg-deb -I "$deb" >/dev/null 2>&1; then
        log "downloads already present — verifying checksums"
        verify_sha256 "$deb" "$want_wo" "WebOne .deb"
        verify_sha256 "$zip" "$want_rp" "RaspAP zip"
        ls -lh "$zip" "$deb" | sed 's/^/[dl] /'
        mark_done download
        return 0
    fi

    if [[ ! -s "$deb" ]] || ! dpkg-deb -I "$deb" >/dev/null 2>&1; then
        log "downloading WebOne ${WEBONE_VERSION} arm64 (wget -c resumes)"
        local wpid="" wrc=0
        wpid="$(progress_watch_bytes "$deb" 22000000 "Downloading WebOne .deb")"
        runv wget -c --show-progress --progress=bar:force:noscroll -O "$deb" "$WEBONE_DEB_URL" || wrc=$?
        stop_watch "$wpid"
        [[ "$wrc" -eq 0 && -s "$deb" ]] || die "WebOne .deb download failed (exit $wrc)"
    else
        log "WebOne .deb already present"
    fi
    dpkg-deb -I "$deb" >/dev/null 2>&1 || die "WebOne .deb is not a valid package"
    verify_sha256 "$deb" "$want_wo" "WebOne .deb"

    if [[ ! -s "$zip" ]] || ! unzip -tqq "$zip" >/dev/null 2>&1; then
        log "downloading official RaspAP ${RASPAP_VERSION} 64-bit (~900 MB, wget -c resumes)"
        local zpid="" zrc=0
        zpid="$(progress_watch_bytes "$zip" 950000000 "Downloading RaspAP zip")"
        runv wget -c --show-progress --progress=bar:force:noscroll -O "$zip" "$RASPAP_ZIP_URL" || zrc=$?
        stop_watch "$zpid"
        [[ "$zrc" -eq 0 ]] || die "RaspAP zip download failed (exit $zrc)"
        unzip -tqq "$zip" || die "RaspAP zip still invalid after download"
    else
        log "RaspAP zip already present and valid"
    fi
    unzip -tqq "$zip" || die "RaspAP zip is not a valid archive"
    verify_sha256 "$zip" "$want_rp" "RaspAP zip"

    [[ -s "$zip" && -s "$deb" ]] || die "download failed"
    ls -lh "$zip" "$deb" | sed 's/^/[dl] /'
    mark_done download
}

dd_create_image() {
    step "4/10  Create the working .img with dd and grow it"
    local zip="$WORKDIR/dl/raspap-arm64.img.zip"
    local extract="$WORKDIR/extract"
    mkdir -p "$extract"

    local official_bytes expected have leftover
    official_bytes="$(unzip -l "$zip" | awk '/\.img$/{print $1; exit}')"
    [[ -n "$official_bytes" ]] || die "cannot read official .img size from zip"
    expected="$((official_bytes + EXPAND_MIB * 1024 * 1024))"
    dbg "official $official_bytes + ${EXPAND_MIB} MiB = $expected expected"

    if [[ "$FRESH" -eq 0 && -f "$IMG" ]]; then
        have="$(stat -c%s "$IMG")"
        if [[ "$have" -eq "$expected" ]]; then
            log "working image already grown ($have bytes) — skipping dd"
            ensure_loop
            mark_done image
            return 0
        fi
        warn "working image incomplete ($have / $expected bytes) — rebuilding"
        leftover="$(losetup -j "$IMG" 2>/dev/null | awk -F: '{print $1; exit}')"
        if [[ -n "$leftover" ]]; then
            as_root umount -l "${leftover}p2" 2>/dev/null || true
            as_root losetup -d "$leftover" || true
        fi
        rm -f "$IMG"
        LOOPDEV=""
    fi

    log "unzipping official RaspAP image"
    progress_within_step 10 "Unzipping official RaspAP image"
    runv unzip -o "$zip" -d "$extract"
    local src
    src="$(find "$extract" -maxdepth 1 -name '*.img' -print -quit)"
    [[ -n "$src" && -f "$src" ]] || die "no .img inside RaspAP zip"

    log "dd copy: $src -> $IMG"
    local dpid="" drc=0
    dpid="$(progress_watch_bytes "$IMG" "$official_bytes" "dd copy official image")"
    runv dd if="$src" of="$IMG" bs=4M status=progress conv=fsync || drc=$?
    stop_watch "$dpid"
    [[ "$drc" -eq 0 && -s "$IMG" ]] || die "dd copy failed (exit $drc)"
    rm -f "$src"

    log "dd grow: append ${EXPAND_MIB} MiB"
    dpid="$(progress_watch_bytes "$IMG" "$expected" "dd grow +${EXPAND_MIB} MiB")"
    drc=0
    runv dd if=/dev/zero of="$IMG" bs=1M count="$EXPAND_MIB" oflag=append conv=notrunc status=progress || drc=$?
    stop_watch "$dpid"
    [[ "$drc" -eq 0 ]] || die "dd grow failed (exit $drc)"
    [[ "$(stat -c%s "$IMG")" -eq "$expected" ]] || die "dd grow did not reach expected size $expected"

    runv parted -s "$IMG" resizepart 2 100%
    LOOPDEV="$(as_root losetup -f --show -P "$IMG")"
    log "loop device $LOOPDEV"
    local n
    for n in 1 2 3 4 5 6 7 8 9 10; do
        [[ -b "${LOOPDEV}p2" ]] && break
        sleep 0.3
    done
    [[ -b "${LOOPDEV}p2" ]] || die "loop partition ${LOOPDEV}p2 did not appear"
    runv as_root e2fsck -f -y "${LOOPDEV}p2"
    runv as_root resize2fs "${LOOPDEV}p2"
    runv as_root e2fsck -f -y "${LOOPDEV}p2"
    log "filesystem grown ($(stat -c%s "$IMG") bytes)"
    mark_done image
}

mount_root() {
    step "5/10  Mount the image root filesystem"
    ensure_mount
    log "rootfs mounted at $ROOTMNT"
    df -h "$ROOTMNT" | sed 's/^/[df] /'
}

set_identity() {
    step "6/10  Set hostname=${DEVICE_NAME}  user=${USERNAME}"
    ensure_mount
    local root="$ROOTMNT"
    if [[ "$FRESH" -eq 0 && "$FORCE_APPLY" -eq 0 ]] \
       && [[ "$(tr -d ' \n' < "$root/etc/hostname" 2>/dev/null || true)" == "$DEVICE_NAME" ]] \
       && grep -q "^${USERNAME}:" "$root/etc/passwd"; then
        log "hostname and user already set — skipping rewrite"
        if [[ ! -e "$root/etc/systemd/system/multi-user.target.wants/userconfig.service" \
           && -f "$root/usr/lib/systemd/system/userconfig.service" ]]; then
            as_root ln -sfn /usr/lib/systemd/system/userconfig.service \
                "$root/etc/systemd/system/multi-user.target.wants/userconfig.service"
        fi
        mark_done identity
        return 0
    fi

    local hash
    hash="$(openssl passwd -6 "$PASSWORD")"
    printf '%s\n' "$DEVICE_NAME" | as_root tee "$root/etc/hostname" >/dev/null
    as_root python3 - "$root/etc/hosts" "$DEVICE_NAME" <<'PY'
import sys
path, name = sys.argv[1], sys.argv[2]
text = open(path).read()
for old in ("raspberrypi", "raspap-webone"):
    text = text.replace(old, name)
if "10.3.141.1" not in text:
    text = text.rstrip() + f"\n10.3.141.1\t{name}\n"
open(path, "w").write(text)
PY

    as_root python3 - "$root" "$USERNAME" "$hash" <<'PY'
import pathlib, sys, shutil
root = pathlib.Path(sys.argv[1])
new_user = sys.argv[2]
new_hash = sys.argv[3]

def rewrite(rel, fn):
    p = root / rel
    if not p.exists():
        return
    lines = p.read_text().splitlines()
    p.write_text("\n".join(fn(lines)) + "\n")

def passwd(lines):
    out = []
    for line in lines:
        parts = line.split(":")
        if len(parts) >= 7 and parts[2] == "1000":
            parts[0] = new_user
            parts[4] = new_user
            parts[5] = f"/home/{new_user}"
            line = ":".join(parts)
        out.append(line)
    return out

def shadow(lines):
    out = []
    for line in lines:
        parts = line.split(":")
        if parts and parts[0] in ("pi", new_user):
            parts[0] = new_user
            parts[1] = new_hash
            line = ":".join(parts)
        out.append(line)
    names = [l.split(":")[0] for l in out if l]
    if new_user not in names:
        out.append(f"{new_user}:{new_hash}:20641:0:99999:7:::")
    return out

def group(lines):
    out = []
    for line in lines:
        parts = line.split(":")
        if not parts:
            out.append(line)
            continue
        if parts[0] == "pi":
            parts[0] = new_user
        if len(parts) >= 4 and parts[3]:
            members = [new_user if m == "pi" else m for m in parts[3].split(",")]
            parts[3] = ",".join(members)
        out.append(":".join(parts))
    return out

rewrite("etc/passwd", passwd)
rewrite("etc/shadow", shadow)
rewrite("etc/group", group)
if (root / "etc/gshadow").exists():
    rewrite("etc/gshadow", group)

old_home = root / "home/pi"
new_home = root / f"home/{new_user}"
if old_home.exists() and not new_home.exists():
    shutil.move(str(old_home), str(new_home))
new_home.mkdir(parents=True, exist_ok=True)
print("identity files rewritten")
PY
    as_root chown -R 1000:1000 "$root/home/$USERNAME"

    # Leave userconfig enabled so Raspberry Pi Imager can inject SSH keys.
    if [[ ! -e "$root/etc/systemd/system/multi-user.target.wants/userconfig.service" \
       && -f "$root/usr/lib/systemd/system/userconfig.service" ]]; then
        as_root ln -sfn /usr/lib/systemd/system/userconfig.service \
            "$root/etc/systemd/system/multi-user.target.wants/userconfig.service"
    fi
    as_root mkdir -p "$root/etc/ssh/sshd_config.d"
    as_root mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
    apply_sshd_settings "$root"

    if [[ -f "$root/etc/hostapd/hostapd.conf" ]]; then
        as_root sed -i \
            -e "s/^ssid=.*/ssid=${WIFI_SSID}/" \
            -e "s/^wpa_passphrase=.*/wpa_passphrase=${WIFI_PSK}/" \
            "$root/etc/hostapd/hostapd.conf"
        log "hostapd SSID=${WIFI_SSID}"
    fi
    apply_wifi_country "$root"
    mark_done identity
}

apply_wifi_country() {
    local root="${1:-}"
    local cc="${WIFI_COUNTRY:-CA}"
    cc="$(printf '%s' "$cc" | tr '[:lower:]' '[:upper:]')"
    WIFI_COUNTRY="$cc"
    [[ "$cc" =~ ^[A-Z]{2}$ ]] || die "Wi-Fi country must be a 2-letter code (got: $cc)"
    if [[ -f "$root/etc/hostapd/hostapd.conf" ]]; then
        if grep -q '^country_code=' "$root/etc/hostapd/hostapd.conf"; then
            as_root sed -i "s/^country_code=.*/country_code=${cc}/" "$root/etc/hostapd/hostapd.conf"
        else
            printf 'country_code=%s\n' "$cc" | as_root tee -a "$root/etc/hostapd/hostapd.conf" >/dev/null
        fi
        if grep -q '^ieee80211d=' "$root/etc/hostapd/hostapd.conf"; then
            as_root sed -i 's/^ieee80211d=.*/ieee80211d=1/' "$root/etc/hostapd/hostapd.conf"
        else
            printf 'ieee80211d=1\n' | as_root tee -a "$root/etc/hostapd/hostapd.conf" >/dev/null
        fi
    fi
    as_root mkdir -p "$root/etc/default" "$root/etc/modprobe.d"
    if [[ -f "$root/etc/default/crda" ]]; then
        if grep -q '^REGDOMAIN=' "$root/etc/default/crda"; then
            as_root sed -i "s/^REGDOMAIN=.*/REGDOMAIN=${cc}/" "$root/etc/default/crda"
        else
            printf 'REGDOMAIN=%s\n' "$cc" | as_root tee -a "$root/etc/default/crda" >/dev/null
        fi
    else
        printf 'REGDOMAIN=%s\n' "$cc" | as_root tee "$root/etc/default/crda" >/dev/null
    fi
    printf 'options cfg80211 ieee80211_regdom=%s\n' "$cc" \
        | as_root tee "$root/etc/modprobe.d/cfg80211-regdom.conf" >/dev/null
    if [[ -f "$root/etc/wpa_supplicant/wpa_supplicant.conf" ]]; then
        if grep -q '^country=' "$root/etc/wpa_supplicant/wpa_supplicant.conf"; then
            as_root sed -i "s/^country=.*/country=${cc}/" "$root/etc/wpa_supplicant/wpa_supplicant.conf"
        else
            as_root python3 - "$root/etc/wpa_supplicant/wpa_supplicant.conf" "$cc" <<'PY'
import sys
path, cc = sys.argv[1], sys.argv[2]
text = open(path).read()
head, sep, tail = text.partition("network=")
if "country=" not in head:
    text = f"country={cc}\n" + text
open(path, "w").write(text)
PY
        fi
    fi
    log "Wi-Fi country=${cc}"
}

apply_sshd_settings() {
    local root="${1:-}"
    [[ -n "$root" ]] || return 0
    as_root mkdir -p "$root/etc/ssh/sshd_config.d"
    as_root mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
    case "${SSH_MODE:-password}" in
        password)
            printf '%s\n' 'PubkeyAuthentication no' 'PasswordAuthentication yes' \
                | as_root tee "$root/etc/ssh/sshd_config.d/99-mob5824.conf" >/dev/null
            ;;
        pubkey)
            printf '%s\n' 'PubkeyAuthentication yes' 'PasswordAuthentication no' \
                | as_root tee "$root/etc/ssh/sshd_config.d/99-mob5824.conf" >/dev/null
            ;;
        both)
            printf '%s\n' 'PubkeyAuthentication yes' 'PasswordAuthentication yes' \
                | as_root tee "$root/etc/ssh/sshd_config.d/99-mob5824.conf" >/dev/null
            ;;
        *)
            as_root rm -f \
                "$root/etc/systemd/system/multi-user.target.wants/ssh.service" \
                "$root/etc/systemd/system/multi-user.target.wants/sshd.service" \
                "$root/etc/ssh/sshd_config.d/99-mob5824.conf"
            log "SSH disabled (Imager can still turn it on later)"
            ENABLE_SSH=0
            return 0
            ;;
    esac
    if [[ -f "$root/usr/lib/systemd/system/ssh.service" ]]; then
        as_root ln -sfn /usr/lib/systemd/system/ssh.service \
            "$root/etc/systemd/system/multi-user.target.wants/ssh.service"
    elif [[ -f "$root/lib/systemd/system/ssh.service" ]]; then
        as_root ln -sfn /lib/systemd/system/ssh.service \
            "$root/etc/systemd/system/multi-user.target.wants/ssh.service"
    fi
    ENABLE_SSH=1
    log "SSH mode=${SSH_MODE}"
}

install_ssh_key() {
    if [[ "${SSH_MODE:-password}" == "off" || "${ENABLE_SSH:-1}" -ne 1 ]]; then
        if [[ -n "${SSH_KEY:-}" ]]; then
            warn "SSH is off — ignoring --ssh-key $SSH_KEY"
        fi
        return 0
    fi
    if [[ "${SSH_MODE}" == "password" ]]; then
        return 0
    fi
    [[ -n "${SSH_KEY:-}" ]] || return 0
    ensure_mount
    local keyfile="$SSH_KEY"
    if [[ "$keyfile" == ~* ]]; then
        keyfile="${keyfile/#\~/${HOME}}"
    fi
    if [[ ! -f "$keyfile" && -n "${SUDO_USER:-}" ]]; then
        local uhome
        uhome="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        if [[ -n "$uhome" && -f "$uhome/${SSH_KEY#\~/}" ]]; then
            keyfile="$uhome/${SSH_KEY#\~/}"
        fi
    fi
    [[ -f "$keyfile" ]] || die "SSH public key not found: $SSH_KEY"
    local line
    line="$(tr -d '\r' < "$keyfile" | grep -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2) ' | head -1 || true)"
    [[ -n "$line" ]] || die "$keyfile does not look like an OpenSSH public key (.pub)"

    local sshdir="$ROOTMNT/home/$USERNAME/.ssh"
    local auth="$sshdir/authorized_keys"
    log "installing SSH public key for $USERNAME from $keyfile"
    as_root mkdir -p "$sshdir"
    if [[ -f "$auth" ]] && grep -Fqx "$line" "$auth"; then
        log "public key already in authorized_keys"
    else
        printf '%s\n' "$line" | as_root tee -a "$auth" >/dev/null
    fi
    as_root chmod 700 "$sshdir"
    as_root chmod 600 "$auth"
    as_root chown -R 1000:1000 "$sshdir"
}

write_overlay() {
    step "7/10  Write WebOne / WPAD / MOTD overlay into the image"
    ensure_mount
    local root="$ROOTMNT"
    if [[ "$FRESH" -eq 0 && "$FORCE_APPLY" -eq 0 \
       && -f "$root/etc/webone.conf.d/raspap.conf" && -f "$root/var/www/wpad/wpad.dat" ]]; then
        log "overlay already present — skipping"
        mark_done overlay
        return 0
    fi
    local ov="$WORKDIR/overlay"
    mkdir -p "$ov/etc/webone.conf.d" "$ov/etc/systemd/system/webone.service.d" \
             "$ov/etc/profile.d" "$ov/etc/lighttpd/conf-available" \
             "$ov/var/www/html/app" "$ov/var/www/wpad" "$ov/usr/local/sbin" \
             "$ov/home/$USERNAME"

    cat > "$ov/etc/webone.conf.d/raspap.conf" <<EOF
[Server]
Port=8080
DefaultHostName=10.3.141.1
SearchInArchive=yes
HideArchiveRedirect=yes
DisplayStatusPage=short
HideClientErrors=yes
ConnectionTimeout=30

[SecureProxy]
SslEnable=yes
EOF

    cat > "$ov/etc/systemd/system/webone.service.d/raspap.conf" <<'EOF'
[Unit]
After=network-online.target hostapd.service dnsmasq.service
Wants=network-online.target
[Install]
WantedBy=multi-user.target
EOF

    cat > "$ov/usr/local/sbin/webone-open-port.sh" <<'EOF'
#!/bin/bash
if command -v nft >/dev/null 2>&1; then
    nft add rule inet filter input tcp dport 8080 accept 2>/dev/null || true
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport 8080 -j ACCEPT || true
fi
exit 0
EOF
    chmod 755 "$ov/usr/local/sbin/webone-open-port.sh"

    cat > "$ov/etc/systemd/system/webone-firewall.service" <<'EOF'
[Unit]
Description=Allow WebOne HTTP proxy port 8080
After=network.target hostapd.service
Before=webone.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/webone-open-port.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

    cat > "$ov/var/www/wpad/wpad.dat" <<'EOF'
function FindProxyForURL(url, host) {
    if (isPlainHostName(host)) return "DIRECT";
    if (shExpMatch(host, "10.3.141.*") || shExpMatch(host, "*.local")) return "DIRECT";
    return "PROXY 10.3.141.1:8080; DIRECT";
}
EOF
    cp "$ov/var/www/wpad/wpad.dat" "$ov/var/www/html/app/wpad.dat"

    local ssh_note="SSH: disabled"
    if [[ "${SSH_MODE:-password}" != "off" && "${ENABLE_SSH:-1}" -eq 1 ]]; then
        case "${SSH_MODE}" in
            pubkey) ssh_note="SSH: ${USERNAME}@10.3.141.1 (public key)" ;;
            both)   ssh_note="SSH: ${USERNAME}@10.3.141.1 (password or public key)" ;;
            *)      ssh_note="SSH: ${USERNAME}@10.3.141.1 (password)" ;;
        esac
    fi

    cat > "$ov/var/www/html/app/webone.html" <<EOF
<!DOCTYPE html><html><head><title>WebOne on ${DEVICE_NAME}</title></head>
<body>
<h1>${DEVICE_NAME} — WebOne + RaspAP</h1>
<p>HTTP proxy: <b>10.3.141.1:8080</b> &nbsp; PAC: http://10.3.141.1/wpad.dat</p>
<p>Wi-Fi SSID <b>${WIFI_SSID}</b> / ${WIFI_PSK}</p>
<p>RaspAP admin: http://10.3.141.1/ (${RASPAP_ADMIN_USER}/${RASPAP_ADMIN_PASS})</p>
<p>${ssh_note}</p>
</body></html>
EOF

    cat > "$ov/etc/lighttpd/conf-available/45-webone.conf" <<'EOF'
server.modules += ( "mod_alias" )
alias.url += (
    "/wpad.dat"    => "/var/www/wpad/wpad.dat",
    "/wpad.da"     => "/var/www/wpad/wpad.dat",
    "/proxy.pac"   => "/var/www/wpad/wpad.dat",
    "/webone.html" => "/var/www/html/app/webone.html"
)
mimetype.assign += (
    ".dat" => "application/x-ns-proxy-autoconfig",
    ".pac" => "application/x-ns-proxy-autoconfig"
)
EOF

    cat > "$ov/etc/profile.d/webone-raspap.sh" <<EOF
if [ -n "\$PS1" ]; then
echo "------------------------------------------------------------"
echo " ${DEVICE_NAME}  —  RaspAP ${RASPAP_VERSION} + WebOne ${WEBONE_VERSION}"
echo " Wi-Fi: ${WIFI_SSID} / ${WIFI_PSK}"
echo " Admin: http://10.3.141.1/   ${RASPAP_ADMIN_USER} / ${RASPAP_ADMIN_PASS}"
echo " WebOne: 10.3.141.1:8080"
echo "------------------------------------------------------------"
fi
EOF

    cat > "$ov/home/$USERNAME/README.txt" <<EOF
${DEVICE_NAME} — RaspAP ${RASPAP_VERSION} + WebOne ${WEBONE_VERSION}

Wi-Fi: ${WIFI_SSID} / ${WIFI_PSK}
RaspAP: http://10.3.141.1/   ${RASPAP_ADMIN_USER} / ${RASPAP_ADMIN_PASS}
WebOne: 10.3.141.1:8080
${ssh_note}

Imager can still enable SSH later: Use custom -> OS customisation
-> Services -> Enable SSH.
EOF

    as_root rsync -a "$ov/etc/"  "$root/etc/"
    as_root rsync -a "$ov/usr/"  "$root/usr/"
    as_root rsync -a "$ov/var/"  "$root/var/"
    as_root rsync -a "$ov/home/" "$root/home/"
    as_root chown -R 1000:1000 "$root/home/$USERNAME"
    as_root chmod 755 "$root/usr/local/sbin/webone-open-port.sh"
    as_root ln -sfn /etc/lighttpd/conf-available/45-webone.conf \
        "$root/etc/lighttpd/conf-enabled/45-webone.conf"

    as_root tee "$root/etc/lighttpd/conf-available/50-raspap-router.conf" >/dev/null <<'EOF'
server.modules += (
	"mod_rewrite",
)
$HTTP["url"] =~ "^/(?!(dist|app|ajax|config|rootCA\\.pem|wpad\\.dat|wpad\\.da|proxy\\.pac|webone\\.html)).*" {
    url.rewrite-once = ( "^/(.*?)(\\?.+)?$"=>"/index.php/$1$2" )
    server.error-handler-404 = "/index.php"
}
EOF

    if [[ -f "$root/etc/dnsmasq.d/090_wlan0.conf" ]] \
       && ! grep -q 'dhcp-option=252' "$root/etc/dnsmasq.d/090_wlan0.conf"; then
        printf '%s\n' 'dhcp-option=252,http://10.3.141.1/wpad.dat' \
            | as_root tee -a "$root/etc/dnsmasq.d/090_wlan0.conf" >/dev/null
    fi

    printf '%s\n' \
        "${DEVICE_NAME} — RaspAP ${RASPAP_VERSION} + WebOne ${WEBONE_VERSION}" \
        "Wi-Fi: ${WIFI_SSID} / ${WIFI_PSK}    Admin: http://10.3.141.1/" \
        "Proxy: 10.3.141.1:8080" \
        | as_root tee "$root/etc/motd" >/dev/null

    as_root mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
    as_root mkdir -p "$root/etc/systemd/system/default.target.wants"
    as_root ln -sfn /etc/systemd/system/webone.service \
        "$root/etc/systemd/system/multi-user.target.wants/webone.service"
    as_root ln -sfn /etc/systemd/system/webone.service \
        "$root/etc/systemd/system/default.target.wants/webone.service"
    as_root ln -sfn /etc/systemd/system/webone-firewall.service \
        "$root/etc/systemd/system/multi-user.target.wants/webone-firewall.service"
    log "overlay installed"
    mark_done overlay
}

install_webone_and_extras() {
    step "8/10  Install WebOne + extras inside the arm64 image"
    ensure_mount
    local root="$ROOTMNT"
    local deb="$WORKDIR/dl/webone.linux-arm64.deb"

    if [[ -e "$root/usr/bin/systemctl.real" ]]; then
        warn "restoring /usr/bin/systemctl left by an interrupted chroot"
        as_root mv -f "$root/usr/bin/systemctl.real" "$root/usr/bin/systemctl"
    fi
    as_root rm -f "$root/usr/sbin/policy-rc.d"
    if [[ -f "$root/etc/resolv.conf.buildbak" ]]; then
        as_root mv -f "$root/etc/resolv.conf.buildbak" "$root/etc/resolv.conf"
    fi
    local p
    for p in proc sys dev/pts dev run; do
        if mountpoint -q "$root/$p"; then
            as_root umount -l "$root/$p" || true
        fi
    done

    if [[ "$FRESH" -eq 0 && -e "$root/usr/share/webone/webone" ]]; then
        log "WebOne already in the image — skipping package install"
        mark_done webone
        return 0
    fi

    as_root cp /usr/bin/qemu-aarch64-static "$root/usr/bin/qemu-aarch64-static"
    as_root cp /etc/resolv.conf "$root/etc/resolv.conf.buildbak"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | as_root tee "$root/etc/resolv.conf" >/dev/null
    printf '#!/bin/sh\nexit 101\n' | as_root tee "$root/usr/sbin/policy-rc.d" >/dev/null
    as_root chmod 755 "$root/usr/sbin/policy-rc.d"
    as_root mkdir -p "$root/tmp"
    [[ -f "$deb" ]] || die "WebOne .deb missing: $deb"
    as_root cp "$deb" "$root/tmp/webone.deb"

    local fs
    for fs in proc sys dev dev/pts; do
        as_root mkdir -p "$root/$fs"
        as_root mount --bind "/$fs" "$root/$fs"
    done

    local chroot_ok=0
    if as_root chroot "$root" /usr/bin/qemu-aarch64-static /bin/true 2>/dev/null \
       || as_root chroot "$root" /bin/true 2>/dev/null; then
        chroot_ok=1
        log "qemu chroot is working"
    else
        warn "qemu chroot failed — will extract the .deb"
    fi

    if [[ -x "$root/usr/bin/systemctl" && ! -e "$root/usr/bin/systemctl.real" ]]; then
        as_root mv "$root/usr/bin/systemctl" "$root/usr/bin/systemctl.real"
        printf '%s\n' '#!/bin/sh' 'exit 0' | as_root tee "$root/usr/bin/systemctl" >/dev/null
        as_root chmod 755 "$root/usr/bin/systemctl"
    fi

    run_chroot() {
        dbg "chroot: $*"
        if as_root chroot "$root" /usr/bin/qemu-aarch64-static "$@"; then
            return 0
        fi
        as_root chroot "$root" "$@"
    }

    if [[ "$chroot_ok" -eq 1 ]]; then
        run_chroot /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update || true
        if [[ "$SKIP_EXTRAS" -eq 0 ]]; then
            run_chroot /usr/bin/env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y --no-install-recommends imagemagick-7.q16 || true
        fi
        run_chroot /usr/bin/dpkg -i /tmp/webone.deb || true
        run_chroot /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -f install -y || true
        run_chroot /usr/bin/dpkg --configure -a || true
        if [[ "$SKIP_EXTRAS" -eq 0 ]]; then
            run_chroot /usr/bin/env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y --no-install-recommends \
                    ffmpeg yt-dlp ca-certificates openssl \
                    htop tmux vim-tiny git curl wget rsync unzip \
                    dnsutils iperf3 tcpdump traceroute || true
            run_chroot /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get clean || true
        fi
    else
        as_root dpkg-deb -x "$deb" "$root"
    fi

    if [[ -e "$root/usr/bin/systemctl.real" ]]; then
        as_root mv "$root/usr/bin/systemctl.real" "$root/usr/bin/systemctl"
    fi
    if [[ ! -e "$root/usr/share/webone" && ! -e "$root/usr/local/bin/webone" ]]; then
        as_root dpkg-deb -x "$deb" "$root"
    fi

    as_root mkdir -p "$root/var/log" "$root/etc/webone.conf.d"
    as_root touch "$root/var/log/webone.log" "$root/etc/webone.conf.d/ssl.crt" "$root/etc/webone.conf.d/ssl.key"
    as_root chmod 666 "$root/var/log/webone.log" "$root/etc/webone.conf.d/ssl.crt" "$root/etc/webone.conf.d/ssl.key"

    if [[ -f "$root/etc/systemd/system/webone.service" ]]; then
        as_root ln -sfn /etc/systemd/system/webone.service \
            "$root/etc/systemd/system/multi-user.target.wants/webone.service"
    fi

    for fs in dev/pts dev proc sys; do
        as_root umount -l "$root/$fs" 2>/dev/null || true
    done
    as_root rm -f "$root/usr/sbin/policy-rc.d" "$root/tmp/webone.deb"
    if [[ -f "$root/etc/resolv.conf.buildbak" ]]; then
        as_root mv "$root/etc/resolv.conf.buildbak" "$root/etc/resolv.conf"
    fi
    log "WebOne install phase finished"
    mark_done webone
}

write_boot_files() {
    step "9/10  Write userconf.txt and optional SSH flag onto the FAT boot partition"
    local bootpart=""
    local tmpdir=""
    local hash=""
    ensure_loop
    if [[ "$FRESH" -eq 0 && "$FORCE_APPLY" -eq 0 ]] && is_done bootfiles; then
        log "boot files already written — skipping"
        return 0
    fi
    export MTOOLS_SKIP_CHECK=1
    bootpart="${LOOPDEV}p1"
    tmpdir="$WORKDIR/bootfat"
    mkdir -p "$tmpdir"

    hash="$(openssl passwd -6 "$PASSWORD")"
    printf '%s:%s\n' "$USERNAME" "$hash" > "$tmpdir/userconf.txt"
    local ssh_note="SSH: disabled (turn on later in Raspberry Pi Imager if you want)"
    if [[ "${ENABLE_SSH:-1}" -eq 1 ]]; then
        : > "$tmpdir/ssh"
        ssh_note="SSH: ${USERNAME}@${DEVICE_NAME}.local"
    fi
    cat > "$tmpdir/README-${DEVICE_NAME}.txt" <<EOF
${DEVICE_NAME} — RaspAP ${RASPAP_VERSION} + WebOne ${WEBONE_VERSION}

Flash this whole disk image.

Wi-Fi: ${WIFI_SSID} / ${WIFI_PSK}
RaspAP: http://10.3.141.1/  (${RASPAP_ADMIN_USER}/${RASPAP_ADMIN_PASS})
WebOne: 10.3.141.1:8080
${ssh_note}

Imager can still enable SSH later: Use custom -> OS customisation
-> Services -> Enable SSH.
EOF

    log "writing userconf.txt + README onto boot FAT (device ${bootpart})"
    as_root env MTOOLS_SKIP_CHECK=1 mcopy -o -i "$bootpart" "$tmpdir/userconf.txt" ::userconf.txt || \
        warn "could not write userconf.txt (user is still in /etc/shadow)"
    if [[ "${ENABLE_SSH:-1}" -eq 1 ]]; then
        as_root env MTOOLS_SKIP_CHECK=1 mcopy -o -i "$bootpart" "$tmpdir/ssh" ::ssh || true
        log "SSH enabled: wrote boot/ssh"
    else
        as_root env MTOOLS_SKIP_CHECK=1 mdel -i "$bootpart" ::ssh 2>/dev/null || true
        as_root env MTOOLS_SKIP_CHECK=1 mdel -i "$bootpart" ::ssh.txt 2>/dev/null || true
        log "SSH disabled: removed boot/ssh if present"
    fi
    as_root env MTOOLS_SKIP_CHECK=1 mcopy -o -i "$bootpart" "$tmpdir/README-${DEVICE_NAME}.txt" \
        "::README-${DEVICE_NAME}.txt" || true
    mark_done bootfiles
}

finish_image() {
    step "10/10  Unmount, fsck, write final .img"
    if [[ "$UPDATE_IN_PLACE" -eq 1 ]]; then
        log "update-in-place: sync, unmount, fsck"
        sync
        if [[ -n "${ROOTMNT:-}" ]] && mountpoint -q "$ROOTMNT"; then
            runv as_root umount "$ROOTMNT" || as_root umount -l "$ROOTMNT"
        fi
        NEED_UMOUNT=0
        if [[ -n "${LOOPDEV:-}" ]]; then
            runv as_root e2fsck -f -y "${LOOPDEV}p2" || true
            runv as_root losetup -d "$LOOPDEV"
            LOOPDEV=""
        fi
        sync
        if [[ -f "$IMG" && "$IMG" != "$IMG_FINAL" ]]; then
            local fpid="" fexp=0 frc=0
            fexp="$(stat -c%s "$IMG")"
            fpid="$(progress_watch_bytes "$IMG_FINAL" "$fexp" "dd write final image")"
            runv dd if="$IMG" of="$IMG_FINAL" bs=4M status=progress conv=fsync || frc=$?
            stop_watch "$fpid"
            [[ "$frc" -eq 0 && -s "$IMG_FINAL" ]] || die "final dd failed (exit $frc)"
        fi
        sha256sum "$IMG_FINAL" > "${IMG_FINAL}.sha256"
        log "updated: $IMG_FINAL"
        ls -lh "$IMG_FINAL" | sed 's/^/[out] /'
        mark_done final
        return 0
    fi

    log "syncing and unmounting"
    sync
    if [[ -n "${ROOTMNT:-}" ]] && mountpoint -q "$ROOTMNT"; then
        runv as_root umount "$ROOTMNT" || as_root umount -l "$ROOTMNT"
    fi
    NEED_UMOUNT=0
    ensure_loop
    runv as_root e2fsck -f -y "${LOOPDEV}p2" || true
    runv as_root losetup -d "$LOOPDEV"
    LOOPDEV=""
    sync

    log "dd final copy: $IMG -> $IMG_FINAL"
    local fpid="" fexp=0 frc=0
    fexp="$(stat -c%s "$IMG")"
    fpid="$(progress_watch_bytes "$IMG_FINAL" "$fexp" "dd write final image")"
    runv dd if="$IMG" of="$IMG_FINAL" bs=4M status=progress conv=fsync || frc=$?
    stop_watch "$fpid"
    [[ "$frc" -eq 0 && -s "$IMG_FINAL" ]] || die "final dd failed (exit $frc)"
    rm -f "$IMG"
    sha256sum "$IMG_FINAL" > "${IMG_FINAL}.sha256"
    log "done: $IMG_FINAL"
    ls -lh "$IMG_FINAL" "${IMG_FINAL}.sha256" | sed 's/^/[out] /'
    mark_done final
}

find_existing_img() {
    if [[ -n "${UPDATE_IMG:-}" && -f "$UPDATE_IMG" ]]; then
        printf '%s\n' "$UPDATE_IMG"; return 0
    fi
    if [[ -n "${DEVICE_NAME:-}" && -s "${OUTDIR:-}/$DEVICE_NAME-raspap${RASPAP_VERSION}-webone${WEBONE_VERSION}-arm64.img" ]]; then
        printf '%s\n' "$OUTDIR/$DEVICE_NAME-raspap${RASPAP_VERSION}-webone${WEBONE_VERSION}-arm64.img"; return 0
    fi
    if [[ -n "${DEVICE_NAME:-}" && -s "${WORKDIR:-}/$DEVICE_NAME-working.img" ]]; then
        printf '%s\n' "$WORKDIR/$DEVICE_NAME-working.img"; return 0
    fi
    local found=""
    found="$(ls -1t "$OUTDIR"/*.img 2>/dev/null | head -1 || true)"
    [[ -n "$found" ]] && { printf '%s\n' "$found"; return 0; }
    found="$(ls -1t "$WORKDIR"/*-working.img 2>/dev/null | head -1 || true)"
    [[ -n "$found" ]] && printf '%s\n' "$found"
}

set_image_paths() {
    [[ -n "${DEVICE_NAME:-}" ]] || return 0
    IMG="$WORKDIR/${DEVICE_NAME}-working.img"
    IMG_FINAL="$OUTDIR/${DEVICE_NAME}-raspap${RASPAP_VERSION}-webone${WEBONE_VERSION}-arm64.img"
    if [[ "${MODE:-}" == "resume" && ! -s "$IMG" ]]; then
        local leftover=""
        leftover="$(ls -1t "$WORKDIR"/*-working.img 2>/dev/null | head -1 || true)"
        [[ -s "${leftover:-}" ]] && IMG="$leftover"
    fi
}

# Graphical UI (tkinter) or whiptail. Prints KEY=value lines to stdout.
launch_ui() {
    local existing="${1:-}"
    local out
    out="$(mktemp)"
    # Prefer the invoking user's X display when running under sudo
    local py=python3
    local env_prefix=()
    if [[ -n "${SUDO_USER:-}" && -n "${DISPLAY:-}" ]]; then
        env_prefix=(sudo -u "$SUDO_USER" env "DISPLAY=${DISPLAY}" \
            "XAUTHORITY=${XAUTHORITY:-/home/${SUDO_USER}/.Xauthority}" \
            "HOME=/home/${SUDO_USER}")
    fi

    if python3 -c "import tkinter" >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        "${env_prefix[@]+"${env_prefix[@]}"}" python3 - "$out" \
            "$DEVICE_NAME" "$USERNAME" "$PASSWORD" "$WIFI_SSID" "$WIFI_PSK" \
            "${SSH_KEY:-}" "$existing" "${SSH_MODE:-password}" "${WIFI_COUNTRY:-CA}" <<'PY'
import os, sys, tkinter as tk
from tkinter import ttk, filedialog, messagebox
import re
argv = sys.argv[1:]
out, name, user, pw, ssid, psk, ssh, existing = argv[:8]
ssh_mode_arg = argv[8] if len(argv) > 8 else "password"
country_arg = argv[9] if len(argv) > 9 else "CA"
if ssh_mode_arg in ("0", "off"):
    ssh_mode_arg = "off"
elif ssh_mode_arg in ("1", "yes"):
    ssh_mode_arg = "password"
elif ssh_mode_arg not in ("off", "password", "pubkey", "both"):
    ssh_mode_arg = "password"

BG, FG, MUTED, ACCENT, FIELD = "#141b24", "#e8eef6", "#8b9bb0", "#2a9d8f", "#1e2834"

root = tk.Tk()
root.title("RaspAP + WebOne")
root.configure(bg=BG)
root.minsize(460, 500)
try:
    root.tk.call("tk", "scaling", 1.1)
except tk.TclError:
    pass

style = ttk.Style()
try:
    style.theme_use("clam")
except tk.TclError:
    pass
style.configure(".", background=BG, foreground=FG, fieldbackground=FIELD, borderwidth=0)
style.configure("TFrame", background=BG)
style.configure("TLabel", background=BG, foreground=FG, font=("sans-serif", 10))
style.configure("Title.TLabel", background=BG, foreground=FG, font=("sans-serif", 15, "bold"))
style.configure("Muted.TLabel", background=BG, foreground=MUTED, font=("sans-serif", 9))
style.configure("TRadiobutton", background=BG, foreground=FG, font=("sans-serif", 10), padding=2)
style.configure("TCheckbutton", background=BG, foreground=FG, font=("sans-serif", 10), padding=2)
style.configure("TEntry", fieldbackground=FIELD, foreground=FG, insertcolor=FG, padding=4)
style.configure("TButton", padding=(8, 4), background="#2a3442", foreground=FG)
style.map("TButton", background=[("active", "#364457")])
style.configure("Accent.TButton", padding=(14, 6), background=ACCENT, foreground="#04110e")
style.map("Accent.TButton", background=[("active", "#38b8a6")])
style.configure("Ghost.TButton", padding=(6, 2), background=BG, foreground=MUTED)
style.map("TRadiobutton", background=[("active", BG)])
style.map("TCheckbutton", background=[("active", BG)])

frm = ttk.Frame(root, padding=20)
frm.pack(fill="both", expand=True)

ttk.Label(frm, text="RaspAP + WebOne", style="Title.TLabel").pack(anchor="w", pady=(0, 14))

mode = tk.StringVar(value="update" if existing else "new")
modes = ttk.Frame(frm)
modes.pack(fill="x", pady=(0, 4))
ttk.Radiobutton(modes, text="New", variable=mode, value="new").pack(side="left", padx=(0, 14))
ttk.Radiobutton(modes, text="Update", variable=mode, value="update",
                state=("normal" if existing else "disabled")).pack(side="left", padx=(0, 14))
ttk.Radiobutton(modes, text="Delete all", variable=mode, value="delete-all").pack(side="left")
if existing:
    shown = existing if len(existing) < 64 else "…" + existing[-61:]
    ttk.Label(frm, text=shown, style="Muted.TLabel").pack(anchor="w", pady=(2, 0))

grid = ttk.Frame(frm)
grid.pack(fill="x", pady=(16, 8))
vars = {}
entries = {}

def toggle_pw(ent, b):
    if ent.cget("show") == "*":
        ent.configure(show="")
        b.configure(text="Hide")
    else:
        ent.configure(show="*")
        b.configure(text="View")

rows = [
    ("Hostname", "name", name, None),
    ("User", "user", user, None),
    ("Password", "password", pw, "secret"),
    ("SSID", "ssid", ssid, None),
    ("Wi-Fi password", "psk", psk, "secret"),
    ("Country", "country", country_arg, None),
]
for i, (label, key, val, kind) in enumerate(rows):
    ttk.Label(grid, text=label).grid(row=i, column=0, sticky="w", pady=5, padx=(0, 10))
    v = tk.StringVar(value=val)
    vars[key] = v
    e = ttk.Entry(grid, textvariable=v, show=("*" if kind == "secret" else ""))
    e.grid(row=i, column=1, sticky="ew", pady=5)
    entries[key] = e
    if kind == "secret":
        btn = ttk.Button(grid, text="View", style="Ghost.TButton", width=5)
        btn.configure(command=lambda ent=e, b=btn: toggle_pw(ent, b))
        btn.grid(row=i, column=2, padx=(6, 0))
grid.columnconfigure(1, weight=1)

vars["ssh"] = tk.StringVar(value=ssh)
skip = tk.BooleanVar(value=False)
ssh_mode = tk.StringVar(value=ssh_mode_arg)

def sync_ssh(*_):
    st = "normal" if ssh_mode.get() in ("pubkey", "both") else "disabled"
    ssh_entry.configure(state=st)
    browse_btn.configure(state=st)

sshrow = ttk.Frame(frm)
sshrow.pack(fill="x", pady=(8, 0))
ttk.Label(sshrow, text="SSH").pack(side="left", padx=(0, 10))
for lab, val in (("Off", "off"), ("Password", "password"), ("Public key", "pubkey"), ("Both", "both")):
    ttk.Radiobutton(sshrow, text=lab, variable=ssh_mode, value=val, command=sync_ssh).pack(side="left", padx=(0, 12))

keyrow = ttk.Frame(frm)
keyrow.pack(fill="x", pady=(4, 0))
ttk.Label(keyrow, text="SSH key").pack(side="left", padx=(0, 10))
ssh_entry = ttk.Entry(keyrow, textvariable=vars["ssh"])
ssh_entry.pack(side="left", fill="x", expand=True)

def browse():
    pth = filedialog.askopenfilename(title="SSH public key", filetypes=[("Public keys", "*.pub"), ("All", "*")])
    if pth:
        vars["ssh"].set(pth)

browse_btn = ttk.Button(keyrow, text="Browse", style="Ghost.TButton", command=browse)
browse_btn.pack(side="left", padx=(6, 0))
sync_ssh()

skip_verify = tk.BooleanVar(value=False)
ttk.Checkbutton(frm, text="Skip extras", variable=skip).pack(anchor="w", pady=(10, 0))
ttk.Checkbutton(frm, text="Skip verification", variable=skip_verify).pack(anchor="w", pady=(4, 0))

btns = ttk.Frame(frm)
btns.pack(fill="x", pady=(18, 0))

def go():
    m = mode.get()
    if m == "update" and not existing:
        messagebox.showerror("No image", "There is no existing .img to update. Choose New or Delete all.")
        return
    user = vars["user"].get().strip()
    pw = vars["password"].get()
    ssid = vars["ssid"].get().strip()
    psk = vars["psk"].get()
    host = vars["name"].get().strip()
    if not host:
        messagebox.showerror("Missing", "Hostname is required.")
        return
    if not re.fullmatch(r"[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?", host):
        messagebox.showerror("Invalid", "Hostname: letters, digits, hyphen only. No spaces. Cannot start or end with a hyphen.")
        return
    if not user:
        messagebox.showerror("Missing", "Login user is required.")
        return
    if not pw:
        messagebox.showerror("Missing", "Login password is required.")
        return
    if not ssid:
        messagebox.showerror("Missing", "Wi-Fi SSID is required.")
        return
    if len(psk) < 8:
        messagebox.showerror("Missing", "Wi-Fi password must be at least 8 characters.")
        return
    cc = vars["country"].get().strip().upper()
    if len(cc) != 2 or not cc.isalpha():
        messagebox.showerror("Missing", "Wi-Fi country must be a 2-letter code (e.g. CA).")
        return
    sm = ssh_mode.get()
    key = vars["ssh"].get().strip()
    if sm == "pubkey" and not key:
        messagebox.showerror("Missing", "Public-key SSH needs a .pub file.")
        return
    lines = [
        f"MODE={m}",
        f"DEVICE_NAME={vars['name'].get().strip()}",
        f"USERNAME={vars['user'].get().strip()}",
        f"PASSWORD={vars['password'].get()}",
        f"WIFI_SSID={vars['ssid'].get().strip()}",
        f"WIFI_PSK={vars['psk'].get()}",
        f"WIFI_COUNTRY={cc}",
        f"SSH_KEY={key if sm in ('pubkey', 'both') else ''}",
        f"SSH_MODE={sm}",
        f"ENABLE_SSH={0 if sm == 'off' else 1}",
        f"SKIP_EXTRAS={1 if skip.get() else 0}",
        f"SKIP_VERIFY={1 if skip_verify.get() else 0}",
        f"UPDATE_IMG={existing}",
    ]
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    root.destroy()

def cancel():
    try:
        os.remove(out)
    except OSError:
        pass
    root.destroy()
    sys.exit(2)

ttk.Button(btns, text="Cancel", command=cancel).pack(side="right")
ttk.Button(btns, text="Start", style="Accent.TButton", command=go).pack(side="right", padx=(0, 8))
root.protocol("WM_DELETE_WINDOW", cancel)
root.mainloop()
if not os.path.isfile(out):
    sys.exit(2)
PY
        local rc=$?
        if [[ "$rc" -eq 0 && -s "$out" ]]; then
            # shellcheck disable=SC1090
            set -a
            # values are simple KEY=value, no spaces in keys
            # shellcheck disable=SC2163
            while IFS= read -r line; do
                [[ "$line" == *=* ]] || continue
                local k="${line%%=*}"
                local v="${line#*=}"
                case "$k" in
                    MODE|DEVICE_NAME|USERNAME|PASSWORD|WIFI_SSID|WIFI_PSK|WIFI_COUNTRY|SSH_KEY|SSH_MODE|ENABLE_SSH|SKIP_EXTRAS|SKIP_VERIFY|UPDATE_IMG)
                        printf -v "$k" '%s' "$v"
                        ;;
                esac
            done < "$out"
            set +a
            rm -f "$out"
            apply_mode_flags
            log "UI: mode=$MODE name=$DEVICE_NAME user=$USERNAME ssh=$SSH_MODE"
            return 0
        fi
        rm -f "$out"
        [[ "$WANT_UI" == "yes" ]] && die "UI cancelled"
        return 1
    fi

    if command -v whiptail >/dev/null 2>&1; then
        local choice
        choice="$(whiptail --title "RaspAP + WebOne" --menu "What do you want to do?" 16 72 4 \
            new "New image (rebuild from official RaspAP)" \
            update "Update existing (check GitHub for new versions)" \
            delete-all "Delete everything and start fresh" \
            quit "Quit" 3>&1 1>&2 2>&3)" || true
        case "${choice:-quit}" in
            new) MODE=new; FRESH=1 ;;
            update) MODE=update; UPDATE_IMG="$existing"; FORCE_APPLY=1; UPDATE_IN_PLACE=1 ;;
            delete-all) MODE=delete-all; FRESH=1 ;;
            *) die "cancelled" ;;
        esac
        log "whiptail: mode=$MODE"
        return 0
    fi
    return 1
}

normalize_ssh_mode() {
    case "${SSH_MODE:-}" in
        off|password|pubkey|both) ;;
        *)
            if [[ "${ENABLE_SSH:-1}" -eq 0 ]]; then
                SSH_MODE=off
            elif [[ -n "${SSH_KEY:-}" ]]; then
                SSH_MODE=pubkey
            else
                SSH_MODE=password
            fi
            ;;
    esac
    if [[ "$SSH_MODE" == "off" ]]; then
        ENABLE_SSH=0
    else
        ENABLE_SSH=1
    fi
}

valid_hostname() {
    local h="${1:-}"
    [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

require_identity() {
    [[ -n "${DEVICE_NAME:-}" ]] || die "hostname required (--name or the UI)"
    valid_hostname "$DEVICE_NAME" || die "hostname must be 1-63 characters: letters, digits, hyphen; no spaces; cannot start or end with a hyphen"
    [[ -n "${USERNAME:-}" ]] || die "login user required (--user or the UI). There is no default."
    [[ -n "${PASSWORD:-}" ]] || die "login password required (--password or the UI). There is no default."
    [[ -n "${WIFI_SSID:-}" ]] || die "Wi-Fi SSID required (--ssid or the UI)"
    [[ "${#WIFI_PSK}" -ge 8 ]] || die "Wi-Fi password required (--wifi-pass or the UI), at least 8 characters (default: ChangeMe)."
    WIFI_COUNTRY="$(printf '%s' "${WIFI_COUNTRY:-CA}" | tr '[:lower:]' '[:upper:]')"
    [[ "$WIFI_COUNTRY" =~ ^[A-Z]{2}$ ]] || die "Wi-Fi country must be a 2-letter code (--country CA)"
    normalize_ssh_mode
    if [[ "$SSH_MODE" == "pubkey" && -z "${SSH_KEY:-}" ]]; then
        die "public-key SSH requires --ssh-key FILE (or Browse in the GUI)"
    fi
}

apply_mode_flags() {
    case "${MODE:-}" in
        new) FRESH=1; UPDATE_IN_PLACE=0; FORCE_APPLY=0 ;;
        delete-all) FRESH=1; UPDATE_IN_PLACE=0; FORCE_APPLY=0 ;;
        update) FRESH=0; FORCE_APPLY=1; UPDATE_IN_PLACE=1 ;;
    esac
}

choose_build_mode() {
    local existing=""
    existing="$(find_existing_img || true)"

    if [[ "$MODE" == "new" ]]; then
        FRESH=1
        log "mode: NEW image (full rebuild)"
        return 0
    fi
    if [[ "$MODE" == "update" ]]; then
        [[ -n "$existing" ]] || die "no existing .img to update (pass --update FILE or build --new first)"
        UPDATE_IMG="$existing"
        FORCE_APPLY=1
        UPDATE_IN_PLACE=1
        log "mode: UPDATE $UPDATE_IMG"
        return 0
    fi
    local working=""
    working="$(ls -1t "$WORKDIR"/*-working.img 2>/dev/null | head -1 || true)"
    if [[ -f "${STATE_FILE:-}" ]] && ! is_done final && [[ -s "${working:-}" ]]; then
        MODE=resume
        IMG="$working"
        log "mode: RESUME interrupted build ($IMG)"
        return 0
    fi

    if [[ "$MODE" == "auto" && "$WANT_UI" != "no" ]]; then
        if [[ "$WANT_UI" == "yes" || -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] \
           || command -v whiptail >/dev/null 2>&1; then
            if launch_ui "${existing:-}"; then
                return 0
            fi
            [[ "$WANT_UI" == "yes" ]] && die "UI failed or cancelled"
        fi
    fi

    if [[ -z "$existing" ]]; then
        MODE=new
        log "mode: NEW image (nothing existing)"
        return 0
    fi

    if [[ -t 0 || -r /dev/tty ]]; then
        printf '\nFound an existing image:\n  %s\n\n' "$existing" >&2
        printf '  [n] New image    — rebuild from official RaspAP (keeps downloads)\n' >&2
        printf '  [u] Update       — remount .img, check GitHub for new RaspAP/WebOne\n' >&2
        printf '  [d] Delete all   — wipe work + output + downloads, then rebuild\n' >&2
        printf '  [q] Quit\n\n' >&2
        local ans=""
        if [[ -r /dev/tty ]]; then
            printf 'Choose [n/u/d/q]: ' >&2
            IFS= read -r ans < /dev/tty || true
        else
            printf 'Choose [n/u/d/q]: ' >&2
            IFS= read -r ans || true
        fi
        case "${ans,,}" in
            n|new) MODE=new; FRESH=1; log "mode: NEW (you chose rebuild)" ;;
            u|update)
                MODE=update
                UPDATE_IMG="$existing"
                FORCE_APPLY=1
                UPDATE_IN_PLACE=1
                log "mode: UPDATE (you chose update)"
                ;;
            d|delete|delete-all)
                MODE=delete-all
                FRESH=1
                log "mode: DELETE ALL then rebuild"
                ;;
            q|quit|'') die "cancelled" ;;
            *) die "unknown choice '$ans' (use n, u, d, or q)" ;;
        esac
    else
        if [[ -s "$IMG_FINAL" ]] && is_done final; then
            MODE=done
            log "mode: existing image complete. Use --update or --new."
        else
            MODE=new
            log "mode: NEW (non-interactive)"
        fi
    fi
}

github_latest_tag() {
    # print latest GitHub release tag without leading v  (repo like atauenis/webone)
    python3 - "$1" <<'PY'
import json, sys, urllib.request
repo = sys.argv[1]
url = f"https://api.github.com/repos/{repo}/releases/latest"
req = urllib.request.Request(url, headers={"User-Agent": "raspap-webone-builder"})
with urllib.request.urlopen(req, timeout=30) as resp:
    tag = json.load(resp).get("tag_name") or ""
print(tag.lstrip("vV"))
PY
}

version_gt() {
    # 0 if $1 > $2
    python3 - "$1" "$2" <<'PY'
import sys
def parts(s):
    out = []
    for p in s.lstrip("vV").replace("-", ".").split("."):
        try:
            out.append(int("".join(c for c in p if c.isdigit()) or "0"))
        except ValueError:
            out.append(0)
    return out
a, b = parts(sys.argv[1]), parts(sys.argv[2])
n = max(len(a), len(b))
a += [0] * (n - len(a))
b += [0] * (n - len(b))
sys.exit(0 if a > b else 1)
PY
}

detect_installed_webone() {
    local root="${1:-}"
    local v=""
    if [[ -f "$root/var/lib/dpkg/status" ]]; then
        v="$(awk '/^Package: webone$/{p=1} p&&/^Version:/{print $2; exit}' "$root/var/lib/dpkg/status" || true)"
    fi
    printf '%s' "${v:-}"
}

detect_installed_raspap() {
    local root="${1:-}"
    local v=""
    if [[ -f "$root/var/www/html/includes/defaults.php" ]]; then
        v="$(grep -oE 'RASPI_VERSION[^;]+' "$root/var/www/html/includes/defaults.php" | grep -oE '[0-9]+\.[0-9.]+' | head -1 || true)"
    fi
    if [[ -z "$v" && -d "$root/var/www/html/.git" ]]; then
        v="$(git -C "$root/var/www/html" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
    fi
    if [[ -z "$v" && -f "$root/etc/motd" ]]; then
        v="$(grep -oE 'RaspAP v?[0-9.]+' "$root/etc/motd" | grep -oE '[0-9.]+' | head -1 || true)"
    fi
    printf '%s' "${v:-unknown}"
}

upgrade_packages_if_newer() {
    step "UPDATE  Check GitHub for newer RaspAP and WebOne"
    ensure_mount
    local root="$ROOTMNT"
    local have_wo have_rp latest_wo latest_rp
    have_wo="$(detect_installed_webone "$root")"
    have_rp="$(detect_installed_raspap "$root")"
    [[ -n "$have_wo" ]] || have_wo="${WEBONE_VERSION}"
    log "installed WebOne: ${have_wo:-none}"
    log "installed RaspAP: ${have_rp}"

    latest_wo=""
    latest_rp=""
    latest_wo="$(github_latest_tag atauenis/webone 2>/dev/null || true)"
    latest_rp="$(github_latest_tag RaspAP/raspap-webgui 2>/dev/null || true)"
    log "latest WebOne on GitHub: ${latest_wo:-unknown}"
    log "latest RaspAP on GitHub: ${latest_rp:-unknown}"

    if [[ -n "$latest_wo" ]] && version_gt "$latest_wo" "${have_wo:-0}"; then
        log "WebOne ${have_wo} -> ${latest_wo}: downloading and installing"
        WEBONE_VERSION="$latest_wo"
        WEBONE_DEB_URL="https://github.com/atauenis/webone/releases/download/v${latest_wo}/webone.${latest_wo}.linux-arm64.deb"
        mkdir -p "$WORKDIR/dl"
        local deb="$WORKDIR/dl/webone.${latest_wo}.linux-arm64.deb"
        local gpid="" grc=0
        gpid="$(progress_watch_bytes "$deb" 22000000 "Downloading newer WebOne")"
        runv wget -c --show-progress --progress=bar:force:noscroll -O "$deb" "$WEBONE_DEB_URL" || grc=$?
        stop_watch "$gpid"
        [[ "$grc" -eq 0 && -s "$deb" ]] || die "WebOne .deb download failed (exit $grc)"
        dpkg-deb -I "$deb" >/dev/null 2>&1 || die "WebOne .deb is not a valid package"
        verify_sha256 "$deb" "$(expected_webone_sha256 || true)" "WebOne .deb"
        # force reinstall even if an older webone is present
        rm -f "$WORKDIR/dl/webone.linux-arm64.deb"
        ln -sfn "$deb" "$WORKDIR/dl/webone.linux-arm64.deb"
        # temporarily pretend webone is missing so install_webone_and_extras runs
        if [[ -e "$root/usr/share/webone/webone" ]]; then
            as_root mv "$root/usr/share/webone/webone" "$root/usr/share/webone/webone.prev" || true
        fi
        install_webone_and_extras || true
        [[ -e "$root/usr/share/webone/webone" ]] || \
            { [[ -e "$root/usr/share/webone/webone.prev" ]] && as_root mv "$root/usr/share/webone/webone.prev" "$root/usr/share/webone/webone"; }
        rm -f "$root/usr/share/webone/webone.prev"
    else
        log "WebOne is up to date"
    fi

    if [[ -n "$latest_rp" && "$have_rp" != "unknown" ]] && version_gt "$latest_rp" "$have_rp"; then
        log "RaspAP ${have_rp} -> ${latest_rp}: updating in the image (git/checkout)"
        RASPAP_VERSION="$latest_rp"
        local chroot_ok=0
        as_root cp /usr/bin/qemu-aarch64-static "$root/usr/bin/qemu-aarch64-static" 2>/dev/null || true
        if as_root chroot "$root" /usr/bin/qemu-aarch64-static /bin/true 2>/dev/null \
           || as_root chroot "$root" /bin/true 2>/dev/null; then
            chroot_ok=1
        fi
        if [[ "$chroot_ok" -eq 1 && -d "$root/var/www/html/.git" ]]; then
            local fs
            for fs in proc sys dev dev/pts; do
                as_root mkdir -p "$root/$fs"
                as_root mount --bind "/$fs" "$root/$fs" 2>/dev/null || true
            done
            as_root chroot "$root" /usr/bin/qemu-aarch64-static /usr/bin/git -C /var/www/html fetch --tags origin || \
                as_root chroot "$root" /usr/bin/git -C /var/www/html fetch --tags origin || true
            as_root chroot "$root" /usr/bin/qemu-aarch64-static /usr/bin/git -C /var/www/html checkout -f "$latest_rp" || \
                as_root chroot "$root" /usr/bin/git -C /var/www/html checkout -f "$latest_rp" || \
                warn "git checkout $latest_rp failed — RaspAP left at $have_rp"
            for fs in dev/pts dev proc sys; do
                as_root umount -l "$root/$fs" 2>/dev/null || true
            done
        else
            warn "cannot git-upgrade RaspAP in this image. Use --delete-all for a new official OS image."
        fi
    else
        log "RaspAP is up to date (or version unknown)"
    fi
}

prepare_update_image() {
    local src="${UPDATE_IMG:-}"
    [[ -f "$src" ]] || die "update source missing: $src"
    IMG="$src"
    log "updating in place: $IMG"
    local leftover=""
    leftover="$(losetup -j "$IMG" 2>/dev/null | awk -F: '{print $1; exit}')"
    if [[ -n "$leftover" ]]; then
        as_root umount -l "${leftover}p2" 2>/dev/null || true
        as_root losetup -d "$leftover" 2>/dev/null || true
    fi
    ensure_loop
}

INSTALL_LAUNCHERS=0

main() {
    parse_args "$@"
    write_launchers 2>/dev/null || true
    if [[ "${INSTALL_LAUNCHERS:-0}" -eq 1 ]]; then
        [[ -x "$SCRIPT_DIR/build-cli.sh" && -x "$SCRIPT_DIR/build-gui.sh" ]]             || die "could not write launchers in $SCRIPT_DIR"
        printf 'wrote:\n  %s\n  %s\n\nThen:\n  sudo ./build-cli.sh\n  sudo ./build-gui.sh\n'             "$SCRIPT_DIR/build-cli.sh" "$SCRIPT_DIR/build-gui.sh"
        exit 0
    fi
    [[ "$(id -u)" -eq 0 ]] || die "run as root:  sudo ./build-cli.sh   or   sudo ./build-gui.sh\nOr create the launchers:  bash $PROG --install-launchers"

    WORKDIR="${WORKDIR:-$SCRIPT_DIR/work}"
    OUTDIR="${OUTDIR:-$SCRIPT_DIR/out}"
    mkdir -p "$WORKDIR" "$OUTDIR"
    STATE_FILE="$WORKDIR/.build-state"

    choose_build_mode
    if [[ "$MODE" != "done" ]]; then
        require_identity
        set_image_paths
    else
        set_image_paths
    fi

    if [[ "$MODE" == "done" ]]; then
        ls -lh "$IMG_FINAL" | sed 's/^/[out] /'
        printf '\nImage ready:\n  %s\n\nTo change it:  sudo bash %s --update\nTo rebuild:    sudo bash %s --new\n\n' \
            "$IMG_FINAL" "$PROG" "$PROG"
        return 0
    fi

    if [[ "$FRESH" -eq 1 ]]; then
        log "--new: wiping leftover mounts, working image, checkpoints"
        ROOTMNT="$WORKDIR/root"
        if [[ -d "$ROOTMNT" ]]; then
            local p leftover
            for p in proc sys dev/pts dev run; do
                as_root umount -l "$ROOTMNT/$p" 2>/dev/null || true
            done
            as_root umount -l "$ROOTMNT" 2>/dev/null || true
        fi
        if [[ -f "$IMG" ]]; then
            leftover="$(losetup -j "$IMG" 2>/dev/null | awk -F: '{print $1; exit}')"
            [[ -n "${leftover:-}" ]] && as_root losetup -d "$leftover" 2>/dev/null || true
        fi
        rm -f "$STATE_FILE" "$IMG"
        rm -rf "$WORKDIR/extract" "$WORKDIR/overlay" "$WORKDIR/bootfat" "$WORKDIR/root"
        rm -f "$IMG_FINAL" "${IMG_FINAL}.sha256"
        if [[ "$MODE" == "delete-all" ]]; then
            log "delete-all: removing downloads too"
            rm -rf "$WORKDIR/dl"
            rm -f "$WORKDIR/last-error.txt"
            mkdir -p "$WORKDIR"
        fi
    fi

    printf '\n'
    log "RaspAP 64-bit + WebOne builder"
    log "device=$DEVICE_NAME user=$USERNAME mode=$MODE ssh=$SSH_MODE"
    log "workdir=$WORKDIR"
    log "output =$IMG_FINAL"
    df -h "$OUTDIR" | sed 's/^/[df] /'

    local free_kb free_mb
    free_kb="$(df -Pk "$OUTDIR" | awk 'NR==2{print $4}')"
    free_mb="$(( ${free_kb:-0} / 1024 ))"
    if [[ "$MODE" != "update" && "${free_kb:-0}" -lt 4500000 ]]; then
        die "not enough disk: need ~4.5 GB minimum, have ${free_mb} MiB. A full build peaks near 9 GB."
    fi
    if [[ "$MODE" != "update" && "${free_kb:-0}" -lt 10000000 ]]; then
        warn "only ${free_mb} MiB free — a full new build can need ~9 GB"
    fi

    recover_stale_mounts
    start_progress_ui
    progress_draw 0 "$PROGRESS_TOTAL" "Preparing host"
    install_host_deps
    register_qemu_binfmt

    if [[ "$MODE" == "update" ]]; then
        prepare_update_image
        mount_root
        set_identity
        install_ssh_key
        write_overlay
        upgrade_packages_if_newer
        if [[ ! -e "$ROOTMNT/usr/share/webone/webone" ]]; then
            download_sources
            install_webone_and_extras
        fi
        write_boot_files
        finish_image
    else
        download_sources
        dd_create_image
        mount_root
        set_identity
        install_ssh_key
        write_overlay
        install_webone_and_extras
        write_boot_files
        finish_image
    fi

    if [[ "$KEEP_WORK" -eq 0 ]]; then
        rm -rf "$WORKDIR/extract" "$WORKDIR/overlay" "$WORKDIR/bootfat" "$WORKDIR/root"
    fi

    progress_draw "$PROGRESS_TOTAL" "$PROGRESS_TOTAL" "BUILD FINISHED"
    printf '\n[%s] BUILD FINISHED\n' "$(ts)"
    printf '\nImage ready:\n  %s\n\nFlash with Raspberry Pi Imager (Use custom) or:\n  sudo dd if=%s of=/dev/sdX bs=4M status=progress conv=fsync && sync\n\n' \
        "$IMG_FINAL" "$IMG_FINAL"
    sleep 3
}

main "$@"
