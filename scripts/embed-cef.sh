#!/bin/bash
# embed-cef.sh — Called from Xcode "Run Script" build phase (post-link).
# Copies CEF framework, compiles helper processes, creates .app bundles,
# and ad-hoc codesigns everything inside the app bundle.
#
# Safe to run when CEF is not downloaded — exits cleanly (stub mode).

set -euo pipefail

# --- Configuration -----------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF_DIR="${REPO_ROOT}/vendor/cef"
HELPER_SRC="${REPO_ROOT}/macos/Helpers/CEF/GhosttiesHelper.cc"
HELPER_PLIST_TEMPLATE="${REPO_ROOT}/macos/Resources/CEF/helper-Info.plist"
HELPER_ENTITLEMENTS="${REPO_ROOT}/macos/GhosttiesHelper.entitlements"

# Xcode sets these during build; fall back to sensible defaults for manual runs.
BUILT_PRODUCTS_DIR="${BUILT_PRODUCTS_DIR:-${REPO_ROOT}/macos/build/Build/Products/Debug}"
PRODUCT_NAME="${PRODUCT_NAME:-Ghostties}"

APP_BUNDLE="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app"
FRAMEWORKS_DIR="${APP_BUNDLE}/Contents/Frameworks"

CEF_FRAMEWORK_SRC="${CEF_DIR}/Release/Chromium Embedded Framework.framework"
CEF_FRAMEWORK_DST="${FRAMEWORKS_DIR}/Chromium Embedded Framework.framework"

# --- Guard: skip if CEF not downloaded ---------------------------------------

if [ ! -d "${CEF_FRAMEWORK_SRC}" ]; then
    echo "note: CEF framework not found — skipping (stub mode)"
    exit 0
fi

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "error: App bundle not found at ${APP_BUNDLE}"
    exit 1
fi

echo "=== embed-cef.sh: Embedding CEF into ${PRODUCT_NAME}.app ==="

# --- Step 1: Copy CEF framework ---------------------------------------------

mkdir -p "${FRAMEWORKS_DIR}"

# CEF distributes a flat framework, but macOS expects a versioned bundle:
#   Versions/A/            — actual content
#   Versions/Current       — symlink to A
#   Resources, Libraries   — symlinks to Versions/Current/Resources, etc.
#   Chromium Embedded Framework — symlink to Versions/Current/...

rm -rf "${CEF_FRAMEWORK_DST}"
mkdir -p "${CEF_FRAMEWORK_DST}/Versions/A"

# Copy content into Versions/A/
rsync -a "${CEF_FRAMEWORK_SRC}/Resources" "${CEF_FRAMEWORK_DST}/Versions/A/"
rsync -a "${CEF_FRAMEWORK_SRC}/Libraries" "${CEF_FRAMEWORK_DST}/Versions/A/"
cp "${CEF_FRAMEWORK_SRC}/Chromium Embedded Framework" \
   "${CEF_FRAMEWORK_DST}/Versions/A/Chromium Embedded Framework"

# Create versioned symlinks.
ln -sf A "${CEF_FRAMEWORK_DST}/Versions/Current"
ln -sf Versions/Current/Resources "${CEF_FRAMEWORK_DST}/Resources"
ln -sf Versions/Current/Libraries "${CEF_FRAMEWORK_DST}/Libraries"
ln -sf "Versions/Current/Chromium Embedded Framework" \
   "${CEF_FRAMEWORK_DST}/Chromium Embedded Framework"

xattr -dr com.apple.quarantine "${CEF_FRAMEWORK_DST}" 2>/dev/null || true

echo "  [1/4] Framework copied (versioned bundle)"

# --- Step 2: Compile helper executable ---------------------------------------

HELPER_OBJ_DIR="${BUILT_PRODUCTS_DIR}/cef-helper-obj"
mkdir -p "${HELPER_OBJ_DIR}"

HELPER_BINARY="${HELPER_OBJ_DIR}/GhosttiesHelper"

WRAPPER_LIB="${REPO_ROOT}/vendor/cef-build/libcef_dll_wrapper.a"

if [ "${HELPER_SRC}" -nt "${HELPER_BINARY}" ] || \
   [ "${WRAPPER_LIB}" -nt "${HELPER_BINARY}" ]; then

    clang++ -std=c++20 -arch arm64 -O2 \
        -mmacosx-version-min=13.0 \
        -I"${CEF_DIR}" \
        -DWRAPPING_CEF_SHARED \
        -framework Cocoa \
        -L"${REPO_ROOT}/vendor/cef-build" \
        -lcef_dll_wrapper \
        -o "${HELPER_BINARY}" \
        "${HELPER_SRC}" \
        "${CEF_DIR}/libcef_dll/wrapper/cef_scoped_library_loader_mac.mm"

    echo "  [2/4] Helper compiled (with C++ wrapper)"
else
    echo "  [2/4] Helper up to date"
fi

# --- Step 3: Create helper .app bundles --------------------------------------

HELPER_VARIANTS=(
    "|"
    " (Alerts)|.alerts"
    " (GPU)|.gpu"
    " (Plugin)|.plugin"
    " (Renderer)|.renderer"
)

for variant in "${HELPER_VARIANTS[@]}"; do
    IFS='|' read -r display_suffix bundle_suffix <<< "${variant}"

    helper_name="Ghostties Helper${display_suffix}"
    helper_app="${FRAMEWORKS_DIR}/${helper_name}.app"
    helper_macos="${helper_app}/Contents/MacOS"

    mkdir -p "${helper_macos}"

    cp "${HELPER_BINARY}" "${helper_macos}/${helper_name}"

    sed \
        -e "s|__EXECUTABLE_NAME__|${helper_name}|g" \
        -e "s|__BUNDLE_ID_SUFFIX__|${bundle_suffix}|g" \
        "${HELPER_PLIST_TEMPLATE}" > "${helper_app}/Contents/Info.plist"
done

echo "  [3/4] Helper bundles created (${#HELPER_VARIANTS[@]} variants)"

# --- Step 4: Codesign everything ---------------------------------------------

for variant in "${HELPER_VARIANTS[@]}"; do
    IFS='|' read -r display_suffix bundle_suffix <<< "${variant}"
    helper_name="Ghostties Helper${display_suffix}"
    helper_app="${FRAMEWORKS_DIR}/${helper_name}.app"

    codesign --force --sign - \
        --entitlements "${HELPER_ENTITLEMENTS}" \
        "${helper_app}" 2>/dev/null
done

codesign --force --sign - \
    "${CEF_FRAMEWORK_DST}" 2>/dev/null

echo "  [4/4] Codesigned"
echo "=== embed-cef.sh: Done ==="
