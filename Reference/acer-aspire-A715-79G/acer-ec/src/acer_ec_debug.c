// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/debugfs.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/acpi.h>
#include "acer_ec_core.h"

#define SYSMEM_PHYS 0xFE0B0100UL
#define SYSMEM_SIZE 0x100

static void __iomem *sysmem_base;
static struct dentry *df_root;
static acpi_handle wmi_handle;

/*
 * Hotkey tracing. The DSDT's NEVT method only forwards hotkeys to the OS when
 * HKDR is set (via SCMD 0x46); it then stores the event code in \_SB.WMI.EVNT
 * and issues Notify(WMI, 0xD0). Without that handshake the EC swallows them.
 */
static void wmi_notify(acpi_handle handle, u32 event, void *data)
{
	unsigned long long evnt = 0;
	acpi_status status;

	status = acpi_evaluate_integer(handle, "EVNT", NULL, &evnt);
	if (ACPI_FAILURE(status))
		pr_info("notify 0x%02x (EVNT unreadable)\n", event);
	else
		pr_info("notify 0x%02x EVNT=0x%02llx\n", event, evnt);
}

static ssize_t reg8_read(struct file *filp, char __user *buf,
			 size_t count, loff_t *pos)
{
	char tmp[16];
	u16 off;
	u8 val;

	if (*pos != 0)
		return 0;
	if (sscanf(filp->f_path.dentry->d_name.name, "reg8_%hx", &off) != 1)
		return -EINVAL;
	if (off >= SYSMEM_SIZE)
		return -ERANGE;
	val = ioread8(sysmem_base + off);
	snprintf(tmp, sizeof(tmp), "0x%02x (%u)\n", val, val);
	return simple_read_from_buffer(buf, count, pos, tmp, strlen(tmp));
}

static ssize_t reg16_read(struct file *filp, char __user *buf,
			  size_t count, loff_t *pos)
{
	char tmp[16];
	u16 off;
	u16 val;

	if (*pos != 0)
		return 0;
	if (sscanf(filp->f_path.dentry->d_name.name, "reg16_%hx", &off) != 1)
		return -EINVAL;
	if (off >= SYSMEM_SIZE - 1)
		return -ERANGE;
	val = ioread16(sysmem_base + off);
	snprintf(tmp, sizeof(tmp), "0x%04x (%u)\n", val, val);
	return simple_read_from_buffer(buf, count, pos, tmp, strlen(tmp));
}

static ssize_t dump_read(struct file *filp, char __user *buf,
			 size_t count, loff_t *pos)
{
	char *tmp;
	int i, n = 0;
	ssize_t ret;

	if (*pos != 0)
		return 0;
	tmp = kmalloc(4096, GFP_KERNEL);
	if (!tmp)
		return -ENOMEM;
	for (i = 0; i < SYSMEM_SIZE; i += 16) {
		int j;
		n += snprintf(tmp + n, 4096 - n, "%02x: ", i);
		for (j = 0; j < 16 && i + j < SYSMEM_SIZE; j++)
			n += snprintf(tmp + n, 4096 - n, "%02x ",
				      ioread8(sysmem_base + i + j));
		n += snprintf(tmp + n, 4096 - n, "\n");
	}
	ret = simple_read_from_buffer(buf, count, pos, tmp, n);
	kfree(tmp);
	return ret;
}

/*
 * Raw SCMD injector — "<cmd> <args32>", both hex or decimal.
 * args32 is passed as the 4-byte ACPI buffer, little-endian, matching how
 * the DSDT does "ARGS = Arg2" on a Buffer.
 *
 * Example (keyboard backlight on, SCMD 0x67 fn=0x4 val=1):
 *     echo "0x67 0x40010000" > /sys/kernel/debug/acer_ec/scmd
 */
static ssize_t scmd_write(struct file *filp, const char __user *buf,
			  size_t count, loff_t *pos)
{
	char tmp[64];
	u32 cmd, args;
	int ret;

	if (count >= sizeof(tmp))
		return -EINVAL;
	if (copy_from_user(tmp, buf, count))
		return -EFAULT;
	tmp[count] = '\0';

	if (sscanf(tmp, "%i %i", &cmd, &args) != 2)
		return -EINVAL;

	ret = ec_core_scmd(cmd, args & 0xff, (args >> 8) & 0xff,
			   (args >> 16) & 0xff, (args >> 24) & 0xff);
	pr_info("scmd(0x%02x, 0x%08x) = %d\n", cmd, args, ret);

	return ret ? ret : count;
}

static const struct file_operations scmd_fops = { .write = scmd_write };
static const struct file_operations reg8_fops = { .read = reg8_read };
static const struct file_operations reg16_fops = { .read = reg16_read };
static const struct file_operations dump_fops = { .read = dump_read };

static int __init acer_ec_debug_init(void)
{
	sysmem_base = ioremap(SYSMEM_PHYS, SYSMEM_SIZE);
	if (!sysmem_base)
		return -ENOMEM;

	df_root = debugfs_create_dir("acer_ec", NULL);
	if (!df_root) {
		iounmap(sysmem_base);
		return -ENOMEM;
	}

	debugfs_create_file("reg8_00", 0444, df_root, NULL, &reg8_fops);
	debugfs_create_file("reg8_07", 0444, df_root, NULL, &reg8_fops);
	debugfs_create_file("reg8_CE", 0444, df_root, NULL, &reg8_fops);
	debugfs_create_file("reg8_CF", 0444, df_root, NULL, &reg8_fops);
	debugfs_create_file("reg8_D7", 0444, df_root, NULL, &reg8_fops);
	debugfs_create_file("reg8_D8", 0444, df_root, NULL, &reg8_fops);
	debugfs_create_file("reg8_D9", 0444, df_root, NULL, &reg8_fops);
	debugfs_create_file("reg8_DA", 0444, df_root, NULL, &reg8_fops);
	debugfs_create_file("reg8_DB", 0444, df_root, NULL, &reg8_fops);
	debugfs_create_file("reg16_D0", 0444, df_root, NULL, &reg16_fops);
	debugfs_create_file("reg16_D2", 0444, df_root, NULL, &reg16_fops);
	debugfs_create_file("reg16_E0", 0444, df_root, NULL, &reg16_fops);
	debugfs_create_file("reg16_D4", 0444, df_root, NULL, &reg16_fops);
	debugfs_create_file("dump", 0444, df_root, NULL, &dump_fops);
	debugfs_create_file("scmd", 0200, df_root, NULL, &scmd_fops);

	if (ACPI_SUCCESS(acpi_get_handle(NULL, "\\_SB_.WMI", &wmi_handle)) ||
	    ACPI_SUCCESS(acpi_get_handle(NULL, "\\_SB.WMI", &wmi_handle))) {
		if (ACPI_FAILURE(acpi_install_notify_handler(wmi_handle,
							    ACPI_DEVICE_NOTIFY,
							    wmi_notify, NULL))) {
			pr_warn("could not hook \\_SB.WMI notifications\n");
			wmi_handle = NULL;
		} else {
			pr_info("tracing \\_SB.WMI notifications\n");
		}
	} else {
		wmi_handle = NULL;
	}

	pr_info("loaded — see /sys/kernel/debug/acer_ec/\n");
	return 0;
}

static void __exit acer_ec_debug_exit(void)
{
	if (wmi_handle)
		acpi_remove_notify_handler(wmi_handle, ACPI_DEVICE_NOTIFY,
					   wmi_notify);
	debugfs_remove_recursive(df_root);
	iounmap(sysmem_base);
	pr_info("unloaded\n");
}

module_init(acer_ec_debug_init);
module_exit(acer_ec_debug_exit);

MODULE_VERSION("0.1");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Acer Aspire A715-79G community");
MODULE_DESCRIPTION("Acer EC debug — read-only EC SystemMemory explorer via debugfs");
MODULE_SOFTDEP("pre: acer_ec_core");
