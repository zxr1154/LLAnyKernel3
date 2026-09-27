#!/usr/bin/env python3
"""Opt-in stock GKI certificate integration for songyuan OS4.0.0.10 only.

Preserves module signatures, protected exports and MODVERSIONS. No private
key is included, no module is re-signed, and no device is accessed.
"""
import argparse
import ast
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

PROFILE = "songyuan-os4.0.0.10"
ACK_COMMIT = "5db86224e3c427ca56cb943d55a31e39eb7e22f2"
KSU_COMMIT = "cf87e3f4ddd3f6e5464d85acf56aaa6950e70841"
CERT_SHA256 = "70ab438b9b156f333e60643318ca552da661f478614d2b9efee21c1ed7c8e56f"
CERT_BASENAME = "songyuan-stock-gki.pem"
REPO_ROOT = Path(__file__).resolve().parents[1]
CERT_PATH = REPO_ROOT / "certs/songyuan-os4.0.0.10-gki.pem"
RELEASE = "6.12.69-android16-6-g014ca48a80ee-ab15889839-4k"
BASE_INPUTS = {
    "android_version": "android16", "kernel_version": "6.12", "sub_level": "69",
    "os_patch_level": "2026-03", "ksu_variant": "SukiSU", "version": RELEASE,
    "build_time": "Fri Jul 17 18:06:00 UTC 2026",
    "use_zram": False, "use_bbg": False, "use_net_enhance": True,
    "use_kpm": "disabled (关闭)", "use_rekernel": False, "enable_susfs": False,
    "supp_op": True, "droidspaces": "off", "droidspaces_ntsync": False,
    "cve_2026_43499_patch": False, "skip_incompatible": False,
    "artifact_upload_mode": "仅上传 AnyKernel3.zip", "stock_gki_profile": PROFILE,
}


def checked_certificate(path=CERT_PATH):
    pem = path.read_text(encoding="ascii")
    match = re.fullmatch(r"\s*-----BEGIN CERTIFICATE-----\s+([A-Za-z0-9+/=\s]+)"
                         r"-----END CERTIFICATE-----\s*", pem)
    if not match:
        raise ValueError("Expected exactly one public certificate, without a private key")
    der = base64.b64decode("".join(match[1].split()), validate=True)
    if hashlib.sha256(der).hexdigest() != CERT_SHA256:
        raise ValueError("Stock certificate fingerprint mismatch")
    return pem, der


def validate_inputs(inputs, config_text):
    for key, expected in BASE_INPUTS.items():
        if inputs.get(key) != expected:
            raise ValueError(f"{PROFILE} requires {key}={expected!r}, got {inputs.get(key)!r}")
    config = dict(re.findall(r"^([a-z_]+)=(.*)$", config_text, re.M))
    if config.get("custom", "").strip() != "true" or config.get("sukisu", "").strip() != KSU_COMMIT:
        raise ValueError("config/config must pin the SukiSU commit of the known bootable build")
    checked_certificate()


def only(nodes, description):
    nodes = list(nodes)
    if len(nodes) != 1:
        raise ValueError(f"Expected exactly one {description}, found {len(nodes)}")
    return nodes[0]


def common_function(source):
    return only((n for n in ast.parse(source).body
                 if isinstance(n, ast.FunctionDef) and n.name == "common_kernel"), "common_kernel macro")


def named_calls(tree, name):
    return [n for n in ast.walk(tree) if isinstance(n, ast.Call)
            and isinstance(n.func, ast.Name) and n.func.id == name]


def add_keyword(source, node, key, expression):
    present = [k for k in node.keywords if k.arg == key]
    if present:
        wanted = ast.parse(expression, mode="eval").body
        if len(present) != 1 or ast.dump(present[0].value) != ast.dump(wanted):
            raise ValueError(f"Refusing to replace an existing {key}")
        return source
    lines = source.splitlines(keepends=True)
    close = node.end_lineno - 1
    if lines[close].strip() != ")" or node.lineno == node.end_lineno:
        raise ValueError("Unsupported Starlark call layout; refusing a guessed edit")
    indent = re.match(r" *", lines[close])[0] + "    "
    lines.insert(close, f"{indent}{key} = {expression},\n")
    result = "".join(lines)
    ast.parse(result)
    return result


def patch_kleaf(source):
    fn = common_function(source)
    # kernel_build already supports this attribute; the common_kernel wrapper
    # in android16-6.12 must expose it. Default None keeps other targets unchanged.
    if "system_trusted_key" not in [a.arg for a in fn.args.args]:
        lines = source.splitlines(keepends=True)
        header = "".join(lines[fn.lineno - 1:fn.body[0].lineno - 1])
        if not header.rstrip().endswith("):"):
            raise ValueError("Unsupported common_kernel parameter layout")
        prefix = header.rstrip()[:-2].rstrip()
        if not prefix.endswith(","):
            prefix += ","
        header = prefix + "\n        system_trusted_key = None):\n"
        source = "".join(lines[:fn.lineno - 1]) + header + "".join(lines[fn.body[0].lineno - 1:])
    fn = common_function(source)
    build = only(named_calls(fn, "kernel_build"), "kernel_build call in common_kernel")
    return add_keyword(source, build, "system_trusted_key", "system_trusted_key")


def patch_build(source):
    calls = named_calls(ast.parse(source), "common_kernel")
    target = only((c for c in calls if any(k.arg == "name" and
        isinstance(k.value, ast.Constant) and k.value.value == "kernel_aarch64"
        for k in c.keywords)), "kernel_aarch64 common_kernel target")
    protected = [k for k in target.keywords if k.arg == "protected_module_names_list"]
    if len(protected) != 1 or not isinstance(protected[0].value, ast.Constant) or not protected[0].value.value:
        raise ValueError("Protected GKI module list is missing; refusing to weaken module protection")
    return add_keyword(source, target, "system_trusted_key", repr(f"certs/{CERT_BASENAME}"))


def guard_anykernel(source):
    required = ["block", "is_slot_device", "do.devicecheck", "do.modules", "device.name1",
                "device.name2", "device.name3", "device.name4", "device.name5"]
    values = {}
    for key in required:
        values[key] = only(re.findall(r"^" + re.escape(key) + r"=(.*)$", source, re.M), key).strip()
    if values["block"] != "boot" or values["is_slot_device"] != "auto" or values["do.modules"] != "0":
        raise ValueError("Expected a boot-only A/B AnyKernel3 template without module replacement")
    if values["device.name1"] not in ("", "songyuan") or any(values[f"device.name{i}"] for i in range(2, 6)):
        raise ValueError("AnyKernel3 template already targets a different device")
    source = re.sub(r"^do\.devicecheck=.*$", "do.devicecheck=1", source, flags=re.M)
    return re.sub(r"^device\.name1=.*$", "device.name1=songyuan", source, flags=re.M)


def prepare(kernel_root, anykernel):
    kernel_root = kernel_root.resolve()
    common = kernel_root / "common"
    head = subprocess.check_output(["git", "-C", str(common), "rev-parse", "HEAD"], text=True).strip()
    if head != ACK_COMMIT:
        raise ValueError(f"Wrong ACK commit: {head}; expected {ACK_COMMIT}")
    ksu = subprocess.check_output(
        ["git", "-C", str(kernel_root / "KernelSU"), "rev-parse", "HEAD"], text=True).strip()
    if ksu != KSU_COMMIT:
        raise ValueError(f"Wrong SukiSU commit: {ksu}; expected {KSU_COMMIT}")
    makefile = (common / "Makefile").read_text()
    for key, value in (("VERSION", "6"), ("PATCHLEVEL", "12"), ("SUBLEVEL", "69")):
        if re.findall(r"^" + key + r"\s*=\s*(\S+)\s*$", makefile, re.M) != [value]:
            raise ValueError("Expected kernel 6.12.69")
    pem, _ = checked_certificate()
    cert = common / "certs" / CERT_BASENAME
    if cert.exists() and cert.read_text(encoding="ascii") != pem:
        raise ValueError("Refusing to overwrite a different certificate")
    backend = kernel_root / "build/kernel/kleaf/impl/kernel_build.bzl"
    if "system_trusted_key" not in backend.read_text():
        raise ValueError("Kleaf kernel_build does not support system_trusted_key")
    build = common / "BUILD.bazel"
    kleaf = kernel_root / "build/kernel/kleaf/common_kernels.bzl"
    # Validate all edits before writing any file. Existing settings are not replaced.
    edits = [(build, patch_build(build.read_text()), "common-BUILD.bazel"),
             (kleaf, patch_kleaf(kleaf.read_text()), "common_kernels.bzl"),
             (anykernel, guard_anykernel(anykernel.read_text()), "anykernel.sh")]
    backup = kernel_root / ".songyuan-stock-module-trust"
    backup.mkdir(exist_ok=True)
    for path, updated, name in edits:
        if path.read_text() == updated:
            continue
        saved = backup / name
        if not saved.exists():
            saved.write_bytes(path.read_bytes())
        path.write_text(updated, encoding="utf-8", newline="\n")
    cert.write_text(pem, encoding="ascii", newline="\n")
    print(f"Added stock public certificate via Kleaf system_trusted_key: {CERT_SHA256}")
    print(f"Module-signing key, MODVERSIONS and protected module list are unchanged. Backup: {backup}")


def embedded_config(image):
    start = image.index(b"IKCFG_ST") + 8
    end = image.index(b"IKCFG_ED", start)
    return dict(re.findall(r"^(CONFIG_[A-Z0-9_]+)=(.*)$",
                          gzip.decompress(image[start:end]).decode(), re.M))


def verify_image(image):
    _, der = checked_certificate()
    if image[56:60] != b"ARM\x64":
        raise ValueError("Expected an uncompressed ARM64 Image")
    if der not in image:
        raise ValueError("Stock GKI certificate is NOT embedded in the final Image")
    cfg = embedded_config(image)
    for key in ("CONFIG_KSU", "CONFIG_MODVERSIONS", "CONFIG_MODULE_SIG", "CONFIG_MODULE_SIG_ALL",
                "CONFIG_MODULE_SIG_PROTECT", "CONFIG_SYSTEM_TRUSTED_KEYRING", "CONFIG_ARM64_4K_PAGES"):
        if cfg.get(key) != "y":
            raise ValueError(f"Required security/build configuration missing: {key}=y")
    if cfg.get("CONFIG_SYSTEM_TRUSTED_KEYS") != f'"{CERT_BASENAME}"':
        raise ValueError("Kleaf did not select the expected trusted certificate")
    if cfg.get("CONFIG_MODULE_SIG_PROTECT_LIST", '""') == '""':
        raise ValueError("Protected module list is empty")
    if cfg.get("CONFIG_RFKILL") != "m" or cfg.get("CONFIG_ZRAM") != "m":
        raise ValueError("Stock RFKILL/ZRAM module configuration changed")
    if b"Linux version " + RELEASE.encode() + b" " not in image:
        raise ValueError("Unexpected kernel release")
    return {"profile": PROFILE, "expected_ack_commit": ACK_COMMIT, "expected_sukisu_commit": KSU_COMMIT,
            "image_sha256": hashlib.sha256(image).hexdigest(),
            "stock_certificate_der_sha256": CERT_SHA256, "stock_certificate_embedded": True,
            "module_signature_protection": True, "modversions": True,
            "runtime_wifi_and_mobile_data_tested": False}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    sub.add_parser("validate-inputs")
    p = sub.add_parser("prepare")
    p.add_argument("--kernel-root", required=True, type=Path)
    p.add_argument("--anykernel", required=True, type=Path)
    v = sub.add_parser("verify")
    v.add_argument("--image", required=True, type=Path)
    v.add_argument("--anykernel", required=True, type=Path)
    v.add_argument("--report", required=True, type=Path)
    args = ap.parse_args()
    if args.command == "validate-inputs":
        validate_inputs(json.loads(os.environ["BUILD_INPUTS"]), (REPO_ROOT / "config/config").read_text())
        print("songyuan build inputs and stock certificate validated")
    elif args.command == "prepare":
        prepare(args.kernel_root, args.anykernel)
    else:
        ak = args.anykernel.read_text()
        if guard_anykernel(ak) != ak:
            raise ValueError("AnyKernel3 songyuan device guard was not applied")
        report = verify_image(args.image.read_bytes())
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, SyntaxError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
