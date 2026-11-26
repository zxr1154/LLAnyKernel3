#!/usr/bin/env python3
"""builtin-new 的 -g0 会让 gendwarfksyms 在 ksu.o 上报没有 DWARF。"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from restore_ksu_debuginfo import lingering_g0, restore, strip_g0


# builtin-new kernel/Makefile 在 d8aafb76 的非 CONFIG_KSU_DEBUG 片段。
UPSTREAM = """\
# CFLAGS_ksu.o += -mcpu=cortex-a76 -mtune=cortex-a76

ifneq ($(CONFIG_KSU_DEBUG),y)
# strip, remove tracing / profiling
# comment out if proper backtrace is needed
CFLAGS_ksu.o += -g0 -fno-unwind-tables -fno-asynchronous-unwind-tables -fomit-frame-pointer
CFLAGS_ksu.o += $(call cc-option, -momit-leaf-frame-pointer)

# no profiling
CFLAGS_REMOVE_ksu.o += $(CC_FLAGS_FTRACE)
CFLAGS_REMOVE_ksu.o += -pg

# no need for stack init
CFLAGS_REMOVE_ksu.o += -ftrivial-auto-var-init=pattern
CFLAGS_REMOVE_ksu.o += -ftrivial-auto-var-init=zero
CFLAGS_REMOVE_ksu.o += -enable-trivial-auto-var-init-zero-knowing-it-will-be-removed-from-clang

# if cflags can be macro'd, this will be called 'TRUST_ME'
CFLAGS_ksu.o += -fno-stack-protector -fno-stack-check
CFLAGS_REMOVE_ksu.o += -fsanitize=shadow-call-stack
endif # CONFIG_KSU_DEBUG
"""


class TestRestoreKsuDebuginfo(unittest.TestCase):
    def test_builtin_new_drops_only_g0(self):
        updated, removed = strip_g0(UPSTREAM)
        self.assertEqual(removed, 1)
        self.assertEqual(lingering_g0(updated), [])
        self.assertIn(
            "CFLAGS_ksu.o += -fno-unwind-tables "
            "-fno-asynchronous-unwind-tables -fomit-frame-pointer\n",
            updated,
        )
        self.assertIn("CFLAGS_ksu.o += -fno-stack-protector -fno-stack-check\n", updated)
        self.assertIn("CFLAGS_REMOVE_ksu.o += $(CC_FLAGS_FTRACE)\n", updated)
        self.assertIn("CFLAGS_REMOVE_ksu.o += -fsanitize=shadow-call-stack\n", updated)
        self.assertIn("ifneq ($(CONFIG_KSU_DEBUG),y)\n", updated)
        self.assertNotIn("CONFIG_KSU_DEBUG=y", updated)
        self.assertIn("# CFLAGS_ksu.o += -mcpu=cortex-a76 -mtune=cortex-a76\n", updated)
        self.assertNotIn("+= -g0", updated)
        again, removed_again = strip_g0(updated)
        self.assertEqual(removed_again, 0)
        self.assertEqual(again, updated)

    def test_other_assignments_and_comments_stay(self):
        text = "ccflags-y += -DKSU_VERSION=1\n# CFLAGS_ksu.o += -g0\n"
        updated, removed = strip_g0(text)
        self.assertEqual(removed, 0)
        self.assertEqual(updated, text)

    def test_ccflags_and_colon_assign(self):
        text = "ccflags-y := -O2 -g0 -Wall\nCFLAGS_ksu.o ?= -g0\n"
        updated, removed = strip_g0(text)
        self.assertEqual(removed, 2)
        self.assertIn("ccflags-y := -O2 -Wall\n", updated)
        self.assertNotIn("CFLAGS_ksu.o ?=", updated)
        self.assertEqual(lingering_g0(updated), [])

    def test_restore_is_idempotent_on_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            makefile = root / "kernel" / "Makefile"
            makefile.parent.mkdir()
            makefile.write_text(UPSTREAM, encoding="utf-8")
            first = restore(root)
            self.assertIn("removed 1", first)
            written = makefile.read_text(encoding="utf-8")
            second = restore(root)
            self.assertIn("no -g0", second)
            self.assertEqual(makefile.read_text(encoding="utf-8"), written)

    def test_kbuild_only_and_missing_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            kbuild = root / "kernel" / "Kbuild"
            kbuild.parent.mkdir()
            kbuild.write_text("CFLAGS_ksu.o += -g0 -O2\n", encoding="utf-8")
            self.assertIn("removed 1", restore(root))
            self.assertIn("CFLAGS_ksu.o += -O2\n", kbuild.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit):
                restore(Path(tmp))

    @unittest.skipUnless(shutil.which("clang") and shutil.which("readelf"), "clang and readelf required")
    def test_g0_removes_dwarf_and_remaining_flags_keep_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "ksu.c"
            source.write_text("int exported(void) { return 1; }\n", encoding="utf-8")
            stripped = Path(tmp) / "g0.o"
            kept = Path(tmp) / "kept.o"
            common = [
                "clang",
                "-c",
                "-g",
                "-gdwarf-4",
                "-O2",
                "-fno-unwind-tables",
                "-fno-asynchronous-unwind-tables",
                "-fomit-frame-pointer",
            ]
            subprocess.run([*common, "-g0", "-o", str(stripped), str(source)], check=True)
            subprocess.run([*common, "-o", str(kept), str(source)], check=True)
            self.assertNotIn(".debug_info", _sections(stripped))
            self.assertIn(".debug_info", _sections(kept))


def _sections(path: Path) -> str:
    result = subprocess.run(
        ["readelf", "-S", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


if __name__ == "__main__":
    unittest.main()
