from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts.verify_models import ModelVerificationError, verify_models


class VerifyModelsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.model_file = self.root / "Memorable/Models/Test.mlmodelc/model.bin"
        self.model_file.parent.mkdir(parents=True)
        self.model_file.write_bytes(b"reviewed model")
        self.manifest = self.root / "manifest.json"
        self._write_manifest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_manifest(self) -> None:
        data = self.model_file.read_bytes()
        self.manifest.write_text(
            json.dumps(
                {
                    "version": 1,
                    "models_root": "Memorable/Models",
                    "model_identity": {
                        "source_revision": "a" * 40,
                        "conversion": {
                            "date": "2026-01-01",
                            "coremltools_version": "9.0",
                            "torch_version": "2.0",
                            "source_dialect": "TorchScript",
                            "minimum_deployment_target": "iOS 17.0",
                            "storage_precision": "Float16",
                            "compute_precision": "Float16",
                            "image_input": "input",
                            "image_output": "output",
                            "text_input": "input",
                            "text_output": "output",
                        },
                    },
                    "files": [
                        {
                            "path": "Memorable/Models/Test.mlmodelc/model.bin",
                            "size": len(data),
                            "sha256": hashlib.sha256(data).hexdigest(),
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

    def test_accepts_exact_manifest(self) -> None:
        verify_models(self.root, self.manifest)

    def test_accepts_exact_packaged_models(self) -> None:
        packaged_root = self.root / "Built.app"
        packaged_file = packaged_root / "Test.mlmodelc/model.bin"
        packaged_file.parent.mkdir(parents=True)
        packaged_file.write_bytes(self.model_file.read_bytes())

        verify_models(self.root, self.manifest, packaged_root)

    def test_rejects_modified_packaged_model(self) -> None:
        packaged_root = self.root / "Built.app"
        packaged_file = packaged_root / "Test.mlmodelc/model.bin"
        packaged_file.parent.mkdir(parents=True)
        packaged_file.write_bytes(b"modified after copy")

        with self.assertRaises(ModelVerificationError):
            verify_models(self.root, self.manifest, packaged_root)

    def test_rejects_modified_file(self) -> None:
        self.model_file.write_bytes(b"modified model")
        with self.assertRaises(ModelVerificationError):
            verify_models(self.root, self.manifest)

    def test_rejects_unmanifested_file(self) -> None:
        (self.model_file.parent / "extra.bin").write_bytes(b"extra")
        with self.assertRaises(ModelVerificationError):
            verify_models(self.root, self.manifest)

    def test_rejects_symbolic_link(self) -> None:
        target = self.root / "outside.bin"
        target.write_bytes(b"outside")
        (self.model_file.parent / "link.bin").symlink_to(target)
        with self.assertRaises(ModelVerificationError):
            verify_models(self.root, self.manifest)

    def test_rejects_malformed_hash(self) -> None:
        document = json.loads(self.manifest.read_text(encoding="utf-8"))
        document["files"][0]["sha256"] = "not-a-sha256"
        self.manifest.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaises(ModelVerificationError):
            verify_models(self.root, self.manifest)

    def test_rejects_missing_conversion_provenance(self) -> None:
        document = json.loads(self.manifest.read_text(encoding="utf-8"))
        del document["model_identity"]["conversion"]
        self.manifest.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaises(ModelVerificationError):
            verify_models(self.root, self.manifest)


if __name__ == "__main__":
    unittest.main()
