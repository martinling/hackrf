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
.equ BUF_SIZE,                             0x8000
.equ BUF_SIZE_MASK,                        0x7fff

.equ REG_MODE,                             0x20007000
.equ REG_M0_COUNT,                         0x20007004
.equ REG_M4_COUNT,                         0x20007008
.equ REG_MAX_BUF_MARGIN,                   0x2000700C
.equ REG_MIN_BUF_MARGIN,                   0x20007010
.equ REG_NUM_SHORTFALLS,                   0x20007014
.equ REG_LONGEST_SHORTFALL,                0x20007018
.equ REG_SHORTFALL_LIMIT,                  0x2000701C

.equ MODE_IDLE,                            0
.equ MODE_TX_START,                        1
.equ MODE_TX_RUN,                          2
.equ MODE_RX,                              3

.global main
.thumb_func
main:
	// Initialise registers used for persistent state.
	mov r0, #0	// r0 = 0
	mov r12, r0	// r12 = shortfall_length = 0
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
	ldr r0, =TARGET_DATA_BUFFER	// r0 = &buffer
	ldr r1, =REG_M0_COUNT		// r1 = &m0_count
	ldr r2, =BUF_SIZE_MASK		// r2 = mask
	ldr r3, [r1]			// r3 = m0_count
	and r2, r3, r2			// r2 = position_in_buffer = m0_count & mask
	add r6, r0, r2			// r6 = buffer_target = &buffer + position_in_buffer

	mov r8, r1			// Store &m0_count
	mov r9, r3			// Store m0_count

	// Our slice chain is set up as follows (ascending data age; arrows are reversed for flow):
	//     L  -> F  -> K  -> C -> J  -> E  -> I  -> A
	// Which has equivalent shadow register offsets:
	//     44 -> 20 -> 40 -> 8 -> 36 -> 16 -> 32 -> 0

	// Load mode
	ldr r4, =REG_MODE		// r4 = &mode
	ldr r5, [r4]			// r5 = mode

	// Idle?
	cmp r5, #MODE_IDLE		// if mode == IDLE:
	beq main			//	goto main

	// RX?
	cmp r5, #MODE_RX		// if mode == RX:
	beq direction_rx		//	goto direction_rx

	// Otherwise in TX start/run.

	// Check for TX underrun.
	ldr r0, =REG_M4_COUNT		// r0 = &m4_count
	ldr r1, [r0]			// r1 = m4_count
	sub r1, r3			// r1 = bytes_available = m4_count - m0_count
	mov r10, r1			// r10 = bytes_available
	cmp r1, #32			// if bytes_available <= 32:
	ble tx_zeros			//     goto tx_zeros

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

	b chunk_successful

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

shortfall:
	ldr r1, =REG_MIN_BUF_MARGIN		// r1 = &min_margin
	mov r0, #0				// r0 = 0
	str r0, [r1]				// min_margin = 0

	// Add to the length of the current shortfall.
	mov r0, r12				// r0 = shortfall_length
	add r0, #32				// r0 = shortfall_length + 32
	mov r12, r0				// shortfall_length = shortfall_length + 32

	// Is the new shortfall length the new maximum?
	ldr r1, =REG_LONGEST_SHORTFALL		// r1 = &longest_shortfall
	ldr r2, [r1]				// r2 = longest_shortfall
	cmp r0, r2				// if shortfall_length <= longest_shortfall:
	ble check_length			//	goto check_length
	str r0, [r1]				// longest_shortfall = shortfall_length

	// Is the new shortfall length enough to trigger a timeout?
	ldr r1, =REG_SHORTFALL_LIMIT		// r1 = &shortfall_limit
	ldr r2, [r1]				// r2 = shortfall_limit
	cmp r0, r2				// if shortfall_length < shortfall_limit:
	blt check_length			//	goto check_length
	mov r5, #MODE_IDLE			// r5 = MODE_IDLE
	str r5, [r4]				// mode = MODE_IDLE

check_length:
	// If we already in shortfall, skip incrementing the count of shortfalls.
	cmp r0, #32				// if shortfall_length > 32:
	bgt loop				//	goto loop

	// Otherwise, this is a new shortfall.
	ldr r0, =REG_NUM_SHORTFALLS		// r0 = &num_shortfalls
	ldr r1, [r0]				// r1 = num_shortfalls
	add r1, #1				// r1 = num_shortfalls + 1
	str r1, [r0]				// num_shortfalls = num_shortfalls + 1

	b loop

direction_rx:
	// Check for RX overrun.
	ldr r0, =REG_M4_COUNT		// r0 = &m4_count
	ldr r1, [r0]			// r1 = m4_count
	sub r3, r1			// r3 = bytes_used = m0_count - m4_count
	ldr r2, =BUF_SIZE		// r2 = buf_size
	sub r2, r3			// r2 = bytes_available = buf_size - bytes_used
	mov r10, r2			// r10 = bytes_available
	cmp r2, #32			// if bytes_available <= 32:
	ble shortfall			//     goto shortfall

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

chunk_successful:
	// Not in shortfall, so zero shortfall length.
	mov r0, #0
	mov r12, r0

	// Update max/min levels in buffer stats.
	ldr r0, =REG_MAX_BUF_MARGIN	// r0 = &max_margin
	ldr r1, =REG_MIN_BUF_MARGIN	// r1 = &min_margin
	ldr r2, [r0]			// r2 = max_margin
	ldr r3, [r1]			// r3 = min_margin
	mov r4, r10			// r4 = bytes_available
	cmp r4, r2			// if bytes_available <= max_margin:
	ble check_min			//	goto check_min
	str r4, [r0]			// max_margin = bytes_available
check_min:
	cmp r4, r3			// if bytes_available >= min_margin:
	bge update_count		//	goto update_count
	str r4, [r1]			// min_margin = bytes_available

update_count:
	// Finally, update the count...
	mov r0, r8             // r0 = &m0_count
	mov r1, r9             // r1 = m0_count
	add r1, r1, #32        // r1 = m0_count + size_copied
	str r1, [r0]           // m0_count = m0_count + size_copied

	b loop
