#!/usr/bin/env bash
# tvpc-audio-manager.sh - Advanced audio management for HTPC
#
# This script provides better control over audio profiles, volume, and routing.
# It can be called by keyboard shortcuts or system events.

set -euo pipefail

LOG_FILE="/var/log/tvpc-audio-manager.log"
log() {
    echo "$(date): $1" | tee -a "$LOG_FILE"
}

usage() {
    echo "Usage: $0 {profile|volume|mute|help} [args]"
    echo ""
    echo "Commands:"
    echo "  profile <name>    - Set audio profile (e.g., hdmi-stereo, hdmi-surround)"
    echo "  volume <level>    - Set volume percentage (0-100)"
    echo "  volume up/down    - Increase/decrease volume by 5%"
    echo "  mute              - Toggle mute"
    echo "  status            - Show current audio status"
    echo "  help              - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 profile hdmi-surround-extra"
    echo "  $0 volume 75"
    echo "  $0 volume up"
    echo "  $0 mute"
    exit 1
}

get_default_sink() {
    pactl get-default-sink
}

list_sinks() {
    pactl list short sinks
}

case "${1:-}" in
    profile)
        if [[ -z "${2:-}" ]]; then
            echo "Available sinks:"
            list_sinks
            echo ""
            echo "Common profiles for NUC7i5BNH:"
            echo "  alsa_output.pci-0000_00_1f.3.hdmi-stereo"
            echo "  alsa_output.pci-0000_00_1f.3.hdmi-stereo-extra"
            echo "  alsa_output.pci-0000_00_1f.3.hdmi-surround"
            echo "  alsa_output.pci-0000_00_1f.3.hdmi-surround-extra"
            echo "  alsa_output.pci-0000_00_1f.3.analog-stereo"
            exit 1
        fi
        
        PROFILE="$2"
        log "Setting audio profile to: $PROFILE"
        if pactl set-card-profile alsa_card.pci-0000_00_1f.3 "$PROFILE"; then
            log "Profile set successfully"
            # Also set as default sink if it's a sink profile
            if [[ "$PROFILE" == *"output"* ]]; then
                pactl set-default-sink "$PROFILE"
                log "Set as default sink: $PROFILE"
            fi
        else
            log "Failed to set profile: $PROFILE"
            exit 1
        fi
        ;;
        
    volume)
        if [[ -z "${2:-}" ]]; then
            CURRENT_VOL=$(pactl get-sink-volume @DEFAULT_SINK@ | awk '{print $5}' | tr -d '%')
            echo "Current volume: $CURRENT_VOL%"
            exit 0
        fi
        
        if [[ "$2" == "up" ]]; then
            pactl set-sink-volume @DEFAULT_SINK@ +5%
            log "Volume increased by 5%"
        elif [[ "$2" == "down" ]]; then
            pactl set-sink-volume @DEFAULT_SINK@ -5%
            log "Volume decreased by 5%"
        else
            # Assume it's a percentage
            VOL="$2"
            if [[ "$VOL" =~ ^[0-9]+$ ]] && [[ "$VOL" -ge 0 ]] && [[ "$VOL" -le 100 ]]; then
                pactl set-sink-volume @DEFAULT_SINK@ "${VOL}%"
                log "Volume set to ${VOL}%"
            else
                echo "Error: Volume must be between 0 and 100, or 'up'/'down'"
                exit 1
            fi
        fi
        ;;
        
    mute)
        pactl set-sink-mute @DEFAULT_SINK@ toggle
        MUTED=$(pactl get-sink-mute @DEFAULT_SINK@ | awk '{print $2}')
        if [[ "$MUTED" == "yes" ]]; then
            log "Audio muted"
        else
            log "Audio unmuted"
        fi
        ;;
        
    status)
        echo "=== Audio Status ==="
        echo "Default sink: $(get_default_sink)"
        echo ""
        echo "Available sinks:"
        list_sinks
        echo ""
        echo "Card profiles for alsa_card.pci-0000_00_1f.3:"
        pactl list cards | grep -A 20 "alsa_card.pci-0000_00_1f.3" | grep "Profiles:" || true
        echo ""
        echo "Current volume: $(pactl get-sink-volume @DEFAULT_SINK@ | awk '{print $5}' | tr -d '%')%"
        echo "Mute: $(pactl get-sink-mute @DEFAULT_SINK@ | awk '{print $2}')"
        ;;
        
    help)
        usage
        ;;
        
    *)
        echo "Error: Unknown command '$1'"
        usage
        ;;
esac