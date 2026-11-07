#!/bin/bash

set -euo pipefail

OMG_VM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMG_VM_REPO_ROOT="$(cd "$OMG_VM_SCRIPT_DIR/../../.." && pwd)"

OMG_VM_NAME="${OMG_VM_NAME:-omg-test}"
OMG_VM_USER="${OMG_VM_USER:-admin}"
OMG_VM_STATE="${OMG_VM_STATE:-$HOME/.local/share/omg-vm}"
OMG_VM_KEY="$OMG_VM_STATE/id_ed25519"
OMG_VM_LOG="$OMG_VM_STATE/$OMG_VM_NAME.tart.log"
OMG_VM_APP="${OMG_VM_APP:-$OMG_VM_REPO_ROOT/macos/build/Debug/OMG.app}"
OMG_VM_BUNDLE_ID="com.jischeng.omg.debug"
OMG_VM_LABEL="com.jischeng.omgvm.$(printf '%s' "$OMG_VM_NAME" | tr -c 'A-Za-z0-9._-' '_')"

OMG_TART="${OMG_TART:-$(command -v tart 2>/dev/null || true)}"
if [[ -z "$OMG_TART" && -x /opt/homebrew/bin/tart ]]; then
    OMG_TART=/opt/homebrew/bin/tart
fi

omg_vm_die() {
    printf 'OMG VM: %s\n' "$*" >&2
    exit 1
}

[[ -n "$OMG_TART" && -x "$OMG_TART" ]] || omg_vm_die "tart was not found"
[[ "$OMG_VM_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || omg_vm_die "invalid VM name: $OMG_VM_NAME"

mkdir -p "$OMG_VM_STATE"
chmod 700 "$OMG_VM_STATE"

OMG_VM_SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o IdentitiesOnly=yes
    -o LogLevel=ERROR
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -i "$OMG_VM_KEY"
)

omg_vm_state() {
    "$OMG_TART" get "$OMG_VM_NAME" 2>/dev/null | awk 'NR == 2 { print $NF }'
}

omg_vm_log_lines() {
    [[ -f "$OMG_VM_LOG" ]] || { echo 0; return; }
    wc -l <"$OMG_VM_LOG" | tr -d ' '
}

# Tart keeps its `run` process alive after a guest-initiated halt, so the VM
# only reports `stopped` once that runner is gone.
omg_vm_guest_halted_since() {
    local offset="${1:-0}"
    [[ -f "$OMG_VM_LOG" ]] || return 1
    tail -n +"$((offset + 1))" "$OMG_VM_LOG" 2>/dev/null |
        grep -q 'guest has stopped the virtual machine'
}

omg_vm_runner_pid() {
    ps -axo pid=,command= |
        awk -v vm="$OMG_VM_NAME" '$NF == vm && /(^|\/)tart run( |$)/ { print $1; exit }'
}

omg_vm_ip() {
    "$OMG_TART" ip "$OMG_VM_NAME" --wait "${1:-10}"
}

omg_vm_ssh() {
    local ip
    ip="$(omg_vm_ip)"
    ssh "${OMG_VM_SSH_OPTS[@]}" "$OMG_VM_USER@$ip" "$@"
}

omg_vm_scp_from() {
    local ip="$1" guest_path="$2" host_path="$3"
    scp "${OMG_VM_SSH_OPTS[@]}" "$OMG_VM_USER@$ip:$guest_path" "$host_path"
}

omg_vm_scp_to() {
    local ip="$1" host_path="$2" guest_path="$3"
    scp "${OMG_VM_SSH_OPTS[@]}" "$host_path" "$OMG_VM_USER@$ip:$guest_path"
}

omg_vm_gui() {
    local remote_command
    printf -v remote_command '%q ' "$@"
    omg_vm_ssh "sudo -n launchctl asuser \$(id -u '$OMG_VM_USER') sudo -n -u '$OMG_VM_USER' $remote_command"
}

omg_vm_require_running() {
    [[ "$(omg_vm_state)" == running ]] || omg_vm_die "VM '$OMG_VM_NAME' is not running; use up first"
}

omg_vm_require_debug_app() {
    [[ -d "$OMG_VM_APP" ]] || omg_vm_die "Debug app not found: $OMG_VM_APP"
    local bundle_id
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OMG_VM_APP/Contents/Info.plist")
    [[ "$bundle_id" == "$OMG_VM_BUNDLE_ID" ]] ||
        omg_vm_die "refusing to deploy bundle '$bundle_id'; expected $OMG_VM_BUNDLE_ID"
}

omg_vm_install_ssh_key() {
    [[ -f "$OMG_VM_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C omg-vm -f "$OMG_VM_KEY"
    chmod 600 "$OMG_VM_KEY"

    local public_key guest_command
    public_key="$(cat "$OMG_VM_KEY.pub")"
    guest_command="mkdir -p ~/.ssh &&
chmod 700 ~/.ssh &&
touch ~/.ssh/authorized_keys &&
(grep -qxF '$public_key' ~/.ssh/authorized_keys || printf '%s\\n' '$public_key' >> ~/.ssh/authorized_keys) &&
chmod 600 ~/.ssh/authorized_keys"
    "$OMG_TART" exec "$OMG_VM_NAME" /bin/sh -c "$guest_command"
}

omg_vm_wait_for_ssh() {
    local attempt
    for attempt in $(seq 1 60); do
        if omg_vm_ssh true 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    omg_vm_die "SSH did not become ready; see $OMG_VM_LOG"
}

omg_vm_wait_for_gui() {
    local attempt
    for attempt in $(seq 1 60); do
        if omg_vm_ssh "pgrep -qx Dock -U \$(id -u '$OMG_VM_USER')" 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    omg_vm_die "guest Aqua session did not become ready; auto-login is required"
}
