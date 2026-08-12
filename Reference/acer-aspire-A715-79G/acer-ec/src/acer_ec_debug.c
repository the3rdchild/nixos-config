// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/debugfs.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include "acer_ec_core.h"

#define SYSMEM_PHYS 0xFE0B0100UL
#define SYSMEM_SIZE 0x100

static void __iomem *sysmem_base;
static struct dentry *df_root;

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

	pr_info("loaded — see /sys/kernel/debug/acer_ec/\n");
	return 0;
}

static void __exit acer_ec_debug_exit(void)
{
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
