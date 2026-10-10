#!/usr/bin/env python3
"""Offline regressions for the release helper's official-license fallback."""
import base64
import hashlib
import io
import json
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest


class LicenseFallbackTests(unittest.TestCase):
    version = "20.0.28"

    def run_fixture(self, mutation=None):
        with tempfile.TemporaryDirectory(prefix="ccusage-license-test-") as directory:
            root = Path(directory)
            notice = b"MIT License\nCopyright (c) Fixture\nPermission is hereby granted\n"
            package = {"name": "ccusage", "version": self.version, "license": "MIT"}
            if mutation in ("name", "version", "license"):
                package[mutation] = "wrong"
            archive = root / "package.tgz"
            with tarfile.open(archive, "w:gz") as output:
                members = [("package/package.json", json.dumps(package).encode())]
                if mutation != "missing":
                    members.append(("package/LICENSE", b"invalid" if mutation == "notice" else notice))
                if mutation == "duplicate":
                    members.append(("package/LICENSE", notice))
                for name, data in members:
                    member = tarfile.TarInfo(name)
                    if name == "package/LICENSE" and mutation == "symlink":
                        member.type = tarfile.SYMTYPE
                        member.linkname = "/etc/passwd"
                        output.addfile(member)
                    else:
                        if name == "package/LICENSE" and mutation == "oversize":
                            data = b"x" * 65537
                        member.size = len(data)
                        output.addfile(member, io.BytesIO(data))
            payload = archive.read_bytes()
            metadata = {
                "name": "ccusage", "version": self.version,
                "dist": {
                    "tarball": f"https://registry.npmjs.org/ccusage/-/ccusage-{self.version}.tgz",
                    "shasum": hashlib.sha1(payload).hexdigest(),
                    "integrity": "sha512-" + base64.b64encode(hashlib.sha512(payload).digest()).decode(),
                },
            }
            if mutation == "sha1":
                metadata["dist"]["shasum"] = "0" * 40
            if mutation == "sha512":
                metadata["dist"]["integrity"] = "sha512-invalid"
            if mutation == "url":
                metadata["dist"]["tarball"] = "https://example.invalid/package.tgz"
            if mutation == "metadata-version":
                metadata["version"] = "20.0.27"
                metadata["dist"]["tarball"] = "https://registry.npmjs.org/ccusage/-/ccusage-20.0.27.tgz"
            (root / "metadata.json").write_text(json.dumps(metadata))
            transport = root / "fixture-curl.py"
            transport.write_text(
                "import pathlib,shutil,sys\n"
                "root=pathlib.Path(__file__).parent\n"
                "args=sys.argv[1:]; index=args.index('-o')\n"
                "url=args[index-1]\n"
                "source='package.tgz' if url.endswith('.tgz') else 'metadata.json'\n"
                "shutil.copyfile(root/source,args[index+1])\n"
            )
            source = Path(__file__).with_name("verify_ccusage_freshness.sh").read_text()
            # Exercise the actual shell functions, replacing only HTTP transport
            # with fixture files. No network, installed helpers or Keychain use.
            functions = source.split("metadata_value() {", 1)[1].split('if [[ "$MODE" !=', 1)[0]
            functions = "metadata_value() {" + functions
            functions = functions.replace("/usr/bin/curl", "/usr/bin/python3 " + shlex.quote(str(transport)))
            script = root / "test.sh"
            script.write_text(
                "set -euo pipefail\n"
                'fail() { echo "$*" >&2; exit 1; }\n'
                + "WORK_DIR=" + shlex.quote(str(root / "work")) + "\n"
                + functions + f"\ndownload_same_version_license {self.version}\n"
            )
            result = subprocess.run(["bash", str(script)], capture_output=True, text=True)
            saved = root / "work" / f"license-{self.version}" / "LICENSE"
            if mutation is None:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(saved.read_bytes(), notice)
            else:
                self.assertNotEqual(result.returncode, 0, mutation)
                self.assertFalse(saved.exists(), mutation)

    def test_verified_same_version_notice_is_preserved(self):
        self.run_fixture()

    def test_invalid_sources_never_supply_a_license(self):
        for mutation in ("sha1", "sha512", "url", "metadata-version", "name", "version",
                         "license", "missing", "duplicate", "symlink", "oversize", "notice"):
            with self.subTest(mutation=mutation):
                self.run_fixture(mutation)


if __name__ == "__main__":
    unittest.main()
