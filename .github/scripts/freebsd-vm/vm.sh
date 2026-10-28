#!/bin/sh
# vm.sh runs the libghostty-vt tests on FreeBSD, inside a virtual machine (VM)
# on your own computer.
#
# A container cannot run FreeBSD, because containers share the host's kernel.
# This script uses QEMU to run a real FreeBSD system instead. You build the
# tests on your computer for FreeBSD, and the script copies them into the VM
# and runs them there.
#
# Usage: vm.sh COMMAND [ARGS]
#
# Commands:
#
#   setup         Prepare the VM. Run this once. See "Setting up" below.
#   start         Boot the VM in the background and wait until ssh works.
#   test [TESTS]  Copy the repository and the test binaries in the directory
#                 TESTS into the VM, then run them. TESTS defaults to
#                 zig-out/bin.
#   stop          Shut the VM down.
#   reset         Undo every change made to the VM's disk since setup. The VM
#                 must be stopped first.
#   ssh [CMD]     Open a shell in the VM, or run CMD there.
#   status        Print whether the VM is running.
#   help          Print this text.
#
# Example
#
# Build the tests for FreeBSD, then set up the VM, start it, run the tests,
# and stop it. The VM is arm64 unless you choose otherwise, so the build
# targets aarch64-freebsd:
#
#     zig build test-lib-vt-build -Demit-lib-vt -Demit-test-exe \
#       -Dtarget=aarch64-freebsd
#     .github/scripts/freebsd-vm/vm.sh setup
#     .github/scripts/freebsd-vm/vm.sh start
#     .github/scripts/freebsd-vm/vm.sh test
#     .github/scripts/freebsd-vm/vm.sh stop
#
# -Demit-test-exe makes the build install the test binary in zig-out/bin as
# ghostty-vt-c-test, which is where test looks for it. That binary is built
# from the C API and runs every libghostty-vt test, the Zig ones included.
#
# -Dtest-filter works here as it does for zig build test-lib-vt. Use it to
# build and run only the tests you are working on:
#
#     zig build test-lib-vt-build -Demit-lib-vt -Demit-test-exe \
#       -Dtarget=aarch64-freebsd -Dtest-filter=decommit
#     .github/scripts/freebsd-vm/vm.sh test
#
# The VM keeps running until stop, so you can rebuild and run test as many
# times as you like in between. Some tests read files from the repository
# while they run, so test also copies the repository into the VM and runs
# the binary from its top directory. The copy leaves out version control,
# build output, and the macOS app, which keeps it to about 85 MB.
#
# Setting up
#
# setup downloads the FreeBSD VM image and checks it against the checksums
# FreeBSD publishes beside it. It then boots the VM once. On that first boot,
# FreeBSD creates a user named ghostty, who can log in with an ssh key that
# setup made and can use sudo without a password. It also installs rsync and
# sudo. setup then shuts the VM down and saves its disk as a snapshot named
# "ready", which reset returns to. Running setup again does nothing once the
# snapshot exists.
#
# Everything setup creates is kept in one directory per release and
# architecture, never in the repository. It needs about 5 GB. To start over,
# delete that directory. The compressed download in its dl/ directory can stay,
# so the next setup does not download it again.
#
# Inside the VM, the repository is in ~/ghostty and the test binaries are in
# ~/tests, as the last test left them:
#
#     .github/scripts/freebsd-vm/vm.sh ssh 'freebsd-version; ls ~/tests'
#
# Requirements
#
# The script needs QEMU, curl, xz, ssh, and rsync. It uses the QEMU on your
# PATH, which nix develop provides on Linux. Otherwise it builds QEMU from
# the nixpkgs version pinned in flake.lock, which needs no setup.
#
# setup also writes a small disk image of first-boot settings for the VM.
# On macOS it uses the built-in hdiutil. On Linux it uses xorriso, from your
# PATH or else from the same pinned nixpkgs.
#
# Speed
#
# The VM runs at close to native speed when it has the same architecture as
# your computer: arm64 on an Apple Silicon Mac, or amd64 on an x86-64 Linux
# machine with KVM (/dev/kvm writable). Any other combination is emulated in
# software, which works but is many times slower.
#
# Other releases and architectures
#
# Environment variables choose the VM. Each release and architecture is its
# own VM with its own disk, and the arm64 and amd64 VMs use different ports
# by default, so they can run at the same time. For example, to test on
# amd64, build for x86_64-freebsd and set GHOSTTY_FREEBSD_VM_ARCH:
#
#     zig build test-lib-vt-build -Demit-lib-vt -Demit-test-exe \
#       -Dtarget=x86_64-freebsd
#     export GHOSTTY_FREEBSD_VM_ARCH=amd64
#     .github/scripts/freebsd-vm/vm.sh setup
#     .github/scripts/freebsd-vm/vm.sh start
#     .github/scripts/freebsd-vm/vm.sh test
#
# To run another release beside the default one, give it its own port too.
# The same test binary works on every supported release:
#
#     export GHOSTTY_FREEBSD_VM_RELEASE=14.5 GHOSTTY_FREEBSD_VM_SSH_PORT=2234
#
# Settings
#
# All of these are optional.
#
#   GHOSTTY_FREEBSD_VM_ARCH      arm64 or amd64. The default is arm64.
#   GHOSTTY_FREEBSD_VM_RELEASE   The FreeBSD release to run. The default is
#                                15.1.
#   GHOSTTY_FREEBSD_VM_DIR       Where downloads and VM disks are kept. The
#                                default is $HOME/.cache/ghostty-freebsd-vm.
#                                Each VM gets a directory inside it named
#                                after its release and architecture, such as
#                                15.1-arm64. The VM's console output is in
#                                console.log there, which shows where a boot
#                                went wrong.
#   GHOSTTY_FREEBSD_VM_SSH_PORT  The port on 127.0.0.1 that reaches the VM's
#                                ssh server. The default is 2232 for arm64 and
#                                2233 for amd64, so one of each can run at the
#                                same time.
#   GHOSTTY_FREEBSD_VM_CPUS      CPUs for the VM. The default is 4.
#   GHOSTTY_FREEBSD_VM_MEMORY    Memory for the VM in MiB. The default is 4096.
#   GHOSTTY_FREEBSD_VM_TIMEOUT   Seconds start waits for ssh. The default is
#                                1200.
#   GHOSTTY_FREEBSD_VM_TEST_TIMEOUT
#                                Seconds each test binary may run before it
#                                is stopped and fails. The default is 1800.
#   GHOSTTY_FREEBSD_VM_QEMU      A QEMU installation directory, the one holding
#                                bin/ and share/qemu/. The default is the QEMU
#                                on PATH, or else the one from the repository's
#                                pinned nixpkgs.
#
# In CI
#
# The test-lib-vt-freebsd job in .github/workflows/test.yml runs the same
# commands as the example above, in an amd64 VM. It keeps the VM's directory
# on the runner's cache volume, so only the first run downloads FreeBSD. Each
# run calls reset before start, so files left by one run never reach the next.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)

arch=${GHOSTTY_FREEBSD_VM_ARCH:-arm64}
release=${GHOSTTY_FREEBSD_VM_RELEASE:-15.1}
case $arch in
arm64)
	# FreeBSD names its arm64 images after the platform and the processor,
	# but their download directory after the processor alone.
	image_dir=aarch64
	image_arch=arm64-aarch64
	default_port=2232
	;;
amd64)
	image_dir=amd64
	image_arch=amd64
	default_port=2233
	;;
*)
	echo "vm.sh: GHOSTTY_FREEBSD_VM_ARCH must be arm64 or amd64, not $arch" >&2
	exit 2
	;;
esac
port=${GHOSTTY_FREEBSD_VM_SSH_PORT:-$default_port}
cpus=${GHOSTTY_FREEBSD_VM_CPUS:-4}
memory=${GHOSTTY_FREEBSD_VM_MEMORY:-4096}
timeout=${GHOSTTY_FREEBSD_VM_TIMEOUT:-1200}
test_timeout=${GHOSTTY_FREEBSD_VM_TEST_TIMEOUT:-1800}

state=${GHOSTTY_FREEBSD_VM_DIR:-$HOME/.cache/ghostty-freebsd-vm}/$release-$arch
image=FreeBSD-$release-RELEASE-$image_arch-BASIC-CLOUDINIT-ufs.qcow2
url=https://download.freebsd.org/releases/VM-IMAGES/$release-RELEASE/$image_dir/Latest
disk=$state/disk.qcow2
key=$state/id_ed25519
pidfile=$state/qemu.pid
console=$state/console.log

# The VM is reachable only from this machine, and it gets a new host key every
# time setup runs. Checking host keys would only produce mismatch errors.
#
# IdentitiesOnly keeps ssh from offering the keys in your ssh agent before the
# VM's own key. sshd allows six attempts, so with six keys loaded in the agent,
# the VM's key would never be tried.
#
# Separate the options with single spaces, never a line break or a tab. rsync
# splits its -e command on spaces only.
ssh_opts="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ssh_opts="$ssh_opts -o IdentitiesOnly=yes -o LogLevel=ERROR -o ConnectTimeout=5 -i $key -p $port"

usage() {
	sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

log() {
	echo "vm.sh: $*" >&2
}

die() {
	log "$*"
	exit 1
}

guest_ssh() {
	# ssh hands its arguments to the guest's shell, so callers quote a
	# command for that shell, not for this one.
	# shellcheck disable=SC2086,SC2029 # ssh_opts is a list of words.
	ssh $ssh_opts ghostty@127.0.0.1 "$@"
}

running() {
	[ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

# find_qemu sets qemu to the emulator for the VM's architecture, and firmware
# to the UEFI firmware it boots.
find_qemu() {
	case $arch in
	arm64) bin=qemu-system-aarch64 fw=edk2-aarch64-code.fd ;;
	amd64) bin=qemu-system-x86_64 fw=edk2-x86_64-code.fd ;;
	esac
	if [ -n "${GHOSTTY_FREEBSD_VM_QEMU:-}" ]; then
		prefix=$GHOSTTY_FREEBSD_VM_QEMU
	elif command -v "$bin" >/dev/null 2>&1; then
		prefix=$(cd "$(dirname "$(command -v "$bin")")/.." && pwd)
	elif command -v nix >/dev/null 2>&1; then
		# --inputs-from takes nixpkgs from the repository's flake.lock, so
		# everyone gets the same QEMU. On macOS, that build is signed with
		# the entitlement that hardware virtualization requires.
		log "using QEMU from the repository's nixpkgs"
		prefix=$(nix build --inputs-from "$repo" nixpkgs#qemu --no-link --print-out-paths |
			head -n 1)
	else
		die "cannot find $bin. Install QEMU or set GHOSTTY_FREEBSD_VM_QEMU."
	fi
	qemu=$prefix/bin/$bin
	qemu_img=$prefix/bin/qemu-img
	firmware=$prefix/share/qemu/$fw
	[ -x "$qemu" ] || die "$qemu is not executable"
	[ -f "$firmware" ] || die "$firmware is missing"
}

# accel prints the QEMU accelerator to use. hvf and kvm are the hardware
# virtualization of macOS and Linux, and work only when the VM has the host's
# architecture. tcg emulates the processor in software and works everywhere.
accel() {
	case $arch:$(uname -m) in
	arm64:arm64 | arm64:aarch64 | amd64:x86_64) native=1 ;;
	*) native= ;;
	esac
	if [ -n "$native" ] && [ "$(uname -s)" = Darwin ]; then
		echo hvf
	elif [ -n "$native" ] && [ -w /dev/kvm ]; then
		echo kvm
	else
		echo tcg
	fi
}

fetch_image() {
	[ -f "$disk" ] && return
	mkdir -p "$state/dl"
	# Keep the compressed image, so that deleting disk.qcow2 to start over
	# does not download 600 MB again.
	if [ ! -f "$state/dl/$image.xz" ]; then
		log "downloading $url/$image.xz"
		curl -fL --progress-bar -o "$state/dl/$image.xz.part" "$url/$image.xz"
		mv "$state/dl/$image.xz.part" "$state/dl/$image.xz"
	fi
	curl -fsSL -o "$state/dl/CHECKSUM.SHA256" "$url/CHECKSUM.SHA256"
	# Each line of the checksum file reads "SHA256 (file name) = digest".
	want=$(sed -n "s/^SHA256 ($image.xz) = //p" "$state/dl/CHECKSUM.SHA256")
	[ -n "$want" ] || die "$url/CHECKSUM.SHA256 does not list $image.xz"
	# macOS has only shasum, and some Linux systems have only sha256sum.
	if command -v sha256sum >/dev/null 2>&1; then
		got=$(sha256sum "$state/dl/$image.xz" | cut -d ' ' -f 1)
	else
		got=$(shasum -a 256 "$state/dl/$image.xz" | cut -d ' ' -f 1)
	fi
	if [ "$got" != "$want" ]; then
		rm -f "$state/dl/$image.xz"
		die "the download's SHA-256 is $got, not $want. It was deleted. Run setup again."
	fi
	log "checksum matches, extracting"
	xz -dc "$state/dl/$image.xz" >"$disk.part"
	# The image has about 5 GB of space, which the repository and the test
	# binaries can outgrow. FreeBSD grows its file system to fill the larger
	# disk on the first boot.
	"$qemu_img" resize -q "$disk.part" +10G
	mv "$disk.part" "$disk"
}

make_seed() {
	[ -f "$state/seed.iso" ] && return
	[ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C ghostty-freebsd-vm -f "$key"
	seed=$state/seed
	rm -rf "$seed"
	mkdir -p "$seed"
	# The BASIC-CLOUDINIT images configure themselves on their first boot
	# with nuageinit(8), FreeBSD's version of cloud-init. It reads these two
	# files from a disk image labelled "cidata", which QEMU attaches as a CD.
	#
	# runcmd installs rsync, which vm.sh test copies files with, and sudo,
	# which the sudo rule below needs. It restarts sshd last, so once ssh
	# works the packages are in place.
	cat >"$seed/user-data" <<EOF
#cloud-config
hostname: ghosttybsd
users:
  - name: ghostty
    gecos: Ghostty Test
    groups: wheel
    shell: /bin/sh
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$key.pub")
ssh_pwauth: false
runcmd:
  - env ASSUME_ALWAYS_YES=yes pkg install -y sudo rsync
  - sysrc sshd_enable=YES
  - service sshd restart
EOF
	printf 'instance-id: ghosttybsd-1\nlocal-hostname: ghosttybsd\n' >"$seed/meta-data"
	if command -v hdiutil >/dev/null 2>&1; then
		hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata \
			-o "$state/seed.iso" "$seed"
	else
		if command -v xorriso >/dev/null 2>&1; then
			xorriso=xorriso
		elif command -v nix >/dev/null 2>&1; then
			# Linux has no hdiutil, and CI runners have no xorriso. Take it
			# from the repository's nixpkgs, as find_qemu does QEMU.
			log "using xorriso from the repository's nixpkgs"
			xorriso=$(nix build --inputs-from "$repo" nixpkgs#xorriso --no-link \
				--print-out-paths | head -n 1)/bin/xorriso
		else
			die "writing the seed image needs hdiutil (macOS) or xorriso"
		fi
		"$xorriso" -as mkisofs -quiet -J -V cidata -o "$state/seed.iso" "$seed"
	fi
}

start() {
	if running; then
		log "already running, ssh on 127.0.0.1:$port"
		return
	fi
	[ -f "$disk" ] || die "$state has no disk. Run vm.sh setup first."
	a=$(accel)
	# Emulation cannot pass the host's processor through, so it uses QEMU's
	# most capable emulated one instead.
	[ "$a" = tcg ] && cpu=max || cpu=host
	case $arch in
	arm64) machine="-M virt,accel=$a -bios $firmware" ;;
	# The q35 machine loads UEFI firmware from a flash drive rather than
	# with -bios.
	amd64) machine="-M q35,accel=$a -drive if=pflash,format=raw,readonly=on,file=$firmware" ;;
	esac
	log "booting FreeBSD $release $arch with $a, ssh on 127.0.0.1:$port"
	rm -f "$pidfile"
	# The VM's serial console goes to console.log. When a boot hangs, that
	# file says where.
	# shellcheck disable=SC2086 # machine is a list of words.
	"$qemu" $machine -cpu "$cpu" -smp "$cpus" -m "${memory}M" \
		-drive "if=virtio,file=$disk,format=qcow2" \
		-drive "if=virtio,file=$state/seed.iso,format=raw,media=cdrom,readonly=on" \
		-device virtio-net-pci,netdev=net0 \
		-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" \
		-device virtio-rng-pci \
		-display none -monitor none -serial "file:$console" \
		-daemonize -pidfile "$pidfile"
	wait_ssh
}

wait_ssh() {
	began=$(date +%s)
	while ! guest_ssh true 2>/dev/null; do
		if ! running; then
			tail -n 20 "$console" >&2 || true
			die "QEMU exited during boot. See $console."
		fi
		if [ $(($(date +%s) - began)) -ge "$timeout" ]; then
			tail -n 20 "$console" >&2 || true
			die "ssh did not work after ${timeout}s. See $console."
		fi
		sleep 5
	done
	log "ssh works after $(($(date +%s) - began))s"
}

stop() {
	running || return 0
	pid=$(cat "$pidfile")
	# Shut down from inside the guest so the disk is left consistent. Both
	# the next boot and a snapshot depend on that.
	guest_ssh 'sudo shutdown -p now' >/dev/null 2>&1 || true
	i=0
	while kill -0 "$pid" 2>/dev/null && [ $i -lt 60 ]; do
		sleep 1
		i=$((i + 1))
	done
	if kill -0 "$pid" 2>/dev/null; then
		log "the VM did not power off within 60s, stopping QEMU"
		kill "$pid"
		sleep 1
	fi
	rm -f "$pidfile"
	log "stopped"
}

setup() {
	mkdir -p "$state"
	find_qemu
	fetch_image
	make_seed
	if "$qemu_img" snapshot -l "$disk" | grep -q ' ready '; then
		log "already set up in $state"
		return
	fi
	start
	# Without network access, pkg install fails and nuageinit carries on.
	# Catch that here rather than in the first vm.sh test.
	if ! guest_ssh 'command -v rsync && command -v sudo' >/dev/null; then
		stop
		die "installing sudo and rsync failed. See $console, delete $disk, and run setup again."
	fi
	guest_ssh 'freebsd-version; df -h /'
	stop
	"$qemu_img" snapshot -c ready "$disk"
	log "saved the disk as snapshot \"ready\". vm.sh reset returns to it."
}

reset() {
	running && die "the VM is running. Run vm.sh stop first."
	find_qemu
	"$qemu_img" snapshot -a ready "$disk"
	log "the disk is back at the \"ready\" snapshot"
}

run_tests() {
	tests=${1:-$repo/zig-out/bin}
	[ -d "$tests" ] || die "$tests does not exist. Build the tests first, as shown in vm.sh help."
	tests=$(cd "$tests" && pwd)
	running || die "the VM is not running. Run vm.sh start first."
	case $test_timeout in
	'' | *[!0-9]*) die "GHOSTTY_FREEBSD_VM_TEST_TIMEOUT must be a number of seconds" ;;
	esac
	rsh="ssh $ssh_opts"
	# QEMU's user networking cannot share folders with the guest, so copy the
	# repository in. The excluded directories are large and no test reads
	# them. .claude can hold whole worktrees, each with its own build
	# output. Zig's build directories are excluded at any depth for the same
	# reason, and so is zig-pkg, where Zig keeps downloaded packages.
	rsync -a --delete --delete-excluded -e "$rsh" \
		--exclude /.git --exclude /.jj --exclude /.claude --exclude /macos \
		--exclude /zig-pkg --exclude .zig-cache --exclude zig-out --exclude node_modules \
		"$repo/" ghostty@127.0.0.1:ghostty/
	# Copy only the test binaries. zig-out/bin may also hold other builds.
	rsync -a --delete -e "$rsh" --include '/*-test' --exclude '*' \
		"$tests/" ghostty@127.0.0.1:tests/
	guest_ssh "GHOSTTY_FREEBSD_VM_TEST_TIMEOUT=$test_timeout" \
		"sh ghostty/.github/scripts/freebsd-vm/test-freebsd.sh \$HOME/tests \$HOME/ghostty"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
setup) setup ;;
start)
	find_qemu
	start
	;;
stop) stop ;;
reset) reset ;;
test) run_tests "$@" ;;
ssh)
	running || die "the VM is not running. Run vm.sh start first."
	if [ $# -eq 0 ]; then
		# shellcheck disable=SC2086 # ssh_opts is a list of words.
		exec ssh -t $ssh_opts ghostty@127.0.0.1
	fi
	guest_ssh "$@"
	;;
status)
	if running; then
		echo "running, ssh on 127.0.0.1:$port"
	else
		echo "stopped"
	fi
	;;
help | -h | --help) usage ;;
*)
	usage >&2
	exit 2
	;;
esac
