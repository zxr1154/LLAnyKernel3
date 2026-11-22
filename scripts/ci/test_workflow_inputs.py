#!/usr/bin/env python3
"""Check GitHub Actions input limits and workflow_call routing.

workflow_dispatch accepts at most 25 inputs. Run 44971036128 failed at
startup, before any kernel job, because kernel-custom.yml had 26.
Reusable workflow_call workflows accept at most 255 inputs.
"""

import pathlib
import sys

import yaml

DISPATCH_LIMIT = 25
CALL_LIMIT = 255
ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


def load_workflow(path):
    class Loader(yaml.SafeLoader):
        pass

    # Copy before editing so SafeLoader itself still parses true/false/on.
    Loader.yaml_implicit_resolvers = {
        key: list(value) for key, value in yaml.SafeLoader.yaml_implicit_resolvers.items()
    }
    # Keep true/false as booleans, but do not treat the workflow key "on" as true.
    for first in ("o", "O"):
        Loader.yaml_implicit_resolvers[first] = [
            item
            for item in Loader.yaml_implicit_resolvers.get(first, [])
            if item[0] != "tag:yaml.org,2002:bool"
        ]
    text = path.read_text(encoding="utf-8")
    data = yaml.load(text, Loader=Loader)
    if not isinstance(data, dict) or "on" not in data:
        raise SystemExit(f"{path}: workflow has no 'on' mapping")
    return data


def input_names(section):
    if not isinstance(section, dict):
        return []
    inputs = section.get("inputs") or {}
    if not isinstance(inputs, dict):
        raise SystemExit("inputs is not a mapping")
    return list(inputs)


def jobs_calling(data, target_name):
    found = []
    for job_name, job in (data.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        uses = str(job.get("uses") or "")
        if uses.endswith("/" + target_name) or uses.endswith(target_name):
            found.append((job_name, job.get("with") or {}))
    return found


def main():
    errors = []
    parsed = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        data = load_workflow(path)
        parsed[path.name] = data
        on = data["on"]
        dispatch = input_names(on.get("workflow_dispatch"))
        call = input_names(on.get("workflow_call"))
        if len(dispatch) > DISPATCH_LIMIT:
            errors.append(
                f"{path.name}: workflow_dispatch has {len(dispatch)} inputs, limit {DISPATCH_LIMIT}"
            )
        if len(call) > CALL_LIMIT:
            errors.append(
                f"{path.name}: workflow_call has {len(call)} inputs, limit {CALL_LIMIT}"
            )
        print(
            f"{path.name}: dispatch={len(dispatch)} call={len(call)}"
        )

    custom = parsed["kernel-custom.yml"]
    custom_inputs = input_names(custom["on"]["workflow_dispatch"])
    if "gki_commit" in custom_inputs:
        errors.append("kernel-custom.yml still exposes gki_commit on workflow_dispatch")
    if len(custom_inputs) != DISPATCH_LIMIT:
        errors.append(
            f"kernel-custom.yml dispatch count is {len(custom_inputs)}, expected exactly {DISPATCH_LIMIT}"
        )

    device = parsed["kernel-songyuan-61269.yml"]
    device_inputs = input_names(device["on"]["workflow_dispatch"])
    gki = device["on"]["workflow_dispatch"]["inputs"]["gki_commit"]
    if gki.get("default") != "0a1dc0413ec7f42ad5924505ca2a519900ccf770":
        errors.append("device workflow gki_commit default is not the device snapshot")
    if device["on"]["workflow_dispatch"]["inputs"]["version"].get("default") != (
        "android16-6-g0a1dc0413ec7-ab16271006-4k"
    ):
        errors.append("device workflow version default changed")
    if device["on"]["workflow_dispatch"]["inputs"]["build_time"].get("default") != (
        "Sat Sep  5 12:19:39 UTC 2026"
    ):
        errors.append("device workflow build_time default changed")
    variants = device["on"]["workflow_dispatch"]["inputs"]["kernelsu_variant"]
    if variants.get("options") != ["SukiSU-Nova"]:
        errors.append("device workflow must select only SukiSU-Nova")
    if "use_zram" in device_inputs:
        errors.append("songyuan must preserve the stock vendor ZRAM modules")
    nomount = device["on"]["workflow_dispatch"]["inputs"]["use_nomount"]
    if nomount.get("default") is not True:
        errors.append("songyuan must enable NoMount by default")
    for job_name, job in device["jobs"].items():
        if job.get("uses", "").endswith(("/build.yml", "/get-manager.yml")):
            passed = job.get("with") or {}
            if passed.get("use_zram") is not False:
                errors.append(f"device job {job_name} must keep use_zram=false")
            if passed.get("use_nomount") != "${{ inputs.use_nomount || false }}":
                errors.append(f"device job {job_name} must route the selected NoMount value")

    for caller_name, caller in parsed.items():
        for job_name, job in (caller.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            uses = str(job.get("uses") or "")
            if not uses.startswith("./.github/workflows/"):
                continue
            callee_name = uses.rsplit("/", 1)[-1]
            callee = parsed.get(callee_name)
            if callee is None or "workflow_call" not in callee["on"]:
                errors.append(f"{caller_name} job {job_name} calls {callee_name} without workflow_call")
                continue
            passed = job.get("with") or {}
            declared = callee["on"]["workflow_call"]["inputs"]
            unknown = sorted(set(passed) - set(declared))
            if unknown:
                errors.append(
                    f"{caller_name} job {job_name} passes undeclared inputs to {callee_name}: {unknown}"
                )
            required = [
                key
                for key, spec in declared.items()
                if isinstance(spec, dict) and spec.get("required") is True
            ]
            missing = sorted(set(required) - set(passed))
            if missing:
                errors.append(
                    f"{caller_name} job {job_name} omits required inputs for {callee_name}: {missing}"
                )

    build_passed = []
    for job_name, passed in jobs_calling(device, "build.yml"):
        build_passed.append(passed)
    if not build_passed or "gki_commit" not in build_passed[0]:
        errors.append("device workflow does not route gki_commit into build.yml")
    if not build_passed or build_passed[0].get("preserve_songyuan_modules") is not True:
        errors.append("device workflow must preserve the stock netfs and ZRAM modules")
    pinned = build_passed[0].get("android_version"), build_passed[0].get("kernel_version"), build_passed[0].get("sub_level"), build_passed[0].get("os_patch_level")
    if pinned != ("android16", "6.12", "69", "2026-03"):
        errors.append(f"device workflow kernel selection changed: {pinned}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("workflow input limits and routing ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
