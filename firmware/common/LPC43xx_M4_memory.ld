/*
 * Copyright 2012 Michael Ossmann <mike@ossmann.com>
 * Copyright 2012 Jared Boone <jared@sharebrained.com>
 *
 * This file is part of HackRF
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street,
 * Boston, MA 02110-1301, USA.
 */

MEMORY
{
	/* Physical address in Flash used to copy Code from Flash to RAM */
	rom_flash (rx)  : ORIGIN = 0x80000000, LENGTH =  1M
	ram_usb (rwx) : ORIGIN = 0x20000000, LENGTH = 64K
}

usb_bulk_buffer = ORIGIN(ram_usb);
usb_bulk_buffer_stats = ORIGIN(ram_sleep) + 7K;
PROVIDE(__ram_m0_start__ = ORIGIN(ram_sleep));
