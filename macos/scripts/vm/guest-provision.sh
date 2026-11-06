#!/bin/bash

set -euo pipefail

bundle_id=com.jischeng.omg.debug
app=/Applications/OMG.app
db="/Library/Application Support/com.apple.TCC/TCC.db"
sshd_clients=(/usr/libexec/sshd-keygen-wrapper /usr/libexec/sshd-session /usr/bin/osascript)
app_services=(kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent)

die() { printf 'provision: %s\n' "$*" >&2; exit 1; }

csrutil status | grep -q 'disabled' ||
    die "system integrity protection must be disabled in the guest"
[[ -d "$app" ]] || die "$app is not deployed; run deploy first"

requirement="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p')"
[[ -n "$requirement" ]] || die "$app has no designated requirement"
printf '%s\n' "$requirement" | csreq -r- -b /tmp/omg-provision.csreq
app_csreq="$(xxd -p /tmp/omg-provision.csreq | tr -d '\n')"
rm -f /tmp/omg-provision.csreq

sql() { sudo sqlite3 "$db" "$1"; }

grant() {
    local service="$1" client="$2" client_type="$3" csreq="$4" indirect="$5"
    local csreq_value=NULL
    [[ -z "$csreq" ]] || csreq_value="X'$csreq'"
    sql "delete from access where service='$service' and client='$client' and client_type=$client_type and indirect_object_identifier='$indirect'"
    sql "insert into access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, last_modified, indirect_object_identifier)
         values ('$service', '$client', $client_type, 2, 4, 1, $csreq_value, 0, cast(strftime('%s', 'now') as integer), '$indirect')"
}

for service in "${app_services[@]}"; do
    grant "$service" "$bundle_id" 0 "$app_csreq" UNUSED
done

for client in "${sshd_clients[@]}"; do
    for service in "${app_services[@]}"; do
        grant "$service" "$client" 1 "" UNUSED
    done
    grant kTCCServiceAppleEvents "$client" 1 "" com.apple.systemevents
done

# Screen recording also consults replayd's approval cache.
/usr/bin/python3 - "$bundle_id" <<'PY'
import datetime
import os
import plistlib
import subprocess
import sys

bundle_id = sys.argv[1]
path = os.path.expanduser(
    "~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
)
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path, "rb") as handle:
        approvals = plistlib.load(handle)
except Exception:
    approvals = {}

now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
for key in (
    "/Applications/OMG.app/Contents/MacOS/omg",
    bundle_id,
    "/usr/libexec/sshd-keygen-wrapper",
    "/usr/libexec/sshd-session",
):
    entry = approvals.setdefault(key, {})
    entry.update(
        {
            "kScreenCaptureApprovalLastAlerted": now,
            "kScreenCaptureApprovalLastUsed": now,
            "kScreenCapturePrivacyHintDate": datetime.datetime(2099, 1, 1),
            "kScreenCapturePrivacyHintPolicy": 2592000,
        }
    )
    entry.setdefault("kScreenCaptureAlertableUsageCount", 1)

with open(path, "wb") as handle:
    plistlib.dump(approvals, handle)
subprocess.run(["killall", "replayd"], stderr=subprocess.DEVNULL)
PY

sql "select service, client, auth_value from access where client='$bundle_id'"
echo "provisioned accessibility, screen capture and automation for $bundle_id"
