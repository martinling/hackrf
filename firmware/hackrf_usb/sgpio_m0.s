/*
 * This file is part of GreatFET
 *
 * Specialized SGPIO interrupt handler for Rhododendron.
 */


// Constants that point to registers we'll need to modify in the SGPIO block.
.equ SGPIO_REGISTER_BLOCK_BASE,            0x40101000
.equ SGPIO_SHADOW_REGISTERS_BASE,          0x40101100
.equ SGPIO_EXCHANGE_INTERRUPT_CLEAR_REG,   0x40101F30
.equ SGPIO_EXCHANGE_INTERRUPT_STATUS_REG,  0x40101F2C
.equ SGPIO_GPIO_INPUT,                     0x40101210


// Buffer that we're funneling data to/from.
.equ TARGET_DATA_BUFFER,                   0x20008000
.equ TARGET_BUFFER_MODE,                   0x20007000
.equ TARGET_BUFFER_M0_COUNT,               0x20007004
.equ TARGET_BUFFER_M4_COUNT,               0x20007008
.equ TARGET_BUFFER_TX_MAX_BUF_BYTES,       0x2000700C
.equ TARGET_BUFFER_TX_MIN_BUF_BYTES,       0x20007010
.equ TARGET_BUFFER_TX_NUM_UNDERRUNS,       0x20007014
.equ TARGET_BUFFER_TX_MAX_UNDERRUN,        0x20007018

.equ TARGET_BUFFER_MASK,                   0x7fff

.equ MODE_IDLE,                            0
.equ MODE_TX_START,                        1
.equ MODE_TX_RUN,                          2
.equ MODE_RX,                              3

.global main
.thumb_func
main:
	// Initialise registers used for persistent state.
	mov r0, #0	// r0 = 0
	mov r12, r0	// r12 = underrun_length = 0
loop:
	// Spin until we're ready to handle an SGPIO packet:
	// Grab the exchange interrupt staus...
	ldr r0, =SGPIO_EXCHANGE_INTERRUPT_STATUS_REG
	ldr r0, [r0]

	// ... check to see if it has any interrupt bits set...
	lsr r0, #1

	// ... and if not, jump back to the beginning.
	bcc loop

	// Clear the interrupt pending bits for the SGPIO slices we're working with.
	ldr r0, =SGPIO_EXCHANGE_INTERRUPT_CLEAR_REG
	ldr r1, =0xffff
	str r1, [r0]

	// Grab the base address of the SGPIO shadow registers...
	ldr r7, =SGPIO_SHADOW_REGISTERS_BASE

	// ... and grab the address of the buffer segment we want to write to / read from.
	ldr r0, =TARGET_DATA_BUFFER       // r0 = &buffer
	ldr r1, =TARGET_BUFFER_M0_COUNT   // r1 = &m0_count
	ldr r2, =TARGET_BUFFER_MASK       // r2 = mask
	ldr r3, [r1]                      // r3 = m0_count
	and r2, r3, r2                    // r2 = position_in_buffer = m0_count & mask
	add r6, r0, r2                    // r6 = buffer_target = &buffer + position_in_buffer

	mov r8, r1                        // Store &m0_count
	mov r9, r3                        // Store m0_count

	// Our slice chain is set up as follows (ascending data age; arrows are reversed for flow):
	//     L  -> F  -> K  -> C -> J  -> E  -> I  -> A
	// Which has equivalent shadow register offsets:
	//     44 -> 20 -> 40 -> 8 -> 36 -> 16 -> 32 -> 0

	// Load mode
	ldr r4, =TARGET_BUFFER_MODE	// r4 = &mode
	ldr r5, [r4]			// r5 = mode

	// Idle?
	cmp r5, #MODE_IDLE		// if mode == IDLE:
	beq main			//	goto main

	// RX?
	cmp r5, #MODE_RX		// if mode == RX:
	beq direction_rx		//	goto direction_rx

	// Otherwise in TX start/run.

	// Check for TX underrun.
	ldr r0, =TARGET_BUFFER_M4_COUNT   // r0 = &m4_count
	ldr r1, [r0]                      // r1 = m4_count
	sub r1, r3                        // r1 = bytes_available = m4_count - m0_count
	mov r10, r1                       // r10 = bytes_available
	cmp r1, #32                       // if bytes_available <= 32:
	ble tx_zeros                      //     goto tx_zeros

	// If still in TX start mode, switch to TX run.
	cmp r5, #MODE_TX_RUN		// if mode == TX_RUN:
	beq tx_write			//	goto tx_write
	mov r5, #MODE_TX_RUN 		// r5 = MODE_TX_RUN
	str r5, [r4]			// mode = MODE_TX_RUN

tx_write:
	ldm r6!, {r0-r5}
	str r0,  [r7, #44]
	str r1,  [r7, #20]
	str r2,  [r7, #40]
	str r3,  [r7, #8 ]
	str r4,  [r7, #36]
	str r5,  [r7, #16]

	ldm r6!, {r0-r1}
	str r0,  [r7, #32]
	str r1,  [r7, #0]

	// Not in underrun, so zero underrun length.
	mov r0, #0
	mov r12, r0

	// Update max/min levels in buffer stats.
	ldr r0, =TARGET_BUFFER_TX_MAX_BUF_BYTES	// r0 = &max_bytes
	ldr r1, =TARGET_BUFFER_TX_MIN_BUF_BYTES // r1 = &min_bytes
	ldr r2, [r0]				// r2 = max_bytes
	ldr r3, [r1]				// r3 = min_bytes
	mov r4, r10				// r4 = bytes_available
	cmp r4, r2				// if bytes_available <= max_bytes:
	ble check_min				//	goto check_min
	str r4, [r0]				// max_bytes = bytes_available
check_min:
	cmp r4, r3				// if bytes_available >= min_bytes:
	bge done				//	goto done
	str r4, [r1]				// min_bytes = bytes_available

	b done

tx_zeros:

	mov r0, #0
	str r0,  [r7, #44]
	str r0,  [r7, #20]
	str r0,  [r7, #40]
	str r0,  [r7, #8 ]
	str r0,  [r7, #36]
	str r0,  [r7, #16]
	str r0,  [r7, #32]
	str r0,  [r7, #0 ]

	// If still in TX start mode, don't count as underrun.
	cmp r5, #MODE_TX_START
	beq loop

	// Otherwise, update stats for underrun.
	ldr r1, =TARGET_BUFFER_TX_MIN_BUF_BYTES	// r1 = &min_bytes
	str r0, [r1]				// min_bytes = 0

	// Add to the length of the current underrun.
	mov r0, r12				// r0 = underrun_length
	add r0, #32				// r0 = underrun_length + 32
	mov r12, r0				// underrun_length = underrun_length + 32

	// Is the new underrun length the new maximum?
	ldr r1, =TARGET_BUFFER_TX_MAX_UNDERRUN	// r1 = &max_underrun
	ldr r2, [r1]				// r2 = max_underrun
	cmp r0, r2				// if underrun_length <= max_underrun:
	ble check_length			//	goto check_length
	str r0, [r1]				// max_underrun = underrun_length

check_length:
	// If we already in underrun, skip incrementing the count of underruns.
	cmp r0, #32				// if underrun_length > 32:
	bgt loop				//	goto loop

	// Otherwise, this is a new underrun.
	ldr r0, =TARGET_BUFFER_TX_NUM_UNDERRUNS	// r0 = &num_underruns
	ldr r1, [r0]				// r1 = num_underruns
	add r1, #1				// r1 = num_underruns + 1
	str r1, [r0]				// num_underruns = num_underruns + 1

	b loop

direction_rx:

	// 8 cycles
	ldr r0,  [r7, #44] // 2
	ldr r1,  [r7, #20] // 2
	ldr r2,  [r7, #40] // 2
	ldr r3,  [r7, #8 ] // 2
	ldr r4,  [r7, #36] // 2
	ldr r5,  [r7, #16] // 2
	stm r6!, {r0-r5}   // 7

	// 6 cycles
	ldr r0,  [r7, #32] // 2
	ldr r1,  [r7, #0]  // 2
	stm r6!, {r0-r1}

done:

	// Finally, update the count...
	mov r0, r8             // r0 = &m0_count
	mov r1, r9             // r1 = m0_count
	add r1, r1, #32        // r1 = m0_count + size_copied
	str r1, [r0]           // m0_count = m0_count + size_copied

	b loop
