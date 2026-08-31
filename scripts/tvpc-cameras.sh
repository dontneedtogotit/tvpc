#!/usr/bin/env bash
# tvpc-cameras — discover, configure, and view IP security cameras
# on the local network as picture-in-picture (always-on-top borderless)
# windows.
#
# Subcommands:
#   scan           Discover cameras on the LAN (RTSP + ONVIF probe)
#   list           Show the configured camera list
#   add NAME URL [USER [PASS]]   Add a camera manually
#   remove ID      Remove a camera by ID (number, see `list`)
#   view ID        Open a single camera in a PiP window
#   grid           Open all cameras in a 2x2 grid of PiP windows
#   menu           GUI menu (kdialog) to do everything from the couch
#   config         Print / edit the config file path
#
# Config file:  ~/.config/tvpc/cameras.conf   (one line per camera)
# Format:       NAME|URL|USER|PASS|NOTES
#
# PiP is implemented as an always-on-top, borderless mpv window in the
# bottom-right corner. mpv must be installed.
set -euo pipefail

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tvpc"
CONF_FILE="$CONF_DIR/cameras.conf"
PIP_W=480
PIP_H=270
PIP_MARGIN=24

have() { command -v "$1" >/dev/null 2>&1; }

# --- Config ---------------------------------------------------------------
ensure_conf() { mkdir -p "$CONF_DIR"; [[ -f $CONF_FILE ]] || : >"$CONF_FILE"; }

read_cameras() {
    ensure_conf
    local i=0 line
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == \#* || -z $line ]] && continue
        echo "$i|$line"
        i=$((i + 1))
    done <"$CONF_FILE"
}

write_cameras() {
    # stdin: lines of "NAME|URL|USER|PASS|NOTES"
    ensure_conf
    tee "$CONF_FILE" >/dev/null
}

get_camera() {
    local id="$1"
    read_cameras | awk -F'|' -v want="$id" '$1==want {for(i=2;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|"); print ""; exit}'
}

# --- Discovery ------------------------------------------------------------
local_subnet() {
    # Print the /24 base for the default route's interface, e.g. 192.168.1
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {split($(i+1),a,"."); print a[1]"."a[2]"."a[3]; exit}}'
}

# Try a URL with ffprobe; returns 0 if it looks like a media stream.
probe_url() {
    local url="$1" user="${2:-}" pass="${3:-}"
    have ffprobe || return 1
    local args=(-v error -show_streams -of default=nw=1)
    if [[ -n $user ]]; then
        FFREPORT= ffmpeg_password="" \
        ffprobe -loglevel error -rtsp_transport tcp -i "$url" \
            -user "$user" -password "$pass" \
            -show_entries stream=codec_name -of csv=p=0 2>/dev/null \
            && return 0
    else
        timeout 5 ffprobe -v error -rtsp_transport tcp -i "$url" \
            -show_entries stream=codec_name -of csv=p=0 2>/dev/null \
            && return 0
    fi
    return 1
}

# Quick TCP port check.
tcp_open() {
    local host="$1" port="$2"
    timeout 1 bash -c ">/dev/tcp/$host/$port" 2>/dev/null
}

# Common RTSP stream paths to try
RTSP_PATHS=(
    "/Streaming/Channels/101"      # Hikvision main
    "/Streaming/Channels/1"        # Hikvision alt
    "/Streaming/Channels/102"      # Hikvision sub
    "/cam/realmonitor"             # Dahua
    "/onvif/Streaming/Channels/101"
    "/onvif/Streaming/Channels/1"
    "/live/main"                   # generic
    "/live/sub"                    # generic sub
    "/live/0/main"                 # Reolink
    "/h264Preview_01_main"         # Axis-like
    "/11"                          # Reolink alt
    "/stream1"                     # generic
    "/stream2"
    "/av0_0"                      # some Chinese cams
    "/video"                       # some MJPEG-over-RTSP
    "/"                            # root
)

scan_rtsp() {
    local subnet="$1" cred="$2"   # cred like "user:pass" or empty
    log "Probing $subnet.0/24 on TCP 554 (RTSP) — up to 30 s..."
    local host p ip
    for ip in $(seq 1 254); do
        host="$subnet.$ip"
        if tcp_open "$host" 554; then
            printf '  \033[1;33mRTSP\033[0m  %s  (port 554 open)\n' "$host"
            # Try common paths. If any works, this is a real camera.
            local path
            for path in "${RTSP_PATHS[@]}"; do
                local url="rtsp://$host$path"
                if probe_url "$url" $cred; then
                    printf '    \033[1;32mLIVE\033[0m  %s\n' "$url"
                    return 0
                fi
            done
        fi
    done
    return 1
}

# ONVIF WS-Discovery: send a UDP probe to 239.255.255.250:3702 and collect
# XAddrs from ProbeMatches. Uses python3 (always present) — no extra deps.
onvif_probe() {
    have python3 || return 1
    python3 - "$subnet" <<'PY' 2>/dev/null
import socket, struct, time, re, sys, uuid

msg = (
    '<?xml version="1.0" encoding="utf-8"?>'
    '<Envelope xmlns:dn="http://www.onvif.org/ver10/network/wsdl"'
    ' xmlns="http://www.w3.org/2003/05/soap-envelope">'
    '<Header>'
    '<wsa:MessageID xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
    'uuid:' + str(uuid.uuid4()) +
    '</wsa:MessageID>'
    '<wsa:To xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
    'urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>'
    '<wsa:Action xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
    'http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>'
    '</Header>'
    '<Body>'
    '<Probe xmlns="http://schemas.xmlsoap.org/ws/2005/04/discovery">'
    '<Types>dn:NetworkVideoTransmitter</Types>'
    '</Probe>'
    '</Body>'
    '</Envelope>'
).encode('utf-8')

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(socket.gethostbyname(socket.gethostname())))
s.settimeout(2.0)
s.sendto(msg, ("239.255.255.250", 3702))
end = time.time() + 3
while time.time() < end:
    try:
        data, addr = s.recvfrom(8192)
    except socket.timeout:
        break
    text = data.decode('utf-8', 'ignore')
    for m in re.finditer(r'XAddrs>([^<]+)</', text):
        print(m.group(1).strip())
PY
}

cmd_scan() {
    local subnet; subnet="$(local_subnet)"
    if [[ -z $subnet ]]; then
        echo "No IPv4 default route found. Connect to a network first." >&2
        return 1
    fi
    log "Scanning $subnet.0/24"

    # RTSP sweep (background, capped by per-host timeout)
    local found=()
    log "  (1) RTSP probe (TCP 554) — this takes ~30 s"
    local out
    out=$(scan_rtsp_quick "$subnet")
    [[ -n $out ]] && echo "$out"

    log "  (2) ONVIF WS-Discovery multicast"
    local onvif
    onvif=$(onvif_probe 2>/dev/null || true)
    if [[ -n $onvif ]]; then
        echo "$onvif" | grep -oE 'http://[^/]+' | sort -u | sed 's/^/  ONVIF   /'
    else
        echo "  (no ONVIF responses)"
    fi

    log "Done. Use 'tvpc-cameras add NAME URL' to add what you found,"
    log "or 'tvpc-cameras menu' for a GUI."
}

# A faster RTSP sweep that only reports which IPs have port 554 open.
scan_rtsp_quick() {
    local subnet="$1"
    local ip
    for ip in $(seq 1 254); do
        if tcp_open "$subnet.$ip" 554; then
            printf 'RTSP   %s\n' "$subnet.$ip"
        fi
    done
}

# --- List / add / remove --------------------------------------------------
cmd_list() {
    echo "== Cameras ($CONF_FILE) =="
    printf '  %-4s %-20s %s\n' "ID" "Name" "URL"
    local line
    while IFS= read -r line; do
        IFS='|' read -r id name url user pass notes <<<"$line"
        printf '  %-4s %-20s %s\n' "$id" "$name" "$url"
    done < <(read_cameras)
}

cmd_add() {
    local name="${1:-}" url="${2:-}" user="${3:-}" pass="${4:-}" notes="${5:-}"
    if [[ -z $name || -z $url ]]; then
        echo "Usage: tvpc-cameras add NAME URL [USER [PASS [NOTES]]]" >&2
        return 1
    fi
    ensure_conf
    printf '%s|%s|%s|%s|%s\n' "$name" "$url" "$user" "$pass" "$notes" >>"$CONF_FILE"
    log "Added '$name' ($url)"
}

cmd_remove() {
    local id="${1:-}"
    [[ -z $id ]] && { echo "Usage: tvpc-cameras remove ID" >&2; return 1; }
    local tmp; tmp="$(mktemp)"
    local n=0
    while IFS= read -r line; do
        if [[ $n -ne $id ]]; then echo "$line"; fi
        n=$((n + 1))
    done <"$CONF_FILE" >"$tmp"
    mv "$tmp" "$CONF_FILE"
    log "Removed ID $id"
}

# --- Playback (PiP) -------------------------------------------------------
play() {
    local url="$1" name="$2" x="$3" y="$4" w="$5" h="$6"
    if ! have mpv; then
        echo "mpv is not installed. sudo apt-get install mpv" >&2
        return 1
    fi
    mpv --no-terminal --quiet \
        --title="tvpc-cameras: $name" \
        --geometry="${w}x${h}+${x}+${y}" \
        --border=no --title-bar=no \
        --no-osc --no-input-terminal --no-input-cursor \
        --keep-open=always \
        --ontop --on-top-level=system \
        --rtsp-transport=tcp \
        --hwdec=auto-safe \
        --force-window=immediate \
        "$url" &
}

# Compute a (x, y) for PiP #N out of N total, in a grid.
pip_pos() {
    local n="$1" total="$2" w="$3" h="$4"
    local screen_w screen_h
    screen_w=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2}' | cut -dx -f1)
    screen_h=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2}' | cut -dx -f2)
    screen_w=${screen_w:-1920}; screen_h=${screen_h:-1080}
    local cols
    case "$total" in
        1) cols=1 ;;
        2|3|4) cols=2 ;;
        *) cols=3 ;;
    esac
    local row=$(( n / cols )) col=$(( n % cols ))
    local x=$(( screen_w - w - PIP_MARGIN - col * (w + PIP_MARGIN) ))
    local y=$(( screen_h - h - PIP_MARGIN - row * (h + PIP_MARGIN) ))
    printf '%d %d\n' "$x" "$y"
}

cmd_view() {
    local id="${1:-}"
    [[ -z $id ]] && { echo "Usage: tvpc-cameras view ID" >&2; return 1; }
    local line; line="$(get_camera "$id")"
    [[ -z $line ]] && { echo "No camera with ID $id" >&2; return 1; }
    IFS='|' read -r name url user pass notes <<<"$line"
    local cred_args=()
    if [[ -n $user ]]; then cred_args=(--user "$user" --password "$pass"); fi
    mpv --no-terminal --quiet \
        --title="tvpc-cameras: $name" \
        --geometry="${PIP_W}x${PIP_H}+0+0" \
        --border=no --title-bar=no \
        --no-osc --no-input-terminal --no-input-cursor \
        --keep-open=always \
        --ontop --on-top-level=system \
        --rtsp-transport=tcp --hwdec=auto-safe \
        --force-window=immediate \
        "${cred_args[@]}" "$url" &
    log "Opened $name in a PiP window (PID $!)"
}

cmd_grid() {
    have mpv || { echo "mpv not installed. sudo apt-get install mpv" >&2; return 1; }
    local n=0
    while IFS= read -r line; do
        IFS='|' read -r name url user pass notes <<<"$line"
        local x y; read -r x y < <(pip_pos "$n" "4" "$PIP_W" "$PIP_H")
        play "$url" "$name" "$x" "$y" "$PIP_W" "$PIP_H"
        n=$((n + 1))
        [[ $n -ge 4 ]] && break
    done < <(read_cameras | awk -F'|' '{$1=""; print substr($0,2)}')
    log "Opened $n camera(s) in a 2x2 grid"
}

# --- GUI ------------------------------------------------------------------
cmd_menu() {
    have kdialog || { cmd_list; return 0; }
    while true; do
        local items
        items=$(read_cameras | awk -F'|' '{
            printf "%d|%s|%s\n", $1, $2, $3
        }')
        local lines=()
        local i
        while IFS='|' read -r id name url; do
            lines+=("$id" "▶ $name  ($url)")
        done <<<"$items"
        lines+=("scan" "🔍 Scan the network")
        lines+=("add"  "➕ Add camera manually")
        lines+=("grid" "▦ Open all as 2x2 grid")

        local choice
        choice=$(kdialog --menu "tvpc-cameras" \
            "Choose a camera to open, or an action" "${lines[@]}" 2>/dev/null) || return 0

        case "$choice" in
            scan) cmd_scan ;;
            add)
                local n u
                n=$(kdialog --inputbox "Camera name:" "front_door" 2>/dev/null) || continue
                u=$(kdialog --inputbox "Stream URL (rtsp:// or http://):" "rtsp://" 2>/dev/null) || continue
                cmd_add "$n" "$u"
                ;;
            grid) cmd_grid ;;
            "")   return 0 ;;
            *)    cmd_view "$choice" ;;
        esac
    done
}

# --- Help -----------------------------------------------------------------
cmd_help() {
    sed -n '2,20p' "$0" | sed 's/^# *//'
}

# --- Dispatch -------------------------------------------------------------
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
case "${1:-menu}" in
    scan)     cmd_scan ;;
    list)     cmd_list ;;
    add)      shift; cmd_add "$@" ;;
    remove|rm) shift; cmd_remove "$@" ;;
    view|play) shift; cmd_view "$@" ;;
    grid)     cmd_grid ;;
    menu|gui|"") cmd_menu ;;
    config)   echo "$CONF_FILE" ;;
    help|--help|-h) cmd_help ;;
    *) echo "Unknown command: $1 (try: tvpc-cameras help)"; exit 1 ;;
esac
