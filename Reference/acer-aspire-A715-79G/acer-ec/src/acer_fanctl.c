// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/sysfs.h>
#include <linux/kobject.h>
#include <linux/hwmon.h>
#include <linux/hwmon-sysfs.h>
#include <linux/err.h>
#include <linux/platform_device.h>
#include <linux/platform_profile.h>
#include <linux/reboot.h>
#include <linux/mutex.h>
#include <linux/jiffies.h>
#include "acer_ec_core.h"

#define DRV_NAME "acer_fanctl"

static struct kobject *fan_kobj;
static struct device *hwmon_dev;
static struct platform_device *pdev;
static struct device *ppdev;

static inline u16 raw_to_rpm(u16 raw)
{
	if (raw == 0 || raw > 60000)
		return 0;
	return 60000000U / raw;
}

/* --- sysfs read helpers --- */
#define FAN_SHOW8(name, off) \
static ssize_t name##_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf) \
{ return sprintf(buf, "%d\n", (int)ec_core_read8(off)); }

#define FAN_SHOW16_RPM(name, off) \
static ssize_t name##_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf) \
{ return sprintf(buf, "%u\n", (unsigned)raw_to_rpm(ec_core_read16(off))); }

FAN_SHOW8(fan1_duty, 0xCE)
FAN_SHOW8(fan2_duty, 0xCF)
FAN_SHOW16_RPM(fan1_rpm, 0xD0)
FAN_SHOW16_RPM(fan2_rpm, 0xD2)
FAN_SHOW16_RPM(fan4_rpm, 0xD4)
FAN_SHOW16_RPM(fan3_rpm, 0xE0)
FAN_SHOW8(dthl_val, 0xD7)
FAN_SHOW8(dtbp_val, 0xD8)
FAN_SHOW8(airp_val, 0xD9)
FAN_SHOW8(winf_val, 0xDA)
FAN_SHOW8(rinf_val, 0xDB)
FAN_SHOW8(tmp_temp, 0x07)

/* --- sysfs: profile (1-4) --- */
static int profile_cur;

/*
 * Duties we asked for recently, used in place of EC RAM for the sibling fan.
 *
 * SCMD 0x68 always carries both duties (see the duty stores below), so each
 * store has to fill in the fan it is not addressing. EC RAM is a poor source
 * for that right after a write: 0xCE/0xCF only reflect a new duty ~0.5 s
 * later. Measured, with the EC curve holding DUT1 at 145 in profile 4:
 *
 *     fan1_duty_set=255; fan2_duty_set=255   ->  dut1 stays 144  (RPM1 ~1070)
 *     fan2_duty_set=255; fan1_duty_set=255   ->  dut1 255        (RPM1 4687)
 *
 * The fan2 store read the stale 145 back out of 0xCE and re-sent it, undoing
 * the fan1 write. acer-fan-max writes in exactly that order every 3 s, so the
 * CPU fan sat at 57% duty in "performance" while the GPU fan ran flat out.
 *
 * So remember each requested duty for DUTY_SETTLE and prefer it over EC RAM.
 * Past that window EC RAM is authoritative again. Any profile change hands
 * the fans back to the EC curve, so it forgets them.
 */
#define DUTY_SETTLE (2 * HZ)

static DEFINE_MUTEX(duty_lock);
static u8 duty_req[2];
static unsigned long duty_req_at[2];
static bool duty_req_valid[2];

static u8 duty_sibling(int fan, u16 off)
{
	if (duty_req_valid[fan] &&
	    time_before(jiffies, duty_req_at[fan] + DUTY_SETTLE))
		return duty_req[fan];
	return ec_core_read8(off);
}

static void duty_remember(int fan, u8 val)
{
	duty_req[fan] = val;
	duty_req_at[fan] = jiffies;
	duty_req_valid[fan] = true;
}

static void duty_forget(void)
{
	mutex_lock(&duty_lock);
	duty_req_valid[0] = duty_req_valid[1] = false;
	mutex_unlock(&duty_lock);
}

static ssize_t profile_store(struct kobject *kobj, struct kobj_attribute *attr,
			     const char *buf, size_t count)
{
	u32 val;
	int ret = kstrtou32(buf, 0, &val);
	if (ret) return ret;
	if (val < 1 || val > 4) return -EINVAL;
	ret = ec_core_scmd(0x69, BIT(val - 1), 0, 0, 0);
	if (ret) return ret;
	profile_cur = val;
	duty_forget();
	return count;
}

/*
 * The EC has no readback for the active profile, so we report what we last
 * wrote. Seeded from profile_param at load time.
 */
static ssize_t profile_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sprintf(buf, "%d\n", profile_cur);
}

/*
 * --- sysfs: fan duty writes ---
 *
 * SCMD 0x68 carries BOTH duties in one command: byte0 = DUT1, byte1 = DUT2.
 * There is no "leave this one alone" encoding — a byte of 0 means 0% duty,
 * which stops that fan outright.
 *
 * Both stores used to pass 0 for the fan they were not addressing, so
 * `echo 255 > fan2_duty_set` set the GPU fan to max AND stopped the CPU fan.
 * Measured on this machine: DUT1 71 -> 0, RPM1 2003 -> 0, and it stayed
 * stopped (package temperature reached 89 C) until the EC was made to
 * reclaim the fan. The README's claim that the EC restores DUT1 within
 * ~500ms does not hold on this firmware.
 *
 * So re-send the sibling fan's current duty unchanged: the one we requested
 * within the last DUTY_SETTLE if there is one, otherwise what EC RAM holds
 * (see duty_sibling() for why EC RAM alone was not enough).
 *
 * Note this makes the written fan MANUAL until something hands it back —
 * write `fan_auto` (or `profile`) for that.
 */
static ssize_t fan2_duty_set_store(struct kobject *kobj, struct kobj_attribute *attr,
				   const char *buf, size_t count)
{
	u32 val;
	int ret = kstrtou32(buf, 0, &val);
	if (ret) return ret;
	if (val > 255) return -EINVAL;
	mutex_lock(&duty_lock);
	ret = ec_core_scmd(0x68, duty_sibling(0, 0xCE), val, 0, 0);
	if (!ret)
		duty_remember(1, val);
	mutex_unlock(&duty_lock);
	if (ret) return ret;
	return count;
}

/*
 * fan1_duty_set — EXPERIMENTAL, and the dangerous one.
 *
 * Fan 1 is the CPU fan. Upstream documents it as EC-protected and expected
 * writes here to be overwritten within ~500ms; on this firmware they are not,
 * so a low value really does stop the CPU fan and keep it stopped. Kept
 * root-only (see the tmpfiles rules in the NixOS module, which deliberately
 * relax fan2_duty_set but not this) precisely because there is no thermal
 * interlock behind it.
 */
static ssize_t fan1_duty_set_store(struct kobject *kobj, struct kobj_attribute *attr,
				   const char *buf, size_t count)
{
	u32 val;
	int ret = kstrtou32(buf, 0, &val);
	if (ret) return ret;
	if (val > 255) return -EINVAL;
	mutex_lock(&duty_lock);
	ret = ec_core_scmd(0x68, val, duty_sibling(1, 0xCF), 0, 0);
	if (!ret)
		duty_remember(0, val);
	mutex_unlock(&duty_lock);
	if (ret) return ret;
	return count;
}

/*
 * fan_auto — hand both fans back to the EC's own curve.
 *
 * There is no "auto" command in the EC interface; re-applying a profile is
 * what drops manual duty. But the EC only re-asserts its curve when the
 * profile actually CHANGES — re-sending the profile that is already active
 * is a no-op. Measured: sitting at profile 4 with DUT2 pinned to 255, a
 * second SCMD 0x69 for profile 4 left it pinned (8s, no movement), while
 * switching to profile 2 released it within 2s.
 *
 * So bounce through a neighbouring profile and come straight back. No delay
 * between the two commands is needed — the EC processes them in order and
 * the release still happens; the intermediate profile is never observable in
 * the fan curve.
 *
 * Any written value is accepted and ignored.
 */
static ssize_t fan_auto_store(struct kobject *kobj, struct kobj_attribute *attr,
			      const char *buf, size_t count)
{
	int val = profile_cur;
	int other;
	int ret;

	if (val < 1 || val > 4)
		val = 2;
	other = (val == 1) ? 2 : 1;

	ret = ec_core_scmd(0x69, BIT(other - 1), 0, 0, 0);
	if (ret) return ret;
	ret = ec_core_scmd(0x69, BIT(val - 1), 0, 0, 0);
	if (ret) return ret;

	profile_cur = val;
	duty_forget();
	return count;
}

/* --- sysfs: dump all values at once --- */
static ssize_t all_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	u8 dut1 = ec_core_read8(0xCE);
	u8 dut2 = ec_core_read8(0xCF);
	u16 raw1 = ec_core_read16(0xD0);
	u16 raw2 = ec_core_read16(0xD2);
	u16 raw3 = ec_core_read16(0xE0);
	u16 raw4 = ec_core_read16(0xD4);
	u16 rpm1 = raw_to_rpm(raw1);
	u16 rpm2 = raw_to_rpm(raw2);
	u16 rpm3 = raw_to_rpm(raw3);
	u16 rpm4 = raw_to_rpm(raw4);
	u8 dthl = ec_core_read8(0xD7);
	u8 dtbp = ec_core_read8(0xD8);
	u8 airp = ec_core_read8(0xD9);
	u8 winf = ec_core_read8(0xDA);
	u8 rinf = ec_core_read8(0xDB);
	u8 tmp  = ec_core_read8(0x07);

	return sprintf(buf,
		"dut1=%d dut2=%d\n"
		"raw1=%u raw2=%u raw3=%u raw4=%u\n"
		"rpm1=%u rpm2=%u rpm3=%u rpm4=%u\n"
		"dthl=%d dtbp=%d airp=%d winf=%d rinf=%d\n"
		"tmp=%d\n",
		dut1, dut2,
		raw1, raw2, raw3, raw4,
		rpm1, rpm2, rpm3, rpm4,
		dthl, dtbp, airp, winf, rinf,
		tmp);
}

static struct kobj_attribute fan1_duty_attr = __ATTR_RO(fan1_duty);
static struct kobj_attribute fan2_duty_attr = __ATTR_RO(fan2_duty);
static struct kobj_attribute fan1_rpm_attr = __ATTR_RO(fan1_rpm);
static struct kobj_attribute fan2_rpm_attr = __ATTR_RO(fan2_rpm);
static struct kobj_attribute fan3_rpm_attr = __ATTR_RO(fan3_rpm);
static struct kobj_attribute fan4_rpm_attr = __ATTR_RO(fan4_rpm);
static struct kobj_attribute dthl_val_attr = __ATTR_RO(dthl_val);
static struct kobj_attribute dtbp_val_attr = __ATTR_RO(dtbp_val);
static struct kobj_attribute airp_val_attr = __ATTR_RO(airp_val);
static struct kobj_attribute winf_val_attr = __ATTR_RO(winf_val);
static struct kobj_attribute rinf_val_attr = __ATTR_RO(rinf_val);
static struct kobj_attribute tmp_temp_attr = __ATTR_RO(tmp_temp);
static struct kobj_attribute profile_attr = __ATTR_RW(profile);
static struct kobj_attribute fan2_duty_set_attr = __ATTR_WO(fan2_duty_set);
static struct kobj_attribute fan1_duty_set_attr = __ATTR_WO(fan1_duty_set);
static struct kobj_attribute fan_auto_attr = __ATTR_WO(fan_auto);
static struct kobj_attribute all_attr = __ATTR_RO(all);

static struct attribute *attrs[] = {
	&fan1_duty_attr.attr,
	&fan2_duty_attr.attr,
	&fan1_rpm_attr.attr,
	&fan2_rpm_attr.attr,
	&fan3_rpm_attr.attr,
	&fan4_rpm_attr.attr,
	&dthl_val_attr.attr,
	&dtbp_val_attr.attr,
	&airp_val_attr.attr,
	&winf_val_attr.attr,
	&rinf_val_attr.attr,
	&tmp_temp_attr.attr,
	&profile_attr.attr,
	&fan2_duty_set_attr.attr,
	&fan1_duty_set_attr.attr,
	&fan_auto_attr.attr,
	&all_attr.attr,
	NULL,
};

static struct attribute_group attr_group = {
	.attrs = attrs,
};

/* --- hwmon interface (lm_sensors) --- */
static ssize_t acer_hwmon_val_show(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	long val = 0;

	if (strcmp(attr->attr.name, "temp1_input") == 0)
		val = ec_core_read8(0x07) * 1000;
	else if (strcmp(attr->attr.name, "fan1_input") == 0)
		val = raw_to_rpm(ec_core_read16(0xD0));
	else if (strcmp(attr->attr.name, "fan2_input") == 0)
		val = raw_to_rpm(ec_core_read16(0xD2));

	return sprintf(buf, "%ld\n", val);
}

static SENSOR_DEVICE_ATTR_RO(temp1_input, acer_hwmon_val, 0);
static SENSOR_DEVICE_ATTR_RO(fan1_input, acer_hwmon_val, 0);
static SENSOR_DEVICE_ATTR_RO(fan2_input, acer_hwmon_val, 0);

static struct attribute *acer_hwmon_attrs[] = {
	&sensor_dev_attr_temp1_input.dev_attr.attr,
	&sensor_dev_attr_fan1_input.dev_attr.attr,
	&sensor_dev_attr_fan2_input.dev_attr.attr,
	NULL
};

static const struct attribute_group acer_hwmon_group = {
	.attrs = acer_hwmon_attrs,
};

static const struct attribute_group *acer_hwmon_groups[] = {
	&acer_hwmon_group,
	NULL
};

/*
 * platform_profile bridge.
 *
 * Exposes the EC's four fan profiles through the standard kernel interface, so
 * the power applet in Plasma/GNOME (via power-profiles-daemon) can switch them
 * without any desktop-specific widget.
 */
static int acer_pp_set(struct device *dev, enum platform_profile_option profile)
{
	int val;

	switch (profile) {
	case PLATFORM_PROFILE_QUIET:               val = 1; break;
	case PLATFORM_PROFILE_LOW_POWER:           val = 1; break;
	case PLATFORM_PROFILE_BALANCED:            val = 2; break;
	case PLATFORM_PROFILE_BALANCED_PERFORMANCE: val = 3; break;
	case PLATFORM_PROFILE_PERFORMANCE:         val = 4; break;
	default:                                   return -EOPNOTSUPP;
	}

	if (ec_core_scmd(0x69, BIT(val - 1), 0, 0, 0))
		return -EIO;

	profile_cur = val;
	duty_forget();
	return 0;
}

static int acer_pp_get(struct device *dev, enum platform_profile_option *profile)
{
	switch (profile_cur) {
	case 1: *profile = PLATFORM_PROFILE_QUIET; break;
	case 3: *profile = PLATFORM_PROFILE_BALANCED_PERFORMANCE; break;
	case 4: *profile = PLATFORM_PROFILE_PERFORMANCE; break;
	default: *profile = PLATFORM_PROFILE_BALANCED; break;
	}
	return 0;
}

static int acer_pp_probe(void *drvdata, unsigned long *choices)
{
	set_bit(PLATFORM_PROFILE_QUIET, choices);
	set_bit(PLATFORM_PROFILE_BALANCED, choices);
	set_bit(PLATFORM_PROFILE_BALANCED_PERFORMANCE, choices);
	set_bit(PLATFORM_PROFILE_PERFORMANCE, choices);
	return 0;
}

static const struct platform_profile_ops acer_pp_ops = {
	.probe = acer_pp_probe,
	.profile_get = acer_pp_get,
	.profile_set = acer_pp_set,
};

static int profile_param = 2;
module_param(profile_param, int, 0444);
MODULE_PARM_DESC(profile_param, "Default fan profile (1=quiet 2=balanced 3=performance 4=gaming)");

/*
 * --- reboot/poweroff: hand the EC back in its boot state ---
 *
 * The EC keeps whatever profile and manual duty it was last given across a
 * warm reboot — it never loses power. Rebooting from profile 4 with both
 * duties pinned at 255 (acer-fan-max) left the firmware hanging at the Acer
 * logo; a cold boot, or a reboot from balanced, did not. Firmware POST
 * evidently expects the EC on its own curve.
 *
 * So on every orderly restart/halt/poweroff, put it back on profile 2 —
 * balanced, the EC's automatic curve and what this driver loads with by
 * default. Fixed at 2 rather than profile_param on purpose: the point is a
 * state the firmware is known to cope with, not whatever was configured.
 * Bounce through profile 1 first, same as fan_auto: re-sending the active
 * profile is a no-op, so a manual duty under profile 2 would otherwise
 * survive.
 *
 * Reboot notifiers run after userspace is gone (nothing can re-pin the fans
 * afterwards) and before device_shutdown(), so ACPI SCMD still works.
 * Emergency restarts (SysRq-B, panic) skip notifiers and are not covered.
 */
#define REBOOT_PROFILE 2

static int acer_fanctl_reboot(struct notifier_block *nb, unsigned long action,
			      void *data)
{
	if (ec_core_scmd(0x69, BIT(1 - 1), 0, 0, 0) ||
	    ec_core_scmd(0x69, BIT(REBOOT_PROFILE - 1), 0, 0, 0))
		pr_warn("could not reset EC profile for reboot\n");
	else
		profile_cur = REBOOT_PROFILE;
	duty_forget();
	return NOTIFY_DONE;
}

static struct notifier_block acer_fanctl_reboot_nb = {
	.notifier_call = acer_fanctl_reboot,
};

static int __init acer_fanctl_init(void)
{
	int ret;

	fan_kobj = kobject_create_and_add("acer_fanctl", kernel_kobj);
	if (!fan_kobj)
		return -ENOMEM;

	ret = sysfs_create_group(fan_kobj, &attr_group);
	if (ret) {
		kobject_put(fan_kobj);
		return ret;
	}

	if (profile_param >= 1 && profile_param <= 4) {
		ec_core_scmd(0x69, BIT(profile_param - 1), 0, 0, 0);
		profile_cur = profile_param;
	}

	hwmon_dev = hwmon_device_register_with_groups(NULL, "acer_ec",
						      NULL, acer_hwmon_groups);
	if (IS_ERR(hwmon_dev)) {
		pr_warn("hwmon registration failed (%ld), sensors won't see it\n",
			PTR_ERR(hwmon_dev));
		hwmon_dev = NULL;
	}

	pdev = platform_device_register_simple(DRV_NAME, PLATFORM_DEVID_NONE,
					       NULL, 0);
	if (IS_ERR(pdev)) {
		pr_warn("platform device registration failed (%ld)\n",
			PTR_ERR(pdev));
		pdev = NULL;
	} else {
		ppdev = platform_profile_register(&pdev->dev, DRV_NAME, NULL,
						  &acer_pp_ops);
		if (IS_ERR(ppdev)) {
			pr_warn("platform_profile registration failed (%ld)\n",
				PTR_ERR(ppdev));
			ppdev = NULL;
		} else {
			pr_info("platform_profile registered\n");
		}
	}

	ret = register_reboot_notifier(&acer_fanctl_reboot_nb);
	if (ret)
		pr_warn("reboot notifier registration failed (%d)\n", ret);

	pr_info("loaded (profile=%d) - see /sys/kernel/acer_fanctl/\n", profile_param);
	return 0;
}

static void __exit acer_fanctl_exit(void)
{
	unregister_reboot_notifier(&acer_fanctl_reboot_nb);
	if (ppdev)
		platform_profile_remove(ppdev);
	if (pdev)
		platform_device_unregister(pdev);
	if (hwmon_dev)
		hwmon_device_unregister(hwmon_dev);
	sysfs_remove_group(fan_kobj, &attr_group);
	kobject_put(fan_kobj);
	pr_info("unloaded\n");
}

module_init(acer_fanctl_init);
module_exit(acer_fanctl_exit);

MODULE_VERSION("0.1");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Acer Aspire A715-79G community");
MODULE_DESCRIPTION("Acer A715-79G fan control via acer_ec_core");

MODULE_SOFTDEP("pre: acer_ec_core");
