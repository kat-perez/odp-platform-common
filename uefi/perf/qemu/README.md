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
| 2 | Bad arguments, or a firmware image was missing. |

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
