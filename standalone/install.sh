#!/usr/bin/env bash
# Standalone installer for tvpc-cameras-gui on Omarchy / Hyprland / Arch.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dontneedtogotit/tvpc/main/standalone/install.sh | bash
# Or run from a local checkout:
#   cd tvpc && bash standalone/install.sh
set -euo pipefail

APP_NAME="tvpc-cameras-gui"
INSTALL_DIR="${HOME}/.local/share/${APP_NAME}"
BIN_DIR="${HOME}/.local/bin"
DESKTOP_DIR="${HOME}/.local/share/applications"
HYPR_DIR="${HOME}/.config/hypr"
CONF_DIR="${HOME}/.config/tvpc"
PIP_REQ="${INSTALL_DIR}/requirements.txt"

# Colors.
if [ -t 1 ]; then
    BOLD='\033[1m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    RESET='\033[0m'
else
    BOLD=''
    GREEN=''
    YELLOW=''
    RED=''
    RESET=''
fi

info() { echo -e "${GREEN}${BOLD}[INFO]${RESET} $*"; }
warn() { echo -e "${YELLOW}${BOLD}[WARN]${RESET} $*"; }
err() { echo -e "${RED}${BOLD}[ERROR]${RESET} $*"; }

# Find the repo root: the directory containing this script's parent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# If the repo isn't there, try to clone it.
if [ ! -d "${REPO_DIR}/.git" ] && [ ! -f "${REPO_DIR}/tvpc_cameras_gui/__main__.py" ]; then
    warn "tvpc repo not found next to this script. Attempting to clone..."
    TMP_DIR="$(mktemp -d)"
    if ! git clone --depth=1 https://github.com/dontneedtogotit/tvpc.git "${TMP_DIR}/tvpc" 2>/dev/null; then
        err "Could not clone tvpc repo. Please install from a local checkout."
        exit 1
    fi
    REPO_DIR="${TMP_DIR}/tvpc"
fi

info "Installing ${APP_NAME} to ${INSTALL_DIR}"

# Create directories.
mkdir -p "${INSTALL_DIR}" "${BIN_DIR}" "${DESKTOP_DIR}" "${CONF_DIR}" "${HYPR_DIR}"

# Copy the Python package.
rsync -a --delete \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.pytest_cache' \
    --exclude='tests' \
    --exclude='.venv' \
    --exclude='venv' \
    --exclude='*.egg-info' \
    --exclude='dist' \
    --exclude='build' \
    "${REPO_DIR}/tvpc_cameras_gui/" "${INSTALL_DIR}/tvpc_cameras_gui/"

# Create a wrapper script.
cat > "${BIN_DIR}/${APP_NAME}" << 'EOF'
#!/usr/bin/env bash
# Launcher for tvpc-cameras-gui standalone install.
set -euo pipefail
APP_DIR="${HOME}/.local/share/tvpc-cameras-gui"
# Prefer the bundled venv; fall back to system python.
if [ -x "${APP_DIR}/.venv/bin/python" ]; then
    exec "${APP_DIR}/.venv/bin/python" -m tvpc_cameras_gui "$@"
fi
PYTHON="$(command -v python3 || command -v python)"
if [ -z "${PYTHON}" ]; then
    echo "Python not found. Please install python3." >&2
    exit 1
fi
exec "${PYTHON}" -m tvpc_cameras_gui "$@"
EOF
chmod +x "${BIN_DIR}/${APP_NAME}"

# Install desktop entry.
install -m 0644 "${SCRIPT_DIR}/tvpc-cameras-gui.desktop" "${DESKTOP_DIR}/tvpc-cameras-gui.desktop"

# Hyprland window rules for a nice first-run experience.
cat > "${HYPR_DIR}/tvpc-cameras-gui.conf" << 'EOF'
# tvpc-cameras-gui window rules
windowrule = float, class:^(tvpc-cameras-gui)$
windowrule = size 1280 760, class:^(tvpc-cameras-gui)$
windowrule = center, class:^(tvpc-cameras-gui)$
# Keep it on the same workspace as the launcher when opened.
windowrule = workspace 0, class:^(tvpc-cameras-gui)$
EOF

# Offer to source the Hyprland rules if not already present.
HYPRIAN_CONF="${HYPR_DIR}/hyprland.conf"
if [ -f "${HYPRIAN_CONF}" ]; then
    if ! grep -q "tvpc-cameras-gui.conf" "${HYPRIAN_CONF}"; then
        info "Adding tvpc-cameras-gui window rules to hyprland.conf"
        echo '' >> "${HYPRIAN_CONF}"
        echo '# tvpc-cameras-gui window rules' >> "${HYPRIAN_CONF}"
        echo 'source = ~/.config/hypr/tvpc-cameras-gui.conf' >> "${HYPRIAN_CONF}"
    fi
else
    warn "No hyprland.conf found at ${HYPRIAN_CONF}. Create one or copy the standalone/tvpc-cameras-gui.conf rules into your Hyprland config."
fi

# Set up Python venv and install dependencies.
info "Setting up Python virtual environment..."
cd "${INSTALL_DIR}"
if [ ! -d ".venv" ]; then
    if ! python3 -m venv .venv; then
        warn "Could not create venv. Will try to use system python."
    fi
else
    info "Reusing existing venv at ${INSTALL_DIR}/.venv"
fi

if [ -x "${INSTALL_DIR}/.venv/bin/python" ]; then
    info "Installing Python dependencies into venv..."
    "${INSTALL_DIR}/.venv/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
    "${INSTALL_DIR}/.venv/bin/pip" install PySide6 requests >/dev/null
fi

# Install system packages hint.
info "Checking system dependencies (ffmpeg, mpv)..."
MISSING_PKGS=()
if ! command -v ffmpeg >/dev/null 2>&1; then
    MISSING_PKGS+=("ffmpeg")
fi
if ! command -v mpv >/dev/null 2>&1; then
    MISSING_PKGS+=("mpv")
fi

if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    warn "Missing system packages: ${MISSING_PKGS[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        if [ "$(id -u)" -ne 0 ]; then
            warn "Run this to finish system deps:"
            echo "  sudo apt-get install -y ${MISSING_PKGS[*]}"
        else
            apt-get update -qq
            apt-get install -y -qq "${MISSING_PKGS[@]}" >/dev/null
        fi
    elif command -v pacman >/dev/null 2>&1; then
        if [ "$(id -u)" -ne 0 ]; then
            warn "Run this to finish system deps:"
            echo "  sudo pacman -S --noconfirm ${MISSING_PKGS[*]}"
        else
            pacman -S --noconfirm --quiet "${MISSING_PKGS[@]}" >/dev/null
        fi
    elif command -v dnf >/dev/null 2>&1; then
        if [ "$(id -u)" -ne 0 ]; then
            warn "Run this to finish system deps:"
            echo "  sudo dnf install -y ${MISSING_PKGS[*]}"
        else
            dnf install -y -q "${MISSING_PKGS[@]}" >/dev/null
        fi
    else
        warn "Unknown package manager. Please install ${MISSING_PKGS[*]} manually."
    fi
else
    info "System dependencies (ffmpeg, mpv) already present."
fi

# Create a desktop icon cache update trigger.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${DESKTOP_DIR}" 2>/dev/null || true
fi

echo ""
info "${BOLD}Installation complete!${RESET}"
echo ""
echo "  Launch from:"
echo "    • App launcher (search for \"tvpc Cameras\")"
echo "    • Terminal:   tvpc-cameras-gui"
echo ""
echo "  Config lives in:   ${CONF_DIR}/cameras.conf"
echo "  App data lives in: ${INSTALL_DIR}"
echo ""
echo "  To update later, re-run this script."
echo ""

