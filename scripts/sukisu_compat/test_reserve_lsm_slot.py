#!/usr/bin/env python3
"""Check that the additional slots affect the preprocessor's numeric count."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from reserve_lsm_slot import reserve_slot


# Keep the ACK 6.12 macro structure and its trailing-comma convention.
HEADER = r"""#ifdef CONFIG_SECURITY
#define NATIVE_ENABLED 1,1,1,1,1,
#define __COUNT_LSMS(skipped_arg, args...) COUNT_ARGS(args...)
#define COUNT_LSMS(args...) __COUNT_LSMS(args)
#define MAX_LSM_COUNT \
    COUNT_LSMS( \
        NATIVE_ENABLED \
        OTHER_ENABLED)
#define OTHER_ENABLED
#else
#define MAX_LSM_COUNT 0
#endif
"""
PREAMBLE = r"""#define __COUNT_ARGS(_0,_1,_2,_3,_4,_5,_6,_7,_8,_9,_10,_11,_12,_13,_14,_15,_n,X...) _n
#define COUNT_ARGS(X...) __COUNT_ARGS(, ##X, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0)
#define IS_ENABLED(config) config
#define CONFIG_SECURITY 1
"""


class TestReserveLsmSlot(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory()
        self.addCleanup(workspace.cleanup)
        self.kernel = Path(workspace.name)
        self.header = self.kernel / "include/linux/lsm_count.h"
        self.header.parent.mkdir(parents=True)
        self.header.write_text(HEADER, encoding="utf-8")
        self.security = self.kernel / "security/security.c"
        self.security.parent.mkdir()
        self.security.write_text('panic("Too many LSMs registered");\n', encoding="utf-8")

    @unittest.skipUnless(shutil.which("cc"), "C preprocessor required")
    def test_conditional_kernelsu_and_bbg_counts(self):
        for name in ("KSU", "BBG"):
            reserve_slot(self.kernel, name)
        header = self.header.read_text(encoding="utf-8")
        for ksu, bbg, expected in ((0, 0, 5), (1, 0, 6), (0, 1, 6), (1, 1, 7)):
            with self.subTest(ksu=ksu, bbg=bbg):
                source = f"{PREAMBLE}#define CONFIG_KSU {ksu}\n#define CONFIG_BBG {bbg}\n"
                result = subprocess.run(
                    ["cc", "-E", "-P", "-x", "c", "-"],
                    input=source + header + "MAX_LSM_COUNT\n",
                    encoding="utf-8",
                    capture_output=True,
                    check=True,
                )
                self.assertEqual(result.stdout.strip(), str(expected))

    def test_reservations_are_idempotent(self):
        for name in ("BBG", "KSU"):
            reserve_slot(self.kernel, name)
        written = self.header.read_bytes()
        for name in ("BBG", "KSU"):
            self.assertIn("already reserved", reserve_slot(self.kernel, name))
        self.assertEqual(written, self.header.read_bytes())

    def test_disabled_security_guard_skips_old_kernel(self):
        self.security.write_text("/* old hook lists */\n", encoding="utf-8")
        self.header.unlink()
        self.assertIn("skipping", reserve_slot(self.kernel, "BBG"))

    def test_missing_header_with_guard_fails(self):
        self.header.unlink()
        with self.assertRaises(FileNotFoundError):
            reserve_slot(self.kernel, "BBG")

    def test_missing_count_macro_fails_without_writing(self):
        self.header.write_text("#define MAX_LSM_COUNT 0\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "MAX_LSM_COUNT"):
            reserve_slot(self.kernel, "BBG")
        self.assertEqual(self.header.read_text(encoding="utf-8"), "#define MAX_LSM_COUNT 0\n")

    def test_partial_reservation_fails_without_writing(self):
        source = "#define BBG_ENABLED 1,\n" + HEADER
        self.header.write_text(source, encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "inconsistent existing BBG_ENABLED"):
            reserve_slot(self.kernel, "BBG")
        self.assertEqual(self.header.read_text(encoding="utf-8"), source)


if __name__ == "__main__":
    unittest.main()
