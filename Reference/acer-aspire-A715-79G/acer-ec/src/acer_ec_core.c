// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/acpi.h>
#include <linux/io.h>
#include "acer_ec_core.h"

#define SYSMEM_PHYS 0xFE0B0100UL
#define SYSMEM_SIZE 0x100

static void __iomem *sysmem_base;
static acpi_handle wmi_handle;

static bool sysmem_ok;
static bool wmi_ok;

u8 ec_core_read8(u16 offset)
{
	if (unlikely(!sysmem_ok || offset >= SYSMEM_SIZE))
		return 0;
	return ioread8(sysmem_base + offset);
}
EXPORT_SYMBOL_GPL(ec_core_read8);

u16 ec_core_read16(u16 offset)
{
	if (unlikely(!sysmem_ok || offset >= SYSMEM_SIZE - 1))
		return 0;
	return ioread16(sysmem_base + offset);
}
EXPORT_SYMBOL_GPL(ec_core_read16);

int ec_core_scmd(u32 cmd, u8 b0, u8 b1, u8 b2, u8 b3)
{
	static union acpi_object objs[3];
	static u8 buf[4];
	struct acpi_object_list params = { .count = 3, .pointer = objs };
	acpi_status status;

	if (unlikely(!wmi_ok))
		return -ENODEV;

	buf[0] = b0; buf[1] = b1; buf[2] = b2; buf[3] = b3;

	objs[0].type = ACPI_TYPE_INTEGER;
	objs[0].integer.value = 0;
	objs[1].type = ACPI_TYPE_INTEGER;
	objs[1].integer.value = cmd;
	objs[2].type = ACPI_TYPE_BUFFER;
	objs[2].buffer.length = 4;
	objs[2].buffer.pointer = buf;

	status = acpi_evaluate_object(wmi_handle, "SCMD", &params, NULL);
	return ACPI_FAILURE(status) ? -EIO : 0;
}
EXPORT_SYMBOL_GPL(ec_core_scmd);

static int __init acer_ec_core_init(void)
{
	acpi_status status;

	sysmem_base = ioremap(SYSMEM_PHYS, SYSMEM_SIZE);
	if (!sysmem_base) {
		pr_err("ioremap(0x%lx, 0x%x) failed\n", SYSMEM_PHYS, SYSMEM_SIZE);
		return -ENOMEM;
	}
	sysmem_ok = true;

	status = acpi_get_handle(NULL, "\\_SB_.WMI", &wmi_handle);
	if (ACPI_FAILURE(status))
		status = acpi_get_handle(NULL, "\\_SB.WMI", &wmi_handle);
	if (ACPI_FAILURE(status)) {
		pr_warn("WMI handle not found, SCMD calls will fail\n");
		wmi_ok = false;
	} else {
		wmi_ok = true;
	}

	pr_info("loaded\n");
	return 0;
}

static void __exit acer_ec_core_exit(void)
{
	if (sysmem_ok)
		iounmap(sysmem_base);
	sysmem_ok = false;
	wmi_ok = false;
	pr_info("unloaded\n");
}

module_init(acer_ec_core_init);
module_exit(acer_ec_core_exit);

MODULE_VERSION("0.1");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Acer Aspire A715-79G community");
MODULE_DESCRIPTION("Acer EC core — SystemMemory mapping + ACPI SCMD wrapper");
