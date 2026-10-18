"""The attribution exception must not permit runtime URLs, APIs or remote packages."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class OfflineGuardTests(unittest.TestCase):
    def check(self, source_path, source, package="local target"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            shutil.copyfile(Path(__file__).resolve().parents[1] / "check_offline.py",
                            root / "scripts/check_offline.py")
            path = root / source_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
            (root / "Core").mkdir(exist_ok=True)
            (root / "Core/Package.swift").write_text(package)
            (root / "project.yml").write_text("local package")
            return subprocess.run([sys.executable, root / "scripts/check_offline.py"],
                                  capture_output=True, text=True).returncode

    def test_vendor_license_comment_is_allowed(self):
        self.assertEqual(self.check("Core/Sources/MaterialColorUtilities/Hct.swift",
                                    "//      http://www.apache.org/licenses/LICENSE-2.0"), 0)

    def test_exception_does_not_allow_runtime_url_or_api(self):
        for source in ['let url = "http://www.apache.org/licenses/LICENSE-2.0"',
                       "let session = URLSession.shared", 'let endpoint = "https://example.com"']:
            with self.subTest(source=source):
                self.assertNotEqual(self.check("Core/Sources/MaterialColorUtilities/Hct.swift", source), 0)

    def test_exception_is_scoped_to_vendor_and_keeps_dependencies_local(self):
        self.assertNotEqual(self.check("App/Example.swift",
                                       "//      http://www.apache.org/licenses/LICENSE-2.0"), 0)
        self.assertNotEqual(self.check("App/Example.swift", "import Foundation",
                                       'package(url: "https://example.com/library")'), 0)


if __name__ == "__main__":
    unittest.main()
