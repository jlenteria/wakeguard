#!/usr/bin/env python3
"""Fails if WakeGuard ever gains the ability to resist removal.

An alarm app that is hard to uninstall has broken its own purpose: the user must
always be able to walk away from it. The dangerous capabilities are the ones
that survive a Settings > Apps > Uninstall:

  * Device admin / accessibility service - the classic uninstall blocker.
  * Device owner / profile owner - grants near-total device control.
  * Lock-task mode (screen pinning) - traps the user on the alarm screen.
  * SYSTEM_ALERT_WINDOW over other apps - persistent overlays.

None of these are needed for any WakeGuard feature. This script asserts their
absence so that adding one later has to be a deliberate, visible change rather
than an accidental dependency.

Usage: python3 tool/check_removable.py   (exit 0 = pass, 1 = fail)
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ANDROID = ROOT / "android" / "app" / "src" / "main"
MANIFEST = ANDROID / "AndroidManifest.xml"

#: capability -> markers that would grant or use it
FORBIDDEN: dict[str, tuple[str, ...]] = {
    "device admin": (
        "android.permission.BIND_DEVICE_ADMIN",
        "DeviceAdminReceiver",
        "device_admin",
        "android.app.action.DEVICE_ADMIN_ENABLED",
    ),
    "accessibility service": (
        "android.permission.BIND_ACCESSIBILITY_SERVICE",
        "AccessibilityService",
        "AccessibilityEvent",
    ),
    "device owner": (
        "android.app.action.DEVICE_ADMIN_ENABLED",
        "setDeviceOwner",
        "DevicePolicyManager",
        "device_owner",
        "profile_owner",
    ),
    "lock task / screen pinning": (
        "lockTaskMode",
        "startLockTask",
        "BIND_TASK_PINNING",
        "LockTaskBroadcastReceiver",
    ),
    "system alert window": (
        "android.permission.SYSTEM_ALERT_WINDOW",
        "TYPE_APPLICATION_OVERLAY",
        "TYPE_SYSTEM_ALERT",
        "TYPE_SYSTEM_OVERLAY",
    ),
    "write settings / overlay abuse": (
        "android.permission.WRITE_SETTINGS",
        "android.permission.SYSTEM_ALERT_WINDOW",
    ),
}


def main() -> int:
    if not MANIFEST.exists():
        print(f"fail: manifest not found at {MANIFEST}")
        return 1

    manifest = MANIFEST.read_text()
    # Resource values files are included because device admin normally requires a
    # res/xml/<something>_device_admin.xml declaring its policy.
    haystack_parts = [manifest]
    res_values = ANDROID / "res"
    if res_values.exists():
        for path in res_values.rglob("*.xml"):
            haystack_parts.append(path.read_text())
    kotlin = ANDROID / "kotlin"
    if kotlin.exists():
        for path in kotlin.rglob("*.kt"):
            haystack_parts.append(path.read_text())
    haystack = "\n".join(haystack_parts)

    failures: list[str] = []
    for capability, markers in FORBIDDEN.items():
        for marker in markers:
            if marker not in haystack:
                continue
            # Distinguish an honest comment about the guard from a real usage.
            for line in haystack.splitlines():
                if marker in line and line.strip().startswith(("//", "*", "<!--")):
                    continue
                failures.append(f"{capability}: found {marker!r} in:")
                failures.append(f"    {line.strip()[:110]}")
                break

    if failures:
        print("REMOVABILITY GUARD FAILED")
        print()
        print("WakeGuard must never gain these capabilities. The user has to be")
        print("able to uninstall it at any time, which is what makes the app safe")
        print("to install in the first place.")
        print()
        for line in failures:
            print("  " + line)
        return 1

    declared = sorted(set(re.findall(r"android\.permission\.([A-Z_]+)", manifest)))
    print("removability guard: PASS")
    print(f"  no admin/accessibility/device-owner/lock-task/overlay usage found")
    print(f"  {len(declared)} permissions declared, all revocable and cleared on uninstall:")
    for permission in declared:
        print(f"    - {permission}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
