// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/leds.h>
#include "acer_ec_core.h"

/*
 * Keyboard backlight on Acer Aspire A715-59G.
 *
 * The EC lighting opcode is 0xCA; sub-command 0x06 sets brightness 0x00-0xFF.
 * This is not reachable through the ACPI SCMD path — SCMD 0x67 decodes to
 * opcodes 0xC2/0xC4, which this EC firmware silently drops.
 */
#define EC_CMD_LIGHT   0xCA
#define EC_SUB_BRIGHT  0x06

static int kbd_brightness_set(struct led_classdev *cdev,
			      enum led_brightness brightness)
{
	u8 level = brightness;

	return ec_core_ecmd(EC_CMD_LIGHT, EC_SUB_BRIGHT, &level, 1);
}

static struct led_classdev kbd_led = {
	.name = "acer_ec::kbd_backlight",
	.max_brightness = 255,
	.brightness_set_blocking = kbd_brightness_set,
	/* EC loses the level across suspend; let the LED core restore it. */
	.flags = LED_CORE_SUSPENDRESUME,
};

static int __init acer_ec_kbd_init(void)
{
	int ret;

	ret = led_classdev_register(NULL, &kbd_led);
	if (ret) {
		pr_err("LED registration failed (%d)\n", ret);
		return ret;
	}

	pr_info("loaded — see /sys/class/leds/%s/\n", kbd_led.name);
	return 0;
}

static void __exit acer_ec_kbd_exit(void)
{
	led_classdev_unregister(&kbd_led);
	pr_info("unloaded\n");
}

module_init(acer_ec_kbd_init);
module_exit(acer_ec_kbd_exit);

MODULE_VERSION("0.1");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Acer Aspire A715-59G community");
MODULE_DESCRIPTION("Acer EC keyboard backlight — LED class interface");
MODULE_SOFTDEP("pre: acer_ec_core");
