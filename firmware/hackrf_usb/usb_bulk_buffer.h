/*
 * Copyright 2012 Jared Boone
 * Copyright 2013 Benjamin Vernoux
 *
 * This file is part of HackRF.
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

#ifndef __USB_BULK_BUFFER_H__
#define __USB_BULK_BUFFER_H__

#include <stdbool.h>
#include <stdint.h>

/* Address of usb_bulk_buffer is set in ldscripts. If you change the name of this
 * variable, it won't be where it needs to be in the processor's address space,
 * unless you also adjust the ldscripts.
 */
extern uint8_t usb_bulk_buffer[32768];

enum usb_bulk_buffer_mode {
	USB_BULK_BUFFER_MODE_IDLE = 0,
	USB_BULK_BUFFER_MODE_TX_START = 1,
	USB_BULK_BUFFER_MODE_TX_RUN = 2,
	USB_BULK_BUFFER_MODE_RX = 3,
};

struct usb_bulk_buffer_registers {
	uint32_t mode;
	uint32_t m0_count;
	uint32_t m4_count;
	uint32_t max_buf_margin;
	uint32_t min_buf_margin;
	uint32_t num_shortfalls;
	uint32_t longest_shortfall;
	uint32_t shortfall_limit;
};

extern volatile struct usb_bulk_buffer_registers usb_bulk_buffer_registers;

extern bool usb_bulk_buffer_tx;

#endif/*__USB_BULK_BUFFER_H__*/
