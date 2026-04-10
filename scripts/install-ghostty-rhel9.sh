#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Ghostty installer for RHEL 9.x
#
# Preferred method: snap install ghostty --classic
#   (bundles its own GNOME libs, avoids RHEL 9 library version issues)
#
# Fallback:  sudo bash install-ghostty.sh   (build from source)
#   Requires GLib >= 2.72, GTK4 >= 4.14, libadwaita >= 1.5
#   RHEL 9 ships older versions — build-from-source will fail.
# =============================================================================

GHOSTTY_VERSION="1.3.1"
ZIG_VERSION="0.15.2"
ZIG_ARCH="x86_64"
BUILD_DIR="/tmp/ghostty-build-$$"

# Minimum required library versions for build-from-source
MIN_GLIB="2.72"
MIN_GTK4="4.14"
MIN_LIBADWAITA="1.5"

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Proxy detection ---
# sudo strips environment variables by default. Source /etc/environment
# to restore proxy settings that the corporate network requires.
if [[ -z "${HTTP_PROXY:-}" && -f /etc/environment ]]; then
    info "Loading proxy settings from /etc/environment..."
    set -a  # auto-export all variables
    source /etc/environment
    set +a
fi

if [[ -n "${HTTP_PROXY:-}" ]]; then
    info "Proxy detected: ${HTTP_PROXY}"
else
    info "No proxy detected"
fi

# --- Preflight checks ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo bash install-ghostty.sh)"
fi

# --- Library version check ---
# Ghostty 1.3.1 requires newer GNOME stack libraries than RHEL 9 provides.
# Check upfront so we fail fast with clear guidance.
version_ge() {
    # Returns 0 if $1 >= $2 (using sort -V)
    [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0")
GTK4_VER=$(pkg-config --modversion gtk4 2>/dev/null || echo "0")
ADW_VER=$(pkg-config --modversion libadwaita-1 2>/dev/null || echo "0")

LIBS_OK=true
if ! version_ge "${GLIB_VER}" "${MIN_GLIB}"; then LIBS_OK=false; fi
if ! version_ge "${GTK4_VER}" "${MIN_GTK4}"; then LIBS_OK=false; fi
if ! version_ge "${ADW_VER}" "${MIN_LIBADWAITA}"; then LIBS_OK=false; fi

if [[ "${LIBS_OK}" != "true" ]]; then
    echo ""
    echo -e "${RED}  ┌────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${RED}  │ RHEL 9 library versions are too old for Ghostty ${GHOSTTY_VERSION}          │${NC}"
    echo -e "${RED}  │                                                                │${NC}"
    echo -e "${RED}  │  Required      Installed                                       │${NC}"
    printf  "${RED}  │  GLib %-8s  %-10s %s${NC}\n" "${MIN_GLIB}" "${GLIB_VER}" "$(version_ge "${GLIB_VER}" "${MIN_GLIB}" && echo '✓' || echo '✗')"
    printf  "${RED}  │  GTK4 %-8s  %-10s %s${NC}\n" "${MIN_GTK4}" "${GTK4_VER}" "$(version_ge "${GTK4_VER}" "${MIN_GTK4}" && echo '✓' || echo '✗')"
    printf  "${RED}  │  Adwaita %-5s  %-10s %s${NC}\n" "${MIN_LIBADWAITA}" "${ADW_VER}" "$(version_ge "${ADW_VER}" "${MIN_LIBADWAITA}" && echo '✓' || echo '✗')"
    echo -e "${RED}  │                                                                │${NC}"
    echo -e "${RED}  │ Install via Snap instead (bundles its own libraries):           │${NC}"
    echo -e "${RED}  │                                                                │${NC}"
    echo -e "${RED}  │   sudo snap install ghostty --classic                           │${NC}"
    echo -e "${RED}  │                                                                │${NC}"
    echo -e "${RED}  └────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    exit 1
fi

info "Ghostty ${GHOSTTY_VERSION} installer for RHEL 9.x"
info "Build directory: ${BUILD_DIR}"

# Use a fixed zig cache location so pre-fetch and build share the same cache,
# and retries don't lose previously fetched dependencies.
export ZIG_GLOBAL_CACHE_DIR="/tmp/ghostty-zig-cache"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}"
info "Zig cache: ${ZIG_GLOBAL_CACHE_DIR}"

# Clean up stale build dirs from previous failed runs (but not our cache)
for old_build in /tmp/ghostty-build-*; do
    [[ -d "$old_build" ]] && rm -rf "$old_build"
done
echo ""

# --- Step 1: Install build dependencies ---
info "Step 1/6: Installing build dependencies via dnf..."
dnf install -y \
    --disablerepo='github_git-lfs*' \
    gtk4-devel \
    libadwaita-devel \
    gettext \
    pkg-config \
    cmake \
    || error "Failed to install dependencies"

# gtk4-layer-shell-devel may not be in RHEL 9 repos — try but don't fail
if dnf list available gtk4-layer-shell-devel --disablerepo='github_git-lfs*' &>/dev/null; then
    info "Installing optional gtk4-layer-shell-devel..."
    dnf install -y --disablerepo='github_git-lfs*' gtk4-layer-shell-devel || true
else
    warn "gtk4-layer-shell-devel not available (optional, only needed for Wayland layer-shell support)"
fi

info "Dependencies installed."
echo ""

# --- Step 2: Install Zig ---
info "Step 2/6: Installing Zig ${ZIG_VERSION}..."
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

ZIG_TARBALL="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"

if command -v zig &>/dev/null && [[ "$(zig version)" == "${ZIG_VERSION}" ]]; then
    info "Zig ${ZIG_VERSION} is already installed, skipping."
else
    info "Downloading Zig from ${ZIG_URL}..."
    curl -fSL -o "${ZIG_TARBALL}" "${ZIG_URL}" \
        || error "Failed to download Zig"

    info "Extracting Zig..."
    tar -xf "${ZIG_TARBALL}"

    # Install to /usr/local
    rm -rf /usr/local/zig
    mv "zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /usr/local/zig

    # Symlink into PATH
    ln -sf /usr/local/zig/zig /usr/local/bin/zig

    info "Zig installed: $(/usr/local/bin/zig version)"
fi

# Ensure zig is on PATH for the rest of this script
export PATH="/usr/local/bin:${PATH}"
echo ""

# --- Step 3: Download Ghostty source ---
info "Step 3/6: Downloading Ghostty ${GHOSTTY_VERSION} source..."
cd "${BUILD_DIR}"

GHOSTTY_TARBALL="ghostty-${GHOSTTY_VERSION}.tar.gz"
GHOSTTY_URL="https://release.files.ghostty.org/${GHOSTTY_VERSION}/${GHOSTTY_TARBALL}"

info "Downloading from ${GHOSTTY_URL}..."
curl -fSL -o "${GHOSTTY_TARBALL}" "${GHOSTTY_URL}" \
    || error "Failed to download Ghostty source"

info "Extracting..."
tar -xf "${GHOSTTY_TARBALL}"
cd "ghostty-${GHOSTTY_VERSION}"
echo ""

# --- Step 4: Pre-fetch Zig dependencies via curl (proxy-compatible) ---
# Zig's built-in HTTP client has known issues with HTTPS proxies, causing
# ConnectionResetByPeer errors. We work around this by downloading all
# dependencies (including transitive ones) with curl (which handles proxies
# correctly) and then populating Zig's global cache with `zig fetch`.
# We loop multiple rounds to catch transitive deps that appear in the cache
# after each fetch.
info "Step 4/6: Pre-fetching Zig dependencies via curl (proxy workaround)..."

DEPS_DIR="${BUILD_DIR}/deps-download"
mkdir -p "${DEPS_DIR}"

ZIG_CACHE="${ZIG_GLOBAL_CACHE_DIR}/p"
FETCHED_URLS="${DEPS_DIR}/fetched.txt"
touch "${FETCHED_URLS}"

FETCH_FAILURES=0
TOTAL_FETCHED=0

fetch_url() {
    local url="$1"
    local download_url="$url"

    # Convert git+https:// URLs to archive tarball URLs
    # Works with GitHub, Codeberg (Gitea), GitLab, and other forges that serve
    # /archive/HASH.tar.gz — covers all git deps in Ghostty's build.zig.zon.
    if [[ "$url" == git+https://* ]]; then
        local repo_part="${url#git+https://}"
        local repo_path="${repo_part%%#*}"
        local commit_hash="${repo_part#*#}"
        download_url="https://${repo_path}/archive/${commit_hash}.tar.gz"
        info "  (git dep → tarball: ${commit_hash:0:12})"
    fi

    local dep_filename
    dep_filename=$(basename "${download_url}")

    info "  Downloading: ${dep_filename}"
    if curl -fSL -o "${DEPS_DIR}/${dep_filename}" "${download_url}"; then
        info "  Caching:     ${dep_filename}"
        if zig fetch "file://${DEPS_DIR}/${dep_filename}" >/dev/null 2>&1; then
            TOTAL_FETCHED=$((TOTAL_FETCHED + 1))
        else
            warn "  Cache failed: ${dep_filename}"
            FETCH_FAILURES=$((FETCH_FAILURES + 1))
        fi
    else
        warn "  Download failed: ${download_url}"
        FETCH_FAILURES=$((FETCH_FAILURES + 1))
    fi
}

for ROUND in $(seq 1 10); do
    info "Pre-fetch round ${ROUND}..."

    # Collect URLs from source tree AND zig cache (transitive deps)
    {
        grep -rh '\.url\s*=' --include='build.zig.zon' . 2>/dev/null || true
        if [[ -d "${ZIG_CACHE}" ]]; then
            grep -rh '\.url\s*=' --include='build.zig.zon' "${ZIG_CACHE}" 2>/dev/null || true
        fi
    } | grep -oP '"(https?://[^"]+|git\+https?://[^"]+)' \
      | tr -d '"' \
      | sort -u > "${DEPS_DIR}/all_urls.txt"

    # Filter out already-fetched URLs
    comm -23 <(sort "${DEPS_DIR}/all_urls.txt") <(sort "${FETCHED_URLS}") > "${DEPS_DIR}/new_urls.txt"

    NEW_COUNT=$(wc -l < "${DEPS_DIR}/new_urls.txt")
    if [[ ${NEW_COUNT} -eq 0 ]]; then
        info "No new dependencies found. Pre-fetch complete."
        break
    fi

    info "Found ${NEW_COUNT} new dependencies to fetch."

    while IFS= read -r dep_url; do
        fetch_url "${dep_url}"
        echo "${dep_url}" >> "${FETCHED_URLS}"
    done < "${DEPS_DIR}/new_urls.txt"

    sort -u -o "${FETCHED_URLS}" "${FETCHED_URLS}"
done

if [[ ${FETCH_FAILURES} -gt 0 ]]; then
    warn "${FETCH_FAILURES} dependencies failed to pre-fetch. Build may still succeed if they are optional."
else
    info "All ${TOTAL_FETCHED} dependencies pre-fetched and cached successfully."
fi
echo ""

# --- Step 5: Build Ghostty ---
info "Step 5/6: Building Ghostty (this may take a few minutes)..."

# -fno-sys=gtk4-layer-shell: not packaged on RHEL 9 (optional Wayland layer-shell feature)
BUILD_FLAGS="-Doptimize=ReleaseFast"
if ! rpm -q gtk4-layer-shell-devel &>/dev/null; then
    info "gtk4-layer-shell-devel not installed — building without layer-shell support"
    BUILD_FLAGS="${BUILD_FLAGS} -fno-sys=gtk4-layer-shell"
fi

zig build ${BUILD_FLAGS} \
    || error "Build failed"

info "Build succeeded!"
echo ""

# --- Step 6: Install system-wide ---
info "Step 6/6: Installing Ghostty system-wide to /usr/local..."
zig build -p /usr/local ${BUILD_FLAGS} \
    || error "Install failed"

# Update icon cache so GNOME picks up the icon
if command -v gtk-update-icon-cache &>/dev/null; then
    info "Updating GTK icon cache..."
    gtk-update-icon-cache -f /usr/local/share/icons/hicolor/ 2>/dev/null || true
fi

# Update desktop database so GNOME picks up the .desktop file
if command -v update-desktop-database &>/dev/null; then
    info "Updating desktop database..."
    update-desktop-database /usr/local/share/applications/ 2>/dev/null || true
fi

# Install terminfo entry
if [[ -d "zig-out/share/terminfo" ]]; then
    info "Installing terminfo entry..."
    mkdir -p /usr/local/share/terminfo
    cp -r zig-out/share/terminfo/* /usr/local/share/terminfo/ 2>/dev/null || true
fi

echo ""

# --- Cleanup ---
info "Cleaning up build directory..."
rm -rf "${BUILD_DIR}"

# --- SELinux file contexts ---
echo ""
info "Setting up SELinux file contexts..."

SELINUX_STATE=$(getenforce 2>/dev/null || echo "Disabled")
info "  Current SELinux state: ${SELINUX_STATE}"

# Apply correct file contexts regardless of current SELinux state.
# This ensures files are properly labeled when/if SELinux is enabled.
if command -v restorecon &>/dev/null; then
    # Binary — gets bin_t context under /usr/local/bin
    restorecon -v /usr/local/bin/ghostty 2>/dev/null || true

    # Desktop integration files
    restorecon -Rv /usr/local/share/applications/ 2>/dev/null || true
    restorecon -Rv /usr/local/share/dbus-1/ 2>/dev/null || true
    restorecon -Rv /usr/local/share/ghostty/ 2>/dev/null || true

    # systemd unit files
    if [[ -d /usr/local/lib/systemd ]]; then
        restorecon -Rv /usr/local/lib/systemd/ 2>/dev/null || true
    fi
    if [[ -d /usr/local/share/systemd ]]; then
        restorecon -Rv /usr/local/share/systemd/ 2>/dev/null || true
    fi

    # Terminfo
    if [[ -d /usr/local/share/terminfo ]]; then
        restorecon -Rv /usr/local/share/terminfo/ 2>/dev/null || true
    fi

    info "  ✓ SELinux file contexts applied"
else
    warn "  restorecon not found — SELinux contexts not set"
fi

# Verify the binary has correct SELinux label
if command -v ls &>/dev/null && [[ "${SELINUX_STATE}" != "Disabled" ]]; then
    BINARY_CONTEXT=$(ls -Z /usr/local/bin/ghostty 2>/dev/null | awk '{print $1}')
    info "  Binary SELinux context: ${BINARY_CONTEXT}"
fi

if [[ "${SELINUX_STATE}" == "Disabled" ]]; then
    echo ""
    echo -e "${YELLOW}  ┌────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}  │ SELinux is currently DISABLED.                                 │${NC}"
    echo -e "${YELLOW}  │                                                                │${NC}"
    echo -e "${YELLOW}  │ Ghostty is installed to standard paths (/usr/local) and will   │${NC}"
    echo -e "${YELLOW}  │ work correctly when SELinux is re-enabled. The binary gets      │${NC}"
    echo -e "${YELLOW}  │ bin_t context automatically under /usr/local/bin.               │${NC}"
    echo -e "${YELLOW}  │                                                                │${NC}"
    echo -e "${YELLOW}  │ To enable SELinux (do this in two stages):                     │${NC}"
    echo -e "${YELLOW}  │                                                                │${NC}"
    echo -e "${YELLOW}  │  Stage 1 — Permissive (log but don't block):                   │${NC}"
    echo -e "${YELLOW}  │    sudo sed -i 's/SELINUX=disabled/SELINUX=permissive/'  \\     │${NC}"
    echo -e "${YELLOW}  │         /etc/selinux/config                                    │${NC}"
    echo -e "${YELLOW}  │    sudo fixfiles -F onboot     # schedule full relabel         │${NC}"
    echo -e "${YELLOW}  │    sudo reboot                 # relabel + boot                │${NC}"
    echo -e "${YELLOW}  │                                                                │${NC}"
    echo -e "${YELLOW}  │  Stage 2 — Verify, then enforce:                               │${NC}"
    echo -e "${YELLOW}  │    getenforce                  # should say 'Permissive'       │${NC}"
    echo -e "${YELLOW}  │    ghostty                     # test it works                 │${NC}"
    echo -e "${YELLOW}  │    ausearch -m avc -ts recent  # check for denials             │${NC}"
    echo -e "${YELLOW}  │    sudo sed -i 's/SELINUX=permissive/SELINUX=enforcing/'  \\    │${NC}"
    echo -e "${YELLOW}  │         /etc/selinux/config                                    │${NC}"
    echo -e "${YELLOW}  │    sudo reboot                                                 │${NC}"
    echo -e "${YELLOW}  └────────────────────────────────────────────────────────────────┘${NC}"
fi

# --- systemd user service ---
echo ""
info "Configuring systemd user service..."
echo ""
echo "  The Ghostty systemd user service enables D-Bus activation for"
echo "  near-instant window creation (~20ms vs ~300ms cold start)."
echo ""
echo "  Run these commands AS YOUR REGULAR USER (not root):"
echo ""
echo "    systemctl --user daemon-reload"
echo "    systemctl enable --user app-com.mitchellh.ghostty.service"
echo ""
echo "  Then use 'ghostty +new-window' for fast window launch."
echo ""
echo "  Useful commands:"
echo "    systemctl status --user app-com.mitchellh.ghostty.service"
echo "    systemctl reload --user app-com.mitchellh.ghostty.service"
echo "    journalctl -a -f --user -u app-com.mitchellh.ghostty.service"
echo ""

# --- Done ---
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} ✓ Ghostty ${GHOSTTY_VERSION} installed successfully!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Binary:    $(command -v ghostty || echo '/usr/local/bin/ghostty')"
echo "  Version:   $(ghostty --version 2>/dev/null || echo 'run ghostty --version to check')"
echo "  Config:    ~/.config/ghostty/config"
echo ""
echo "  Ghostty should now appear in your GNOME Activities/Applications menu."
echo "  If the icon doesn't show immediately, log out and back in."
echo ""
echo "  Important: Avoid using the 'class' config parameter if using the"
echo "  systemd service — it can interfere with D-Bus activation."
echo ""
