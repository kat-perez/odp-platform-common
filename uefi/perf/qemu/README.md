# QEMU bringup for Patina firmware

`run-q35-boot.sh` boots a Patina Q35 firmware pair under QEMU and reports
whether it reaches BDS. It is the entry point for measuring Patina boot
behaviour on a machine that is reproducible in CI, rather than on real
hardware.

## Requirements

- `qemu-system-x86_64` on `PATH`.
- A Q35 firmware directory containing `QEMUQ35_CODE.fd` and `QEMUQ35_VARS.fd`.

## Getting firmware

The quickest path is a published build. Releases of
[`OpenDevicePartnership/patina-qemu`](https://github.com/OpenDevicePartnership/patina-qemu)
attach a `patina-qemu-q35-<version>.zip` containing both `.fd` images.

To build instead — required if performance measurement is wanted, since the
tracing flag is compile-time — check out `patina-qemu` and run:

```sh
python -m venv .venv && . .venv/bin/activate
pip install -r pip-requirements.txt
stuart_setup  -c Platforms/QemuQ35Pkg/PlatformBuild.py
stuart_update -c Platforms/QemuQ35Pkg/PlatformBuild.py
stuart_build  -c Platforms/QemuQ35Pkg/PlatformBuild.py 'BLD_*_PERF_TRACE_ENABLE=TRUE'
```

The images land in `Build/QemuQ35Pkg/DEBUG_CLANGPDB/FV/`. The build uses the
CLANGPDB toolchain, so no Visual Studio installation is involved; `nasm`,
`iasl`, `mono` and `uuid-dev` are the notable prerequisites.

`PERF_TRACE_ENABLE` defaults to `FALSE`. It has to be set at build time because
the platform PEI always publishes the Patina performance configuration HOB, and
a HOB that is present but disabled takes precedence over the DXE Core's own
default. Replacing only the DXE Core binary therefore cannot turn measurement
on.

## Running

```sh
./run-q35-boot.sh --firmware-dir <dir> --out-dir <dir>
```

| Exit code | Meaning |
| --------- | ------- |
| 0 | The BDS entry marker appeared on the debug console. |
| 1 | The firmware did not reach BDS before the timeout. |
| 2 | Bad arguments, or a required file or tool was missing. |

`qemu-system-x86_64` is checked before the guest starts, so a missing emulator
is reported as exit 2 up front instead of looking like a firmware that failed
to reach BDS.

The debug console log is written to `boot-debugcon.log` in the output
directory and is the primary artifact to inspect on failure. The variable
store is copied before use, so the firmware directory stays reusable across
runs.

## Confirming that measurement is enabled

A firmware built with the tracing flag reports the configuration it published
during PEI:

```
PublishPatinaPerformanceConfigHob: Patina Performance Config HOB: Enabled=1, EnabledMeasurements=0x9
```

`Enabled=0` means the firmware was built without `PERF_TRACE_ENABLE` and will
produce no performance records, even though it still boots normally.

## Capturing firmware performance data

Patina publishes a firmware basic boot performance table (FBPT) during boot.
Reading it needs a UEFI Shell application, `FbptDump.efi`, which writes the
table to its own volume; it is not part of a default build, so add
`UefiTestingPkg/PerfTests/FbptDump/FbptDump.inf` to `QemuQ35Pkg.dsc` before
building.

Build a disk that boots to the shell and dumps the table, then run a capture:

```sh
./make-fbpt-disk.sh --build-dir <build>/X64 --out dump-disk.img
./capture-fbpt.sh --firmware-dir <fw> --disk dump-disk.img --out-dir <results>
```

The guest powers itself off once the dump completes, so the capture ends on its
own rather than on a timeout. The output directory receives the captured
`FBPT.bin`, the boot log, the dump application's own output, and the parsed
`fbpt.xml` / `fbpt.txt`.

Each capture finishes by printing the boot time in milliseconds, taken from the
ACPI basic boot performance record:

```text
boot time (reset to OS loader handoff): 2642.295 ms
  ResetEnd                         0.000 ms
  OSLoaderLoadImageStart        2629.683 ms
  OSLoaderStartImageStart       2642.295 ms
```

The summary deliberately stops there. The parser also emits per-phase records,
but their millisecond values are not all on one time base in this firmware, so
a PEI/DXE/BDS breakdown built from them would read as authoritative while being
wrong. Use `fbpt.txt` or `fbpt.xml` when you need that detail. The summary can
also be run on its own against an existing report:

```sh
python3 boot_time_summary.py <results>/fbpt.xml
```

Capture fails with exit 1 if the firmware reports that measurement is disabled,
if the guest never powers off, if the dump log cannot be read back off the
disk, or if no table was written; exit 2 still means a setup problem.

`qemu-system-x86_64`, mtools and the parser dependency are all checked before
the guest starts, so a missing tool is reported as exit 2 up front rather than
surfacing as a shell error partway through a capture that has already taken
minutes to run.

### Parsing

Parsing needs `edk2-pytool-extensions`:

```sh
pip install edk2-pytool-extensions
```

`capture-fbpt.sh` invokes the parser through `fpdt_parser_any_platform.py`.
The packaged `fpdt_parser` can read the live FPDT from a running Windows
system, so it imports `windll` at module scope and builds its Windows
firmware-table accessor unconditionally. Neither is used when parsing a
captured binary, but both break the tool on Linux, which is where CI runs. The
wrapper supplies the missing pieces and raises if a Windows-only path is ever
actually reached.

For a readable breakdown by module, feed the parsed XML to the report
generator with a source tree to resolve GUIDs against:

```sh
perf_report_generator -i <results>/fbpt.xml -r report.html -s <patina-qemu>
```

Unmatched start records are expected when the guest powers off from the shell,
since phases that would normally end at boot never complete.
