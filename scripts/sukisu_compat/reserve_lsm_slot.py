#!/usr/bin/env python3
"""Reserve a slot for an additional LSM registered with security_add_hooks."""

import argparse
from pathlib import Path
import re


COUNT_START = re.compile(
    r"^#define[ \t]+MAX_LSM_COUNT[ \t]+\\\n[ \t]+COUNT_LSMS\([ \t]*\\\n",
    re.MULTILINE,
)
COUNT_ENTRIES = re.compile(
    r"(?:[ \t]*[A-Z][A-Z0-9_]*[ \t]*\\\n)+[ \t]*[A-Z][A-Z0-9_]*\)[ \t]*(?=\n|$)"
)


def reserve_slot(kernel: Path, feature: str) -> str:
    security = kernel / "security/security.c"
    if "Too many LSMs registered" not in security.read_text(encoding="utf-8"):
        return f"{feature}: no static-call LSM count guard, skipping"

    header = kernel / "include/linux/lsm_count.h"
    source = header.read_text(encoding="utf-8")
    count_starts = list(COUNT_START.finditer(source))
    if len(count_starts) != 1:
        raise ValueError(f"{header}: expected exactly one MAX_LSM_COUNT list")
    count = count_starts[0]
    entries = COUNT_ENTRIES.match(source, count.end())
    if entries is None:
        raise ValueError(f"{header}: unrecognized COUNT_LSMS layout")

    symbol = f"{feature}_ENABLED"
    condition = (
        f"#if IS_ENABLED(CONFIG_{feature})\n"
        f"#define {symbol} 1,\n"
        f"#else\n"
        f"#define {symbol}\n"
        f"#endif\n\n"
    )
    listed = re.findall(r"\b[A-Z][A-Z0-9_]*\b", entries.group())
    if re.search(rf"\b{symbol}\b", source):
        if listed.count(symbol) == 1 and condition in source[:count.start()]:
            return f"{header.name}: {feature} static-call LSM slot already reserved"
        raise ValueError(f"{header}: inconsistent existing {symbol} reservation")

    patched = (
        source[:count.start()]
        + condition
        + source[count.start():count.end()]
        + f"\t\t{symbol}\t\t\\\n"
        + source[count.end():]
    )
    header.write_text(patched, encoding="utf-8")
    return f"{header.name}: reserved one conditional static-call LSM slot for {feature}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", type=Path, help="kernel tree containing security/ and include/")
    parser.add_argument("feature", choices=("KSU", "BBG"))
    args = parser.parse_args()
    try:
        print(reserve_slot(args.kernel, args.feature))
    except (OSError, ValueError) as exc:
        parser.exit(1, f"LSM slot reservation failed: {exc}\n")


if __name__ == "__main__":
    main()
