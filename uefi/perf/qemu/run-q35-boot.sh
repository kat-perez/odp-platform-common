#!/usr/bin/env bash
#
# Boots the Patina Q35 firmware under QEMU and reports whether it reaches BDS.
#
# Exits 0 once the BDS entry marker appears on the debug console, non-zero if
# the marker has not appeared before the timeout. The firmware keeps running
# after BDS is reached when no boot device is attached, so this stops QEMU as
# soon as the marker is seen rather than waiting for an exit.

set -euo pipefail

# QEMU wiring that the Patina Q35 firmware expects. These values are fixed by
# the platform, not tunable: the DXE Core logger writes to the debug console at
# DEBUGCON_IO_PORT, and the firmware signals completion through the debug exit
# device at DEBUG_EXIT_IO_PORT.
readonly DEBUGCON_IO_PORT=0x402
readonly DEBUG_EXIT_IO_PORT=0xf4
readonly DEBUG_EXIT_IO_SIZE=0x04

# Emitted by BdsDxe when the boot device selection phase begins. Reaching this
# line is the definition of a successful bringup boot.
readonly BDS_READY_MARKER='[Bds] Entry...'

# Identifies which DXE Core the firmware actually loaded, and is reported on
# success so a run can be attributed to a specific build.
readonly DXE_CORE_BANNER='DXE Core Platform Binary'

# Q35 firmware is built as a pair of flash images: unit 0 is execute-only code,
# unit 1 is the writable variable store.
readonly FLASH_UNIT_CODE=0
readonly FLASH_UNIT_VARS=1

readonly GUEST_MEMORY_MB=2048
readonly GUEST_CPU_COUNT=4

# Interval between checks of the debug console log for the BDS marker.
readonly POLL_INTERVAL_SECONDS=2

# Generous enough for a cold TCG boot on a loaded CI runner; a healthy boot
# reaches BDS in a few seconds.
readonly DEFAULT_TIMEOUT_SECONDS=180

# Exit code used for usage and environment problems, to keep them distinct from
# a firmware that simply failed to reach BDS.
readonly EXIT_USAGE=2

readonly POSITIVE_INTEGER_PATTERN='^[1-9][0-9]*$'

readonly QEMU_COMMAND=qemu-system-x86_64

usage() {
  cat <<'EOF'
Usage: run-q35-boot.sh --firmware-dir DIR [--timeout SECONDS] [--out-dir DIR]

  --firmware-dir  Directory holding QEMUQ35_CODE.fd and QEMUQ35_VARS.fd.
  --timeout       Seconds to wait for BDS before failing.
  --out-dir       Directory for the boot log and the writable variable store.
EOF
}

firmware_dir=""
out_dir=""
timeout_seconds="${DEFAULT_TIMEOUT_SECONDS}"

# Reading "$2" for a flag given without a value trips 'set -u', which reports a
# bash error and exits 1 -- the code that means the firmware failed to reach
# BDS. Check for the value first so misuse stays distinguishable.
require_value() {
  local flag="$1" value="${2:-}"
  if [ -z "$value" ]; then
    echo "missing value for $flag" >&2
    usage >&2
    exit "$EXIT_USAGE"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --firmware-dir) require_value "$1" "${2:-}"; firmware_dir="$2"; shift 2 ;;
    --timeout) require_value "$1" "${2:-}"; timeout_seconds="$2"; shift 2 ;;
    --out-dir) require_value "$1" "${2:-}"; out_dir="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit "$EXIT_USAGE" ;;
  esac
done

if [ -z "$firmware_dir" ]; then
  echo "--firmware-dir is required" >&2
  usage >&2
  exit "$EXIT_USAGE"
fi

# The timeout is only used in arithmetic much later, after QEMU has started, so
# a bad value would otherwise surface as a boot failure rather than as misuse.
if ! [[ "$timeout_seconds" =~ $POSITIVE_INTEGER_PATTERN ]]; then
  echo "--timeout must be a positive whole number of seconds: ${timeout_seconds}" >&2
  exit "$EXIT_USAGE"
fi

code_fd="${firmware_dir}/QEMUQ35_CODE.fd"
vars_fd_source="${firmware_dir}/QEMUQ35_VARS.fd"

# A missing tool would otherwise surface as "command not found" (127) or a
# generic shell failure, neither of which the caller can tell apart from
# firmware that simply never reached BDS.
if ! command -v "$QEMU_COMMAND" >/dev/null 2>&1; then
  echo "required command not found: ${QEMU_COMMAND}" >&2
  exit "$EXIT_USAGE"
fi

for image in "$code_fd" "$vars_fd_source"; do
  if [ ! -f "$image" ]; then
    echo "firmware image not found: $image" >&2
    exit "$EXIT_USAGE"
  fi
done

if [ -z "$out_dir" ]; then
  out_dir="$(mktemp -d)"
fi
mkdir -p "$out_dir"

boot_log="${out_dir}/boot-debugcon.log"

# The variable store is written during boot, so run against a copy to keep the
# extracted firmware directory reusable across runs.
vars_fd="${out_dir}/QEMUQ35_VARS.writable.fd"
cp "$vars_fd_source" "$vars_fd"
chmod u+w "$vars_fd"

: > "$boot_log"

"$QEMU_COMMAND" \
  -debugcon "file:${boot_log}" \
  -global "isa-debugcon.iobase=${DEBUGCON_IO_PORT}" \
  -global ICH9-LPC.disable_s3=1 \
  -device "isa-debug-exit,iobase=${DEBUG_EXIT_IO_PORT},iosize=${DEBUG_EXIT_IO_SIZE}" \
  -machine q35,smm=on,accel=tcg \
  -global driver=cfi.pflash01,property=secure,value=on \
  -cpu qemu64,+rdrand,+umip,+smep,+pdpe1gb,+popcnt,+sse,+sse2,+sse3,+ssse3,+sse4.2,+sse4.1 \
  -smp "${GUEST_CPU_COUNT}" \
  -m "${GUEST_MEMORY_MB}" \
  -drive "if=pflash,format=raw,unit=${FLASH_UNIT_CODE},file=${code_fd},readonly=on" \
  -drive "if=pflash,format=raw,unit=${FLASH_UNIT_VARS},file=${vars_fd}" \
  -display none \
  -no-reboot &
qemu_pid=$!

stop_qemu() {
  if kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
}
trap stop_qemu EXIT

deadline=$((SECONDS + timeout_seconds))
reached_bds=false

while [ "$SECONDS" -lt "$deadline" ]; do
  if grep -qF "$BDS_READY_MARKER" "$boot_log" 2>/dev/null; then
    reached_bds=true
    break
  fi
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    echo "QEMU exited before reaching BDS" >&2
    break
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

stop_qemu
trap - EXIT

echo "boot log: ${boot_log}"

if [ "$reached_bds" != true ]; then
  echo "FAIL: did not reach BDS within ${timeout_seconds}s" >&2
  exit 1
fi

echo "PASS: reached BDS"
grep -m1 -nF "$DXE_CORE_BANNER" "$boot_log" || true
grep -m1 -nF "$BDS_READY_MARKER" "$boot_log"
