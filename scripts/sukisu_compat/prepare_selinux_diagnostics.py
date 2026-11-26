#!/usr/bin/env python3
"""Prepare diagnostic logging on the pinned songyuan SELinux implementation."""

import subprocess
import sys
from pathlib import Path


ACK = "0a1dc0413ec7f42ad5924505ca2a519900ccf770"
NOVA = "d8aafb76eeef070dad2dc39161ddf922545fce90"

STATUS_LOG = """static void selinux_diag_status(struct page *page, const char *operation)
{
	const struct selinux_kernel_status *status = page_address(page);
	u32 sequence, policyload;

	sequence = READ_ONCE(status->sequence);
	if (sequence & 1)
		return;
	smp_rmb();
	policyload = READ_ONCE(status->policyload);
	smp_rmb();
	if (sequence != READ_ONCE(status->sequence))
		return;

	pr_info_ratelimited("selinux-diag status %s tgid=%d tid=%d policyload=%u sequence=%u\\n",
			    operation, task_tgid_nr(current), task_pid_nr(current),
			    policyload, sequence);
}

"""

STATUS_READ = """	struct page    *status = filp->private_data;

	BUG_ON(!status);

	return simple_read_from_buffer(buf, count, ppos,
				       page_address(status),
				       sizeof(struct selinux_kernel_status));
"""

STATUS_READ_LOG = """	struct page    *status = filp->private_data;
	ssize_t ret;

	BUG_ON(!status);

	ret = simple_read_from_buffer(buf, count, ppos,
				      page_address(status),
				      sizeof(struct selinux_kernel_status));
	if (ret > 0)
		selinux_diag_status(status, "read");
	return ret;
"""

STATUS_MMAP_HEADER = """	struct page    *status = filp->private_data;
	unsigned long	size = vma->vm_end - vma->vm_start;
"""

STATUS_MMAP_TAIL = """	return remap_pfn_range(vma, vma->vm_start,
			       page_to_pfn(status),
			       size, vma->vm_page_prot);
"""

STATUS_MMAP_LOG = """	ret = remap_pfn_range(vma, vma->vm_start, page_to_pfn(status),
			      size, vma->vm_page_prot);
	if (!ret)
		selinux_diag_status(status, "mmap");
	return ret;
"""

ACCESS_TAIL = "\t\t\t  avd.seqno, avd.flags);\nout:\n"
ACCESS_LOG = """			  avd.seqno, avd.flags);
	if (length > 0)
		pr_info_ratelimited("selinux-diag access tgid=%d tid=%d seqno=%u\\n",
				    task_tgid_nr(current), task_pid_nr(current),
				    avd.seqno);
out:
"""


def replace_once(source, old, new, description):
    if source.count(old) != 1:
        raise ValueError(f"Expected one {description} match in pinned source")
    return source.replace(old, new)


def verify_head(root, expected):
    actual = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if actual != expected:
        raise ValueError(f"{root.name} HEAD is {actual}, expected {expected}")


def prepare_selinuxfs(source):
    insertion_point = "static ssize_t sel_read_handle_status("
    source = replace_once(
        source, insertion_point, STATUS_LOG + insertion_point, "status read entry"
    )
    source = replace_once(source, STATUS_READ, STATUS_READ_LOG, "status read body")
    source = replace_once(
        source, STATUS_MMAP_HEADER, STATUS_MMAP_HEADER + "\tint ret;\n", "status mmap header"
    )
    source = replace_once(source, STATUS_MMAP_TAIL, STATUS_MMAP_LOG, "status mmap return")
    source = replace_once(source, ACCESS_TAIL, ACCESS_LOG, "formatted access response")
    headers = ("<linux/ratelimit.h>", "<linux/sched.h>")
    additions = "".join(f"#include {header}\n" for header in headers
                        if f"#include {header}\n" not in source)
    return replace_once(
        source, "#include <linux/fs.h>\n", "#include <linux/fs.h>\n" + additions,
        "SELinux filesystem includes",
    )


def prepare_nova(source):
    return replace_once(
        source,
        "\tksu_selinux_hide_init();\n\tksu_avc_spoof_init();\n",
        "\t/* Keep native SELinux responses and audit records in the diagnostic build. */\n",
        "SELinux and AVC alteration initializers",
    )


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: prepare_selinux_diagnostics.py COMMON KERNELSU")
    common, nova = (Path(argument) for argument in sys.argv[1:])
    verify_head(common, ACK)
    verify_head(nova, NOVA)
    selinuxfs = common / "security/selinux/selinuxfs.c"
    ksu = nova / "kernel/ksu.c"

    # Validate both source transformations before changing either file.
    annotated = prepare_selinuxfs(selinuxfs.read_text(encoding="utf-8"))
    unmodified_responses = prepare_nova(ksu.read_text(encoding="utf-8"))
    selinuxfs.write_text(annotated, encoding="utf-8")
    ksu.write_text(unmodified_responses, encoding="utf-8")
    print(f"SELinux diagnostics prepared from ACK {ACK} and Nova {NOVA}")
    print("SELinux response and AVC alteration initializers omitted; read-only diagnostics added")


if __name__ == "__main__":
    main()
