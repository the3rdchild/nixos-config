#ifndef ACER_EC_CORE_H
#define ACER_EC_CORE_H

#include <linux/types.h>

u8 ec_core_read8(u16 offset);
u16 ec_core_read16(u16 offset);
int ec_core_scmd(u32 cmd, u8 b0, u8 b1, u8 b2, u8 b3);

#endif
