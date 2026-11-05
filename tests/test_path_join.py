"""Run with: python -m unittest discover -s tests -v (requires steel on PATH)."""

from pathlib import Path
import subprocess
import tempfile
import unittest


class PathJoinTests(unittest.TestCase):
    def test_path_join_matches_forge_native_paths(self):
        # Extract the actual helper to test it without loading Helix-only modules.
        source = (Path(__file__).resolve().parents[1] / "smith.scm").read_text(
            encoding="utf-8"
        )
        start = source.index("(define (smith-path-join . parts)")
        end = source.index("\n(define (smith-config-root)", start)
        helper = source[start:end]
        checks = r'''
(define (check label actual expected)
  (unless (equal? actual expected)
    (error (string-append label ": expected " expected ", got " actual))))
(define separator (path-separator))
(define root
  (if (equal? separator "\\") "C:\\Users\\test\\.steel" "/home/test/.steel"))
;; First-time registration compares these strings using equal?.
(check "Forge installation path"
       (smith-path-join root "cogs" "example")
       (string-append root separator "cogs" separator "example"))
(check "empty join" (smith-path-join) "")
(check "single path" (smith-path-join root) root)
(check "relative paths"
       (smith-path-join "steel" "plugins" "registry.scm")
       (string-append "steel" separator "plugins" separator "registry.scm"))
'''
        with tempfile.TemporaryDirectory(prefix="smith-path-test-") as directory:
            script = Path(directory) / "path-join.scm"
            script.write_text(helper + checks, encoding="utf-8")
            result = subprocess.run(
                ["steel", str(script)], capture_output=True, text=True,
                encoding="utf-8", timeout=30,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
