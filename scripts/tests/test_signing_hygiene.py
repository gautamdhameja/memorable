from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import signing_hygiene  # noqa: E402


class SigningHygieneTests(unittest.TestCase):
    def test_sensitive_path_detection_covers_credentials_and_local_config(self) -> None:
        sensitive = [
            "Certificates/distribution.p12",
            "Certificates/distribution.cer",
            "request.certSigningRequest",
            "Profiles/app.mobileprovision",
            "Keys/AuthKey_123.p8",
            "ExportOptions.plist",
            ".env",
            "Config/Local.xcconfig",
        ]

        for path in sensitive:
            self.assertTrue(signing_hygiene.is_sensitive_path(path), path)
        self.assertFalse(signing_hygiene.is_sensitive_path("Config/Build.xcconfig"))
        self.assertFalse(signing_hygiene.is_sensitive_path("README.md"))

    def test_validation_accepts_an_ignored_untracked_local_config(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.initialize_repository(root)
            (root / ".gitignore").write_text(
                "*.p12\n*.cer\n*.certSigningRequest\n*.mobileprovision\n"
                "*.p8\nExportOptions.plist\n.env\nConfig/Local.xcconfig\n",
                encoding="utf-8",
            )
            self.git(root, "add", ".gitignore")

            self.assertEqual(signing_hygiene.validation_errors(root), [])

    def test_validation_rejects_a_force_tracked_credential(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.initialize_repository(root)
            (root / ".gitignore").write_text(
                "*.p8\nConfig/Local.xcconfig\n",
                encoding="utf-8",
            )
            key = root / "AuthKey_TEST.p8"
            key.write_text("not-a-real-key", encoding="utf-8")
            self.git(root, "add", ".gitignore")
            self.git(root, "add", "-f", key.name)

            errors = signing_hygiene.validation_errors(root)

            self.assertEqual(len(errors), 1)
            self.assertIn(key.name, errors[0])

    @staticmethod
    def initialize_repository(root: Path) -> None:
        subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)

    @staticmethod
    def git(root: Path, *arguments: str) -> None:
        subprocess.run(["git", *arguments], cwd=root, check=True)


if __name__ == "__main__":
    unittest.main()
