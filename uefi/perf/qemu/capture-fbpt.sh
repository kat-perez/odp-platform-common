#!/usr/bin/env bash
#
# Captures firmware performance data from a Patina Q35 firmware under QEMU.
#
# Boots the firmware with the dump disk from make-fbpt-disk.sh attached. The
# guest writes the firmware basic boot performance table (FBPT) back to that
# disk and powers itself off, so this waits for QEMU to exit rather than
# watching for a console marker. The table is then copied out and parsed.

set -euo pipefail

# QEMU wiring that the Patina Q35 firmware expects; fixed by the platform.
readonly DEBUGCON_IO_PORT=0x402
readonly DEBUG_EXIT_IO_PORT=0xf4
readonly DEBUG_EXIT_IO_SIZE=0x04

# Flash unit 0 is execute-only code, unit 1 is the writable variable store.
readonly FLASH_UNIT_CODE=0
readonly FLASH_UNIT_VARS=1

readonly GUEST_MEMORY_MB=2048
readonly GUEST_CPU_COUNT=4

# The guest powers itself off once the dump completes, so this only bounds a
# hang. A healthy capture finishes in well under a minute.
readonly DEFAULT_TIMEOUT_SECONDS=300
readonly POLL_INTERVAL_SECONDS=2

# Written by the dump application; the name carries the model and firmware
# version, which vary, so it is matched by prefix.
readonly FBPT_FILE_PREFIX=FBPT
readonly SHELL_LOG_NAME=dumplog.txt

# Reported by the dump application on success.
readonly DUMP_SUCCESS_MARKER='Wrote to file'

# Confirms the firmware was built with performance tracing selected. Without
# it the boot succeeds but carries no measurements.
readonly PERFORMANCE_ENABLED_MARKER='Patina Performance Config HOB: Enabled=1'

readonly EXIT_USAGE=2

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PARSER_WRAPPER="${script_dir}/fpdt_parser_any_platform.py"

usage() {
  cat <<'EOF'
Usage: capture-fbpt.sh --firmware-dir DIR --disk IMAGE --out-dir DIR
                       [--timeout SECONDS] [--python PYTHON]

  --firmware-dir  Directory holding QEMUQ35_CODE.fd and QEMUQ35_VARS.fd.
  --disk          Dump disk image produced by make-fbpt-disk.sh.
  --out-dir       Directory for the captured table, logs and parsed output.
  --timeout       Seconds to wait for the guest to power itself off.
  --python        Interpreter with edk2-pytool-extensions installed.

The firmware must be built with 'BLD_*_PERF_TRACE_ENABLE=TRUE'; see README.md.
EOF
}

firmware_dir=""
disk_image=""
out_dir=""
timeout_seconds="${DEFAULT_TIMEOUT_SECONDS}"
python_bin="python3"

while [ $# -gt 0 ]; do
  case "$1" in
    --firmware-dir) firmware_dir="$2"; shift 2 ;;
    --disk) disk_image="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --timeout) timeout_seconds="$2"; shift 2 ;;
    --python) python_bin="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit "$EXIT_USAGE" ;;
  esac
done

if [ -z "$firmware_dir" ] || [ -z "$disk_image" ] || [ -z "$out_dir" ]; then
  echo "--firmware-dir, --disk and --out-dir are all required" >&2
  usage >&2
  exit "$EXIT_USAGE"
fi

code_fd="${firmware_dir}/QEMUQ35_CODE.fd"
vars_fd_source="${firmware_dir}/QEMUQ35_VARS.fd"

for image in "$code_fd" "$vars_fd_source" "$disk_image"; do
  if [ ! -f "$image" ]; then
    echo "image not found: $image" >&2
    exit "$EXIT_USAGE"
  fi
done

mkdir -p "$out_dir"
boot_log="${out_dir}/capture-debugcon.log"

# The guest writes to both the variable store and the dump disk, so run against
# copies to keep the inputs reusable across captures.
vars_fd="${out_dir}/QEMUQ35_VARS.writable.fd"
capture_disk="${out_dir}/fbpt-disk.img"
cp "$vars_fd_source" "$vars_fd"
cp "$disk_image" "$capture_disk"
chmod u+w "$vars_fd" "$capture_disk"

: > "$boot_log"

qemu-system-x86_64 \
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
  -device ich9-ahci,id=ahci \
  -drive "id=fbptdisk,if=none,format=raw,file=${capture_disk}" \
  -device ide-hd,bus=ahci.0,drive=fbptdisk \
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
guest_powered_off=false

while [ "$SECONDS" -lt "$deadline" ]; do
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    guest_powered_off=true
    break
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

stop_qemu
trap - EXIT

echo "boot log: ${boot_log}"

if ! grep -qF "$PERFORMANCE_ENABLED_MARKER" "$boot_log" 2>/dev/null; then
  echo "FAIL: firmware did not enable performance measurement" >&2
  echo "      rebuild with 'BLD_*_PERF_TRACE_ENABLE=TRUE'" >&2
  exit 1
fi

if [ "$guest_powered_off" != true ]; then
  echo "FAIL: guest did not power off within ${timeout_seconds}s" >&2
  exit 1
fi

export MTOOLS_SKIP_CHECK=1

if mtype -i "$capture_disk" "::/${SHELL_LOG_NAME}" >"${out_dir}/${SHELL_LOG_NAME}" 2>/dev/null; then
  echo "dump application output: ${out_dir}/${SHELL_LOG_NAME}"
fi

if ! grep -qF "$DUMP_SUCCESS_MARKER" "${out_dir}/${SHELL_LOG_NAME}" 2>/dev/null; then
  echo "FAIL: the dump application did not report writing a table" >&2
  exit 1
fi

# The written name embeds the model and firmware version and contains spaces,
# so recover the short name from the directory listing rather than globbing.
short_name="$(mdir -i "$capture_disk" ::/ \
  | awk -v prefix="$FBPT_FILE_PREFIX" \
      '$1 ~ "^" prefix && $2 == "BIN" { print $1 "." $2; exit }')"

if [ -z "$short_name" ]; then
  echo "FAIL: no ${FBPT_FILE_PREFIX}*.bin on the dump disk" >&2
  exit 1
fi

fbpt_bin="${out_dir}/${FBPT_FILE_PREFIX}.bin"
mcopy -o -i "$capture_disk" "::/${short_name}" "$fbpt_bin"
echo "captured table: ${fbpt_bin} ($(wc -c <"$fbpt_bin") bytes)"

"$python_bin" "$PARSER_WRAPPER" \
  -b "$fbpt_bin" \
  -x "${out_dir}/fbpt.xml" \
  -t "${out_dir}/fbpt.txt"

echo "PASS: captured firmware performance data"
echo "parsed records: ${out_dir}/fbpt.xml, ${out_dir}/fbpt.txt"
