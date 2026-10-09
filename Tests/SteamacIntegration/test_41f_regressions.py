#!/usr/bin/env python3
"""Static regression guards for BepisLoader x Steamac.

These checks cannot establish runtime correctness, Proton compatibility,
atomic filesystem operations, or successful rollback under actual failures.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/BepisLoader/Frameworks/ReloadedII/ReloadedIIModManager.swift"

class SteamacSourceRegressions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.graph = cls.source.split("private func installMissingDependenciesSteamac(", 1)[1].split("    func dependencySummary(", 1)[0]
        cls.deferred = cls.source.split("private final class GuestDeferredInstall", 1)[1].split("    enum ReloadedIIDependencyInstallError:", 1)[0]

    def test_graph_installer_still_present(self):
        self.assertIn("appConfigCommitAttempted", self.graph)
        self.assertIn("GuestDeferredInstall", self.graph)

    def test_cycle_check_precedes_staged_shortcut(self):
        # Check within graph acquisition closure, not unrelated local installer.
        graph = self.graph
        check = graph.index("visitSet.contains(")
        staged = graph.index("if staged[\n                normalized\n            ] != nil")
        self.assertLess(check, staged)

    def test_registry_restore_guarded_by_commit_attempt(self):
        graph = self.graph
        self.assertRegex(graph, r"if\s+appConfigCommitAttempted\s*\{")
        self.assertIn("appConfigCommitAttempted =\n                true", graph)

    def test_retry_safe_rollback_state(self):
        self.assertIn("private var replacementRemoved =", self.deferred)
        self.assertIn("replacementRemoved =\n                    true", self.deferred)

    def test_filesystem_preflight(self):
        self.assertIn("// Patch 41F-6: reject non-directory guest roots and staged payloads.", self.source)
        self.assertIn("// Patch 41F-7: preflight the explicit Steamac guest endpoint.", self.source)

    def test_read_only_guest_diagnostics(self):
        self.assertIn("// Patch 41F-9: report only observable guest metadata state.", self.source)
        self.assertIn("// Patch 41F-10: always derive state from this guest read,", self.source)

    def test_actionable_failure_reporting(self):
        self.assertEqual(self.source.count("// Patch 41F-11: recovery guidance"), 2)
        self.assertIn("The installed graph was NOT rolled back", self.source)

    def test_local_installer_not_replaced(self):
        self.assertIn("installMissingDependencies(", self.source)
        self.assertIn("installMissingDependenciesSteamac(", self.source)

if __name__ == "__main__":
    unittest.main(verbosity=2)
