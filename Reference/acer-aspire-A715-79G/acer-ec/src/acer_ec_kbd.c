// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/leds.h>
#include <linux/led-class-multicolor.h>
#include "acer_ec_core.h"

/*
 * Keyboard backlight on Acer Aspire A715-59G.
 *
 * The EC lighting opcode is 0xCA; the FDAT byte selects what the rest of the
 * mailbox means. This is not reachable through the ACPI SCMD path — SCMD 0x67
 * decodes to opcodes 0xC2/0xC4, which this EC firmware silently drops.
 *
 *   FDAT = 0x06   brightness, FBUF = level 0x00-0xFF
 *   FDAT = zone   colour, FBUF..FBF2 = blue, green, red; FBF3 = flags
 *
 * The colour half comes from the Acer-Aspire-A715-79G-KeyBoard reverse
 * engineering (`CA 03 BB RR GG`), which drives the same registers from
 * userspace through ec_sys/debugfs. Going through ec_core_ecmd() instead means
 * the writes are serialised against fan control under ecmd_lock and do not
 * require ec_sys write_support=1 — which would hand every root process raw
 * write access to the EC that also owns the thermal loop.
 *
 * The byte order is FA=Blue, FB=Red, FC=Green — note that green and red are
 * NOT in the order the register names suggest. That project's README table and
 * its rgb.sh disagree on this (the README flags the disagreement itself); the
 * table is the correct half. Confirmed on an A715-59G at colour zone 3:
 * writing `0 255 0` while the driver still followed rgb.sh's B,G,R order lit
 * the keyboard red, which puts red on FBF1 and green on FBF2.
 */
#define EC_CMD_LIGHT   0xCA
#define EC_SUB_BRIGHT  0x06

/*
 * Which lighting zone the colour command addresses. Zone 3 is what the RE
 * project found on an A715-79G, but fnkey.exe picks the zone from a runtime
 * keyboard-type probe, so it is not guaranteed to be 3 on every unit — hence a
 * writable module parameter rather than a constant.
 */
static int zone = 3;
module_param(zone, int, 0644);
MODULE_PARM_DESC(zone, "EC lighting zone for colour writes (default 3)");

static struct mc_subled kbd_subled[3];

/*
 * Colour is only sent once userspace has asked for one.
 *
 * The subled intensities start at 0,0,0 and the colour command is skipped
 * while they are all zero, so a module that nobody has written a colour to
 * behaves exactly like the old brightness-only one: the EC keeps whatever
 * colour it already had (from Acer Control Center under Windows, from a
 * previous boot, or the firmware default). Without this, the first brightness
 * keypress after boot would silently overwrite the colour with whatever the
 * driver happened to initialise to.
 *
 * All-zero is a safe sentinel because it is also indistinguishable from off:
 * brightness already covers turning the backlight down.
 */
static bool colour_wanted(void)
{
	return kbd_subled[0].intensity || kbd_subled[1].intensity ||
	       kbd_subled[2].intensity;
}

static int kbd_brightness_set(struct led_classdev *cdev,
			      enum led_brightness brightness)
{
	u8 level = brightness;
	int ret;

	if (colour_wanted()) {
		u8 buf[4];

		buf[0] = kbd_subled[2].intensity;	/* blue  -> FBUF 0xFA */
		buf[1] = kbd_subled[0].intensity;	/* red   -> FBF1 0xFB */
		buf[2] = kbd_subled[1].intensity;	/* green -> FBF2 0xFC */
		buf[3] = 0x00;				/* flags -> FBF3 0xFD */

		ret = ec_core_ecmd(EC_CMD_LIGHT, zone, buf, sizeof(buf));
		if (ret)
			return ret;
	}

	return ec_core_ecmd(EC_CMD_LIGHT, EC_SUB_BRIGHT, &level, 1);
}

/*
 * Registered as a multicolor LED so the colour lands on the standard
 * `multi_intensity` attribute rather than a bespoke one. The class name is
 * deliberately left as-is: the LED naming convention would suggest
 * "acer_ec:rgb:kbd_backlight", but brightnessctl invocations and the
 * SUPER+CTRL keybinds all name the existing device, and renaming it would
 * break them for a cosmetic gain.
 *
 * Writing multi_intensity re-applies the current brightness through
 * brightness_set_blocking(), so the colour reaches the EC on write without
 * needing a brightness change to flush it.
 */
static struct led_classdev_mc kbd_mc = {
	.subled_info = kbd_subled,
	.num_colors = ARRAY_SIZE(kbd_subled),
	.led_cdev = {
		.name = "acer_ec::kbd_backlight",
		.max_brightness = 255,
		.brightness_set_blocking = kbd_brightness_set,
		/* EC loses the level across suspend; let the LED core restore
		 * it — which re-sends the colour too, since it goes out of the
		 * same callback. */
		.flags = LED_CORE_SUSPENDRESUME,
	},
};

static int __init acer_ec_kbd_init(void)
{
	int ret;

	kbd_subled[0].color_index = LED_COLOR_ID_RED;
	kbd_subled[1].color_index = LED_COLOR_ID_GREEN;
	kbd_subled[2].color_index = LED_COLOR_ID_BLUE;

	ret = led_classdev_multicolor_register(NULL, &kbd_mc);
	if (ret) {
		pr_err("LED registration failed (%d)\n", ret);
		return ret;
	}

	pr_info("loaded — see /sys/class/leds/%s/ (colour zone %d)\n",
		kbd_mc.led_cdev.name, zone);
	return 0;
}

static void __exit acer_ec_kbd_exit(void)
{
	led_classdev_multicolor_unregister(&kbd_mc);
	pr_info("unloaded\n");
}

module_init(acer_ec_kbd_init);
module_exit(acer_ec_kbd_exit);

MODULE_VERSION("0.2");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Acer Aspire A715-59G community");
MODULE_DESCRIPTION("Acer EC keyboard backlight — LED class interface");
MODULE_SOFTDEP("pre: acer_ec_core");
