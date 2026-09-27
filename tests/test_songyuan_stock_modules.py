import ast
import copy
import gzip
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("trust", REPO / "scripts/songyuan_stock_modules.py")
trust = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trust)

MACRO = '''def common_kernel(
        name,
        outs = None):
    """Minimal representative Kleaf wrapper."""
    kernel_build(
        name = name,
        outs = outs,
    )
'''
BUILD = '''common_kernel(
    name = "kernel_aarch64",
    protected_module_names_list = ":protected",
    outs = [],
)

common_kernel(
    name = "kernel_aarch64_16k",
    protected_module_names_list = ":protected",
    outs = [],
)
'''
AK = "\n".join([
    "do.devicecheck=0", "do.modules=0", "device.name1=", "device.name2=",
    "device.name3=", "device.name4=", "device.name5=", "block=boot", "is_slot_device=auto", "",
])


def synthetic_image(overrides=None, certificate=True):
    """A small parser fixture, NOT a runnable kernel or a build success test."""
    config = {k: "y" for k in (
        "CONFIG_KSU", "CONFIG_MODVERSIONS", "CONFIG_MODULE_SIG", "CONFIG_MODULE_SIG_ALL",
        "CONFIG_MODULE_SIG_PROTECT", "CONFIG_SYSTEM_TRUSTED_KEYRING", "CONFIG_ARM64_4K_PAGES")}
    config.update({"CONFIG_SYSTEM_TRUSTED_KEYS": f'"{trust.CERT_BASENAME}"',
                   "CONFIG_MODULE_SIG_PROTECT_LIST": '"protected_module_names_list"',
                   "CONFIG_RFKILL": "m", "CONFIG_ZRAM": "m"})
    config.update(overrides or {})
    cfg = "\n".join(f"{k}={v}" for k, v in config.items()) + "\n"
    der = trust.checked_certificate()[1] if certificate else b""
    return (bytes(56) + b"ARM\x64" + b"\0Linux version " + trust.RELEASE.encode() + b" (test)\0"
            + der + b"IKCFG_ST" + gzip.compress(cfg.encode(), mtime=0) + b"IKCFG_ED")


class CertificateAndInputsTest(unittest.TestCase):
    def test_certificate_is_the_pinned_public_certificate(self):
        pem, der = trust.checked_certificate()
        self.assertNotIn("PRIVATE KEY", pem)
        self.assertEqual(len(der), 1357)

    def test_tampered_certificate_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bad.pem"
            path.write_text("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n")
            with self.assertRaisesRegex(ValueError, "fingerprint"):
                trust.checked_certificate(path)

    def test_private_key_in_bundle_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bad.pem"
            path.write_text(trust.CERT_PATH.read_text() + "-----BEGIN PRIVATE KEY-----\nAAAA\n")
            with self.assertRaisesRegex(ValueError, "public certificate"):
                trust.checked_certificate(path)

    def test_exact_baseline_inputs(self):
        trust.validate_inputs(trust.BASE_INPUTS, f"custom=true\nsukisu={trust.KSU_COMMIT}\n")

    def test_wrong_version_profile_or_changed_features_rejected(self):
        for key, value in (("sub_level", "92"), ("android_version", "android15"),
                           ("stock_gki_profile", "another-device"), ("use_zram", True),
                           ("use_bbg", True), ("enable_susfs", True), ("use_rekernel", True)):
            with self.subTest(key=key):
                inputs = copy.deepcopy(trust.BASE_INPUTS)
                inputs[key] = value
                with self.assertRaises(ValueError):
                    trust.validate_inputs(inputs, f"custom=true\nsukisu={trust.KSU_COMMIT}\n")

    def test_unpinned_ksu_rejected(self):
        with self.assertRaisesRegex(ValueError, "SukiSU"):
            trust.validate_inputs(trust.BASE_INPUTS, "custom=false\nsukisu=\n")


class SourceEditsTest(unittest.TestCase):
    def test_kleaf_forwards_key_without_changing_other_defaults(self):
        result = trust.patch_kleaf(MACRO)
        fn = trust.common_function(result)
        self.assertEqual(fn.args.args[-1].arg, "system_trusted_key")
        self.assertIsNone(fn.args.defaults[-1].value)
        call = trust.named_calls(fn, "kernel_build")[0]
        key = next(k for k in call.keywords if k.arg == "system_trusted_key")
        self.assertEqual(key.value.id, "system_trusted_key")
        self.assertEqual(trust.patch_kleaf(result), result)

    def test_only_four_k_target_gets_certificate(self):
        result = trust.patch_build(BUILD)
        calls = trust.named_calls(ast.parse(result), "common_kernel")
        self.assertEqual(sum(k.arg == "system_trusted_key" for c in calls for k in c.keywords), 1)
        self.assertEqual(len(calls[1].keywords), 3)
        self.assertEqual(trust.patch_build(result), result)
        self.assertEqual(result.count("protected_module_names_list"), 2)

    def test_existing_different_trusted_key_rejected(self):
        altered = BUILD.replace('    name = "kernel_aarch64",',
            '    name = "kernel_aarch64",\n    system_trusted_key = "other.pem",')
        with self.assertRaisesRegex(ValueError, "existing system_trusted_key"):
            trust.patch_build(altered)

    def test_unknown_layout_and_missing_protection_rejected(self):
        for source in ("", BUILD + BUILD,
                       BUILD.replace('    protected_module_names_list = ":protected",\n', "")):
            with self.subTest(source=source[:20]), self.assertRaises(ValueError):
                trust.patch_build(source)

    def test_prepare_is_idempotent_and_preserves_backups(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            common = root / "common"
            kleaf = root / "build/kernel/kleaf"
            (common / "certs").mkdir(parents=True)
            (kleaf / "impl").mkdir(parents=True)
            (common / "Makefile").write_text("VERSION = 6\nPATCHLEVEL = 12\nSUBLEVEL = 69\n")
            (common / "BUILD.bazel").write_text(BUILD)
            (kleaf / "common_kernels.bzl").write_text(MACRO)
            (kleaf / "impl/kernel_build.bzl").write_text("system_trusted_key = None\n")
            ak = root / "anykernel.sh"
            ak.write_text(AK)
            with patch.object(trust.subprocess, "check_output",
                              side_effect=[trust.ACK_COMMIT, trust.KSU_COMMIT] * 2):
                trust.prepare(root, ak)
                first = (common / "BUILD.bazel").read_bytes()
                trust.prepare(root, ak)
                self.assertEqual(first, (common / "BUILD.bazel").read_bytes())
            self.assertEqual((root / ".songyuan-stock-module-trust/common-BUILD.bazel").read_text(), BUILD)
            self.assertEqual((common / "certs" / trust.CERT_BASENAME).read_text(), trust.CERT_PATH.read_text())
            self.assertEqual(ak.read_text(), trust.guard_anykernel(AK))

    def test_wrong_ack_rejected_before_editing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.object(trust.subprocess, "check_output", return_value="b18aa09ef8e7\n"):
                with self.assertRaisesRegex(ValueError, "Wrong ACK"):
                    trust.prepare(root, root / "anykernel.sh")
            self.assertEqual(list(root.iterdir()), [])

    def test_setup_fallback_to_wrong_ksu_rejected_before_editing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.object(trust.subprocess, "check_output",
                              side_effect=[trust.ACK_COMMIT, "another-ksu-commit"]):
                with self.assertRaisesRegex(ValueError, "Wrong SukiSU"):
                    trust.prepare(root, root / "anykernel.sh")
            self.assertEqual(list(root.iterdir()), [])


class ArtifactChecksTest(unittest.TestCase):
    def test_synthetic_image_passes_without_claiming_runtime_test(self):
        report = trust.verify_image(synthetic_image())
        self.assertTrue(report["stock_certificate_embedded"])
        self.assertFalse(report["runtime_wifi_and_mobile_data_tested"])

    def test_missing_certificate_rejected(self):
        with self.assertRaisesRegex(ValueError, "NOT embedded"):
            trust.verify_image(synthetic_image(certificate=False))

    def test_security_disabling_and_wrong_config_rejected(self):
        for key, value in (("CONFIG_MODVERSIONS", "n"), ("CONFIG_MODULE_SIG", "n"),
                           ("CONFIG_MODULE_SIG_PROTECT", "n"), ("CONFIG_KSU", "n"),
                           ("CONFIG_SYSTEM_TRUSTED_KEYS", '""'),
                           ("CONFIG_MODULE_SIG_PROTECT_LIST", '""'),
                           ("CONFIG_RFKILL", "y"), ("CONFIG_ZRAM", "y")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                trust.verify_image(synthetic_image({key: value}))

    def test_non_arm64_image_rejected(self):
        with self.assertRaisesRegex(ValueError, "ARM64"):
            trust.verify_image(b"not a kernel")

    def test_anykernel_guard_is_idempotent(self):
        guarded = trust.guard_anykernel(AK)
        self.assertIn("do.devicecheck=1\n", guarded)
        self.assertIn("device.name1=songyuan\n", guarded)
        self.assertIn("block=boot\n", guarded)
        self.assertEqual(trust.guard_anykernel(guarded), guarded)

    def test_unsafe_anykernel_templates_rejected(self):
        for source in (AK.replace("block=boot", "block=auto"),
                       AK.replace("block=boot", "block=init_boot"),
                       AK.replace("do.modules=0", "do.modules=1"),
                       AK.replace("device.name2=", "device.name2=another-device"),
                       AK + "block=boot\n"):
            with self.subTest(source=source[-40:]), self.assertRaises(ValueError):
                trust.guard_anykernel(source)

    @unittest.skipUnless(os.getenv("SONGYUAN_BAD_ZIP"), "optional real failure artifact")
    def test_real_broken_package_fails_gate(self):
        with zipfile.ZipFile(os.environ["SONGYUAN_BAD_ZIP"]) as package:
            with self.assertRaisesRegex(ValueError, "NOT embedded"):
                trust.verify_image(package.read("Image"))


class WorkflowTest(unittest.TestCase):
    def test_dedicated_workflow_matches_known_inputs_and_opt_in(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML needed for workflow integration check")
        workflow = yaml.safe_load((REPO / ".github/workflows/songyuan-6.12-stock-trust.yml").read_text())
        inputs = workflow["jobs"]["build-songyuan"]["with"]
        trust.validate_inputs(inputs, (REPO / "config/config").read_text())
        reusable = yaml.safe_load((REPO / ".github/workflows/build.yml").read_text())
        # PyYAML's YAML 1.1 resolver interprets the unquoted GHA key 'on' as True.
        trigger = reusable.get("on", reusable.get(True))
        declared = trigger["workflow_call"]["inputs"]
        self.assertEqual(declared["stock_gki_profile"]["default"], "")
        self.assertLessEqual(inputs.keys(), declared.keys())
        self.assertTrue(all(k in inputs for k, v in declared.items() if v.get("required")))
        steps = reusable["jobs"]["build-kernel"]["steps"]
        commands = [s.get("run", "") for s in steps]
        before = next(i for i, c in enumerate(commands) if "songyuan_stock_modules.py prepare" in c)
        compile_idx = next(i for i, s in enumerate(steps) if s.get("id") == "compile_kernel")
        after = next(i for i, c in enumerate(commands) if "songyuan_stock_modules.py verify" in c)
        upload = next(i for i, s in enumerate(steps) if s["name"] == "上传 AnyKernel3 刷入包")
        self.assertLess(before, compile_idx)
        self.assertLess(compile_idx, after)
        self.assertLess(after, upload)
        for i in (before, after):
            self.assertEqual(steps[i]["if"], "inputs.stock_gki_profile != ''")
        if os.name == "posix":
            for step in steps:
                if step.get("if") == "inputs.stock_gki_profile != ''" and "run" in step:
                    subprocess.run(["bash", "-n"], input=step["run"], text=True,
                                   capture_output=True, check=True)

    @unittest.skipUnless(os.getenv("SONGYUAN_KERNEL_ROOT"), "optional real ACK/Kleaf checkout")
    def test_actual_ack_and_kleaf_source_layout(self):
        root = Path(os.environ["SONGYUAN_KERNEL_ROOT"])
        actual = subprocess.check_output(["git", "-C", str(root / "common"), "show",
                                          trust.ACK_COMMIT + ":BUILD.bazel"], text=True)
        patched = trust.patch_build(actual)
        self.assertEqual(trust.patch_build(patched), patched)
        actual_macro = (root / "build/kernel/kleaf/common_kernels.bzl").read_text()
        patched_macro = trust.patch_kleaf(actual_macro)
        self.assertEqual(trust.patch_kleaf(patched_macro), patched_macro)
        ast.parse(patched)
        ast.parse(patched_macro)


if __name__ == "__main__":
    unittest.main()
