#!/usr/bin/env python3
"""Add LZ4K / LZ4KD / LZ4K_OPLUS to a Linux 6.12 zram module.

The codecs are linked into zram.ko. CONFIG_ZRAM and CONFIG_ZSMALLOC stay
modular, and modules.bzl is not edited, so the GKI module list still
ships drivers/block/zram/zram.ko and mm/zsmalloc.ko.

Usage:
  apply.py --kernel-root common --patches SukiSU_patch [--defconfig path]
"""

import argparse
import re
import shutil
import sys
from pathlib import Path

MARKER = "LLANY_ZRAM612"
SCRIPT_DIR = Path(__file__).resolve().parent

BACKENDS = (
    ("LZ4K", "backend_lz4k", "lz4k"),
    ("LZ4KD", "backend_lz4kd", "lz4kd"),
    ("LZ4K_OPLUS", "backend_lz4k_oplus", "lz4k_oplus"),
)

CODEC_OBJECTS = {
    "LZ4K": [
        "lz4k_embed/huawei/lz4k/lz4k_encode.o",
        "lz4k_embed/huawei/lz4k/lz4k_decode.o",
    ],
    "LZ4KD": [
        "lz4k_embed/huawei/lz4kd/lz4kd_encode.o",
        "lz4k_embed/huawei/lz4kd/lz4kd_encode_delta.o",
        "lz4k_embed/huawei/lz4kd/lz4kd_decode.o",
        "lz4k_embed/huawei/lz4kd/lz4kd_decode_delta.o",
    ],
    "LZ4K_OPLUS": [
        "lz4k_embed/oplus/lz4k_compress.o",
        "lz4k_embed/oplus/lz4k_decompress.o",
    ],
}

DELTA_OBJECTS = [
    "lz4k_embed/huawei/lz4kd/lz4kd_encode.o",
    "lz4k_embed/huawei/lz4kd/lz4kd_encode_delta.o",
    "lz4k_embed/huawei/lz4kd/lz4kd_decode.o",
    "lz4k_embed/huawei/lz4kd/lz4kd_decode_delta.o",
]

# 只增加后端。原厂 6.12.69 的默认算法是 lzo-rle，不能改成 lz4kd。
FRAGMENT = """CONFIG_ZRAM_BACKEND_LZ4K=y
CONFIG_ZRAM_BACKEND_LZ4KD=y
CONFIG_ZRAM_BACKEND_LZ4K_OPLUS=y
CONFIG_ARM64_4K_PAGES=y
"""


def die(msg):
    print("::error::%s" % msg, file=sys.stderr)
    raise SystemExit(1)


def read(path):
    return path.read_text(encoding="utf-8", errors="surrogateescape")


def write(path, text):
    path.write_text(text, encoding="utf-8", errors="surrogateescape")


def strip_module_lines(text):
    kept = []
    for line in text.splitlines(keepends=True):
        if re.match(r"^\s*(MODULE_[A-Z0-9_]+|module_init|module_exit|EXPORT_SYMBOL)\b", line):
            continue
        kept.append(line)
    return "".join(kept)


def copy_codec(src, dst):
    dst.mkdir(parents=True, exist_ok=True)
    for path in src.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix not in {".c", ".h"}:
            continue
        rel = path.relative_to(src)
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        data = path.read_text(encoding="utf-8", errors="surrogateescape")
        if path.suffix == ".c":
            data = strip_module_lines(data)
        write(target, data)


def ensure_sources(kernel, patches):
    zram = kernel / "drivers/block/zram"
    for name in ("zcomp.c", "Kconfig", "Makefile"):
        if not (zram / name).is_file():
            die("6.12 zram tree is missing %s" % (zram / name))
    huawei = patches / "other/zram/lz4k"
    oplus = patches / "other/zram/lz4k_oplus"
    for need in (
        huawei / "include/linux/lz4k.h",
        huawei / "include/linux/lz4kd.h",
        huawei / "lib/lz4k/lz4k_encode.c",
        huawei / "lib/lz4k/lz4k_decode.c",
        huawei / "lib/lz4kd/lz4kd_encode.c",
        huawei / "lib/lz4kd/lz4kd_decode.c",
        oplus / "lz4k.h",
        oplus / "lz4k_compress.c",
        oplus / "lz4k_decompress.c",
    ):
        if not need.is_file():
            die("ZRAM codec source missing: %s" % need)

    inc = kernel / "include/linux"
    inc.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(huawei / "include/linux/lz4k.h", inc / "lz4k.h")
    shutil.copyfile(huawei / "include/linux/lz4kd.h", inc / "lz4kd.h")
    copy_codec(huawei / "lib/lz4k", zram / "lz4k_embed/huawei/lz4k")
    copy_codec(huawei / "lib/lz4kd", zram / "lz4k_embed/huawei/lz4kd")
    copy_codec(oplus, zram / "lz4k_embed/oplus")
    # The oplus crypto wrapper is its own module. The backend calls
    # lz4k_compress/lz4k_decompress directly.
    wrapper = zram / "lz4k_embed/oplus/lz4k.c"
    if wrapper.exists():
        wrapper.unlink()
    for name in (
        "backend_lz4k.c",
        "backend_lz4k.h",
        "backend_lz4kd.c",
        "backend_lz4kd.h",
        "backend_lz4k_oplus.c",
        "backend_lz4k_oplus.h",
    ):
        shutil.copyfile(SCRIPT_DIR / name, zram / name)


def patch_kconfig(path):
    text = read(path)
    if MARKER in text:
        return
    if "config ZRAM_BACKEND_FORCE_LZO" not in text or "config ZRAM_DEF_COMP\n" not in text:
        die("zram Kconfig does not look like the 6.12 backend menu")
    block = (
        "config ZRAM_BACKEND_LZ4K\n"
        '\tbool "lz4k compression support"\n'
        "\tdepends on ZRAM\n\n"
        "config ZRAM_BACKEND_LZ4KD\n"
        '\tbool "lz4kd compression support"\n'
        "\tdepends on ZRAM\n\n"
        "config ZRAM_BACKEND_LZ4K_OPLUS\n"
        '\tbool "lz4k_oplus compression support"\n'
        "\tdepends on ZRAM\n\n"
        "# %s backends\n" % MARKER
    )
    text = text.replace("config ZRAM_BACKEND_FORCE_LZO\n", block + "config ZRAM_BACKEND_FORCE_LZO\n", 1)
    old_force = (
        "\tdef_bool !ZRAM_BACKEND_LZ4 && !ZRAM_BACKEND_LZ4HC && \\\n"
        "\t\t!ZRAM_BACKEND_ZSTD && !ZRAM_BACKEND_DEFLATE && \\\n"
        "\t\t!ZRAM_BACKEND_842\n"
    )
    new_force = (
        "\tdef_bool !ZRAM_BACKEND_LZ4 && !ZRAM_BACKEND_LZ4HC && \\\n"
        "\t\t!ZRAM_BACKEND_ZSTD && !ZRAM_BACKEND_DEFLATE && \\\n"
        "\t\t!ZRAM_BACKEND_842 && !ZRAM_BACKEND_LZ4K && \\\n"
        "\t\t!ZRAM_BACKEND_LZ4KD && !ZRAM_BACKEND_LZ4K_OPLUS\n"
    )
    if old_force not in text:
        die("ZRAM_BACKEND_FORCE_LZO expression changed; refusing to guess")
    text = text.replace(old_force, new_force, 1)
    choice = (
        "config ZRAM_DEF_COMP_LZ4K\n"
        '\tbool "lz4k"\n'
        "\tdepends on ZRAM_BACKEND_LZ4K\n\n"
        "config ZRAM_DEF_COMP_LZ4KD\n"
        '\tbool "lz4kd"\n'
        "\tdepends on ZRAM_BACKEND_LZ4KD\n\n"
        "config ZRAM_DEF_COMP_LZ4K_OPLUS\n"
        '\tbool "lz4k_oplus"\n'
        "\tdepends on ZRAM_BACKEND_LZ4K_OPLUS\n\n"
        "endchoice\n"
    )
    if "\nendchoice\n" not in text:
        die("zram Kconfig has no compressor choice")
    text = text.replace("\nendchoice\n", "\n" + choice, 1)
    extra = (
        '\tdefault "lz4k" if ZRAM_DEF_COMP_LZ4K\n'
        '\tdefault "lz4kd" if ZRAM_DEF_COMP_LZ4KD\n'
        '\tdefault "lz4k_oplus" if ZRAM_DEF_COMP_LZ4K_OPLUS\n'
        '\tdefault "unset-value"\n'
    )
    if '\tdefault "unset-value"\n' not in text:
        die("zram Kconfig default compressor string changed")
    text = text.replace('\tdefault "unset-value"\n', extra, 1)
    write(path, text)


def patch_makefile(path):
    text = read(path)
    if MARKER in text:
        return
    anchor = "zram-$(CONFIG_ZRAM_BACKEND_842)\t\t+= backend_842.o\n"
    if anchor not in text:
        die("zram Makefile has no 842 backend anchor")
    lines = [anchor.rstrip("\n")]
    for cfg, backend, _name in BACKENDS:
        lines.append("zram-$(CONFIG_ZRAM_BACKEND_%s)\t\t+= %s.o" % (cfg, backend))
        for obj in CODEC_OBJECTS[cfg]:
            lines.append("zram-$(CONFIG_ZRAM_BACKEND_%s)\t\t+= %s" % (cfg, obj))
    for obj in DELTA_OBJECTS:
        lines.append("CFLAGS_%s += -DLZ4K_DELTA" % obj)
    lines.append("# %s objects stay inside zram.ko" % MARKER)
    text = text.replace(anchor, "\n".join(lines) + "\n", 1)
    write(path, text)


def patch_zcomp(path):
    text = read(path)
    if MARKER in text:
        return
    inc = '#include "backend_842.h"\n'
    if inc not in text:
        die("zcomp.c has no backend_842.h include")
    extra_inc = inc + "".join(
        '#include "%s.h"\n' % backend for _cfg, backend, _name in BACKENDS
    )
    text = text.replace(inc, extra_inc, 1)
    sentinel = "#endif\n\tNULL\n"
    # The 842 block ends with #endif then NULL.
    needle = "#if IS_ENABLED(CONFIG_ZRAM_BACKEND_842)\n\t&backend_842,\n#endif\n\tNULL\n"
    if needle not in text:
        die("zcomp.c backend table does not end with the 842 entry")
    extra = needle.replace("\tNULL\n", "")
    for _cfg, backend, _name in BACKENDS:
        cfg = _cfg
        extra += "#if IS_ENABLED(CONFIG_ZRAM_BACKEND_%s)\n\t&%s,\n#endif\n" % (cfg, backend)
    extra += "\tNULL\n\t/* %s */\n" % MARKER
    text = text.replace(needle, extra, 1)
    write(path, text)


def append_fragment(defconfig):
    current = read(defconfig) if defconfig.is_file() else ""
    if re.search(r"^CONFIG_ZRAM=y$", current, re.M):
        die("refusing to build ZRAM into vmlinux; vendor zram.ko must stay a module")
    if "zram.ko" in current and "drivers/block/zram/zram.ko" not in current:
        pass
    missing = []
    for line in FRAGMENT.splitlines():
        if not line or line.startswith("#"):
            key = line
        else:
            key = line
        if key not in current:
            missing.append(line)
    if missing:
        if current and not current.endswith("\n"):
            current += "\n"
        current += "\n".join(missing) + "\n"
        write(defconfig, current)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel-root", required=True)
    parser.add_argument("--patches", required=True)
    parser.add_argument("--defconfig")
    args = parser.parse_args()
    kernel = Path(args.kernel_root)
    patches = Path(args.patches)
    ensure_sources(kernel, patches)
    zram = kernel / "drivers/block/zram"
    patch_kconfig(zram / "Kconfig")
    patch_makefile(zram / "Makefile")
    patch_zcomp(zram / "zcomp.c")
    joined = read(zram / "Makefile") + read(zram / "Kconfig") + read(zram / "zcomp.c")
    for cfg, backend, name in BACKENDS:
        if "CONFIG_ZRAM_BACKEND_%s" % cfg not in joined or backend not in joined:
            die("backend %s was not wired" % name)
    if "CONFIG_ZRAM=y" in joined:
        die("adapter tried to builtin ZRAM")
    if args.defconfig:
        append_fragment(Path(args.defconfig))
        frag = read(Path(args.defconfig))
        if re.search(r"^CONFIG_ZRAM=y$", frag, re.M):
            die("defconfig fragment built ZRAM in")
        if "CONFIG_ARM64_16K_PAGES=y" in frag:
            die("defconfig requests 16K pages")
    print("6.12 ZRAM backends linked into zram.ko; zram.ko and zsmalloc.ko kept")


if __name__ == "__main__":
    main()
