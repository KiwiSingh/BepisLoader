#!/usr/bin/env python3
"""41F-13 repeatable release gate: static checks and build only."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / "Sources/BepisLoader/Frameworks/ReloadedII/ReloadedIIModManager.swift"
TEST = ROOT / "Tests/SteamacIntegration/test_41f_regressions.py"
REPORT = ROOT / "Tests/SteamacIntegration/41f-release-report.json"

def command(args):
    try:
        p = subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=300, check=False)
        return {"passed": p.returncode == 0, "returncode": p.returncode,
                "output_tail": p.stdout[-5000:]}
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"passed": False, "error": str(exc)}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-build", action="store_true",
                    help="Run only static checks; report cannot pass build gate")
    args = ap.parse_args()
    checks = {}
    checks["source_present"] = {"passed": SWIFT.is_file()}
    checks["regression_suite_present"] = {"passed": TEST.is_file()}
    if TEST.is_file():
        checks["static_regressions"] = command([sys.executable, str(TEST)])
    else:
        checks["static_regressions"] = {"passed": False, "error": "41F-12 suite missing"}
    checks["git_diff_check"] = command(["git", "diff", "--check"])
    if args.skip_build:
        checks["swift_build"] = {"passed": False, "skipped": True}
    else:
        checks["swift_build"] = command(["swift", "build"])
    # These are intentionally NOT inferred from a green build.
    manual_gates = {
        "guest_transaction_fault_injection": "NOT_VERIFIED",
        "bidirectional_guest_host_sync": "NOT_VERIFIED",
        "proton_reloaded_ii_execution": "NOT_VERIFIED",
        "real_mod_compatibility_matrix": "NOT_VERIFIED",
        "release_signing_and_packaging": "NOT_VERIFIED",
    }
    report = {
        "patch": "41F-13",
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "checks": checks,
        "automated_checks_pass": all(x.get("passed") for x in checks.values()),
        "manual_release_gates": manual_gates,
        "production_ready": False,
        "reason": "Runtime and release validation gates require explicit evidence.",
    }
    REPORT.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                      encoding="utf-8")
    for name, result in checks.items():
        print(("PASS" if result.get("passed") else "FAIL"), name)
    print("Runtime compatibility: UNVERIFIED")
    print("Production readiness: NOT ESTABLISHED")
    print("Report:", REPORT)
    return 0 if report["automated_checks_pass"] else 1

if __name__ == "__main__":
    sys.exit(main())
