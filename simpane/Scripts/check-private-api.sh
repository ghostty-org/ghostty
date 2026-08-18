#!/bin/bash
#
# Ground rule 4, made checkable: one shim owns all private API.
#
# Nothing outside Private/PrivateSim.swift may name a private class, resolve a
# selector by string, dlopen a framework, or use the ObjC dispatch glue. The
# facade types that file vends (SimDisplay, IndigoHIDClient, SimDeviceHandle,
# PrivateFrameworks) are ordinary Swift and may be used freely — that is the
# point of a facade.
#
# Run from the simpane directory. Exits non-zero on a violation.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SHIM="Sources/SimPaneKit/Private/PrivateSim.swift"

# Ways to reach a private framework without naming it in Swift source.
PATTERNS='NSClassFromString|NSSelectorFromString|objc_msgSend|dlopen|dlsym|SPObjC|SimServiceContext|SimulatorKit\.|/PrivateFrameworks/'

status=0

check() {
    local label="$1"; shift
    local hits
    hits=$(grep -rnE --include='*.swift' "$PATTERNS" "$@" 2>/dev/null | grep -v "^$SHIM:")
    if [ -n "$hits" ]; then
        echo "FAIL: private API outside the shim in $label"
        echo "$hits"
        status=1
    else
        echo "ok: $label reaches private API only through $SHIM"
    fi
}

check "SimPaneKit" Sources/SimPaneKit
check "SimPanePOC" Sources/SimPanePOC

# SimDump is deliberately not checked: dumping the live private-API surface is
# the entire job of that target. It ships nothing and Ghostty never links it.

# The shim must actually still be the thing doing the work; an empty file would
# pass every check above.
if ! grep -q 'NSClassFromString' "$SHIM"; then
    echo "FAIL: $SHIM no longer resolves any private class — has the shim moved?"
    status=1
fi

exit $status
