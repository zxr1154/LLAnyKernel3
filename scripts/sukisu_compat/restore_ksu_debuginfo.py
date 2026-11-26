#!/usr/bin/env python3
"""去掉 SukiSU ksu.o 编译参数里的 -g0。

builtin-new 在 CONFIG_KSU_DEBUG 未打开时写入：

    CFLAGS_ksu.o += -g0 -fno-unwind-tables -fno-asynchronous-unwind-tables -fomit-frame-pointer

scripts/Makefile.lib 把 CFLAGS_ksu.o 放在 KBUILD_CFLAGS 之后。clang 采用最后
一个 -g 选项，所以 -g0 会盖掉 GKI 的 -g / -gdwarf-*。6.12 的
CONFIG_MODVERSIONS + CONFIG_GENDWARFKSYMS 在 scripts/Makefile.build 里对导出
了符号的 ksu.o 调用 gendwarfksyms，对象文件没有 DWARF 时失败：

    gendwarfksyms: process_module: dwarf_get_units failed: no debugging information?

CONFIG_KSU_DEBUG=y 会同时恢复日志、追踪和栈保护。这里只删除 -g0 这个词，
保留同一行上的其余裁剪选项。上游已经不再传 -g0 时文件保持原样。
"""

from __future__ import annotations

import pathlib
import re
import sys

MAKEFILES = ("kernel/Makefile", "kernel/Kbuild")
ASSIGN = re.compile(
    r"^(?P<indent>[ \t]*)(?P<var>CFLAGS_ksu\.o|ccflags-y)"
    r"(?P<op>[ \t]*(?:\+=|:=|\?=|=))"
    r"(?P<rest>.*)$"
)
G0 = "-g0"
NOTE = "gendwarfksyms 需要 ksu.o 的 DWARF，已去掉 -g0，其余裁剪选项保留。"


def _rewrite_line(line: str) -> tuple[str, int]:
    raw = line.rstrip("\r\n")
    ending = line[len(raw) :]
    if raw.lstrip().startswith("#"):
        return line, 0
    comment = ""
    code = raw
    for marker in (" #", "\t#"):
        at = raw.find(marker)
        if at != -1:
            code, comment = raw[:at], raw[at:]
            break
    match = ASSIGN.match(code)
    if match is None:
        return line, 0
    rest = match.group("rest")
    continued = rest.rstrip().endswith("\\")
    tokens = [token for token in rest.split() if token != "\\"]
    if G0 not in tokens:
        return line, 0
    kept = [token for token in tokens if token != G0]
    removed = len(tokens) - len(kept)
    if continued:
        kept.append("\\")
    indent = match.group("indent")
    var = match.group("var")
    op = match.group("op")
    if not kept:
        rewritten = f"{indent}# {NOTE}"
    elif kept == ["\\"]:
        rewritten = f"{indent}{var}{op} \\"
    else:
        rewritten = f"{indent}{var}{op} {' '.join(kept)}"
    return rewritten + comment + ending, removed


def strip_g0(text: str) -> tuple[str, int]:
    removed = 0
    out: list[str] = []
    for line in text.splitlines(keepends=True):
        rewritten, count = _rewrite_line(line)
        if count and not rewritten.lstrip().startswith("#"):
            previous = out[-1].strip() if out else ""
            if previous != f"# {NOTE}":
                ending = "\r\n" if line.endswith("\r\n") else "\n"
                out.append(f"# {NOTE}{ending}")
        removed += count
        out.append(rewritten)
    return "".join(out), removed


def lingering_g0(text: str) -> list[str]:
    found = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        code = line.split("#", 1)[0]
        match = ASSIGN.match(code)
        if match is None:
            continue
        tokens = [token for token in match.group("rest").split() if token != "\\"]
        if G0 in tokens:
            found.append(f"{lineno}:{line}")
    return found


def restore(ksu_dir: pathlib.Path) -> str:
    found = False
    messages = []
    for rel in MAKEFILES:
        path = ksu_dir / rel
        if not path.is_file():
            continue
        found = True
        original = path.read_text(encoding="utf-8")
        updated, removed = strip_g0(original)
        leftover = lingering_g0(updated)
        if leftover:
            raise SystemExit(
                f"{path} 仍含 -g0，无法安全删除:\n" + "\n".join(leftover)
            )
        if removed:
            path.write_text(updated, encoding="utf-8", newline="")
            messages.append(f"removed {removed} -g0 flag(s) from {path}")
        else:
            messages.append(f"no -g0 on ksu compile flags in {path}")
    if not found:
        raise SystemExit(f"no KernelSU Makefile/Kbuild under {ksu_dir}")
    return "; ".join(messages)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} KERNELSU_DIR", file=sys.stderr)
        return 2
    print(restore(pathlib.Path(argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
