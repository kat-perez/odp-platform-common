"""Runs edk2toolext's fpdt_parser on a captured FBPT binary from any platform.

fpdt_parser can read the live FPDT out of the running Windows system, so it
imports ``windll``/``WinError`` at module scope and constructs its Windows
firmware-table accessor unconditionally in ``main``. Parsing a binary captured
elsewhere (``-b``) never uses that accessor -- every call site is guarded on
``input_fbpt_bin is None`` -- but the import and the construction still fail on
a non-Windows host.

This wrapper supplies the missing ctypes names and replaces the accessor with a
stand-in, so the same parser can run in CI on Linux. Any code path that does
reach the Windows API raises rather than silently misbehaving.
"""

import ctypes
import sys


class WindowsOnlyApi:
    """Stands in for Windows-only interfaces that are absent on this host."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        pass

    def __getattr__(self, name: str) -> None:
        raise RuntimeError(
            f"fpdt_parser reached the Windows-only interface '{name}'. Reading "
            "the live FPDT requires Windows; pass a captured FBPT binary with "
            "-b instead."
        )


if not hasattr(ctypes, "windll"):
    ctypes.windll = WindowsOnlyApi()
    ctypes.WinError = OSError

from edk2toolext.perf import fpdt_parser  # noqa: E402

if not sys.platform.startswith("win"):
    fpdt_parser.SystemFirmwareTable = WindowsOnlyApi

if __name__ == "__main__":
    sys.exit(fpdt_parser.main())
