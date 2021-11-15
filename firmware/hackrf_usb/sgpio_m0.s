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
.equ MODE_RX,                              1
.equ MODE_TX_START,                        2
.equ MODE_TX_RUN,                          3

.global main
.thumb_func

/*
	This code has tight timing constraints.

	We have to complete a read or write from SGPIO every 163 cycles.

	The CPU clock is 204MHz. We exchange 32 bytes at a time in the SGPIO registers, which
	is 16 samples worth of IQ data. At the maximum sample rate of 20MHz, the SGPIO update
	rate is 20 / 16 = 1.25MHz. So we have 204 / 1.25 = 163.2 cycles available.

	Access to the SGPIO peripheral is slow, due to the asynchronous bridge that connects
	it to the AHB bus matrix. Section 20.4.1 of the LPC43xx user manual (UM10503) specifies
	the access latencies as:

	Read:  4 x MCLK + 4 x CLK_PERIPH_SGPIO
	Write: 4 x MCLK + 2 x CLK_PERIPH_SGPIO

	In our case both these clocks are at 204MHz so reads add 8 cycles and writes add 6.
	These are latencies that add to the usual M0 instruction timings, so an ldr from SGPIO
	takes 10 cycles, and an str to SGPIO takes 8 cycles.
*/

main:												// Cycle counts:
	// Initialise registers used for persistent state.
	mov r0, #0	// r0 = 0								// 1
	mov r12, r0	// r12 = shortfall_length = 0						// 1
loop:
	// Spin until we're ready to handle an SGPIO packet:
	// Grab the exchange interrupt staus...
	ldr r0, =SGPIO_EXCHANGE_INTERRUPT_STATUS_REG						// 2
	ldr r0, [r0]										// 2

	// ... check to see if it has any interrupt bits set...
	lsr r0, #1										// 1

	// ... and if not, jump back to the beginning.
	bcc loop										// 1 thru, 3 taken

	// Clear the interrupt pending bits for the SGPIO slices we're working with.
	ldr r0, =SGPIO_EXCHANGE_INTERRUPT_CLEAR_REG						// 2
	ldr r1, =0xffff										// 2
	str r1, [r0]										// 2

	// Grab the base address of the SGPIO shadow registers...
	ldr r7, =SGPIO_SHADOW_REGISTERS_BASE							// 2

	// ... and grab the address of the buffer segment we want to write to / read from.
	ldr r0, =TARGET_DATA_BUFFER	// r0 = &buffer						// 2
	ldr r1, =REG_M0_COUNT		// r1 = &m0_count					// 2
	ldr r2, =BUF_SIZE_MASK		// r2 = mask						// 2
	ldr r3, [r1]			// r3 = m0_count					// 2
	and r2, r3, r2			// r2 = position_in_buffer = m0_count & mask		// 1
	add r6, r0, r2			// r6 = buffer_target = &buffer + position_in_buffer	// 1

	mov r8, r1			// Store &m0_count					// 1
	mov r9, r3			// Store m0_count					// 1

	// Our slice chain is set up as follows (ascending data age; arrows are reversed for flow):
	//     L  -> F  -> K  -> C -> J  -> E  -> I  -> A
	// Which has equivalent shadow register offsets:
	//     44 -> 20 -> 40 -> 8 -> 36 -> 16 -> 32 -> 0

	// Load mode
	ldr r4, =REG_MODE		// r4 = &mode						// 2
	ldr r5, [r4]			// r5 = mode						// 2

	// Branch for idle or TX mode.
	cmp r5, #MODE_RX		// if mode < RX:					// 1
	blt main			//	goto main					// 1 thru, 3 taken
	bgt tx				// else if mode > RX: goto tx				// 1 thru, 3 taken

	// Otherwise, in RX mode.

	// Check for RX overrun.
	ldr r0, =REG_M4_COUNT		// r0 = &m4_count					// 2
	ldr r1, [r0]			// r1 = m4_count					// 2
	sub r3, r1			// r3 = bytes_used = m0_count - m4_count		// 1
	ldr r2, =BUF_SIZE		// r2 = buf_size					// 2
	sub r2, r3			// r2 = bytes_available = buf_size - bytes_used		// 1
	mov r10, r2			// r10 = bytes_available				// 1
	cmp r2, #32			// if bytes_available <= 32:				// 1
	ble shortfall			//     goto shortfall					// 1 thru, 3 taken

	ldr r0,  [r7, #44] 									// 10
	ldr r1,  [r7, #20] 									// 10
	ldr r2,  [r7, #40] 									// 10
	ldr r3,  [r7, #8 ] 									// 10
	stm r6!, {r0-r3}   									// 5

	ldr r0,  [r7, #36] 									// 10
	ldr r1,  [r7, #16] 									// 10
	ldr r2,  [r7, #32] 									// 10
	ldr r3,  [r7, #0]  									// 10
	stm r6!, {r0-r3}									// 5

chunk_successful:
	// Not in shortfall, so zero shortfall length.
	mov r0, #0										// 1
	mov r12, r0										// 1

	// Update max/min levels in buffer stats.
	ldr r0, =REG_MAX_BUF_MARGIN	// r0 = &max_margin					// 2
	ldr r1, =REG_MIN_BUF_MARGIN	// r1 = &min_margin					// 2
	ldr r2, [r0]			// r2 = max_margin					// 2
	ldr r3, [r1]			// r3 = min_margin					// 2
	mov r4, r10			// r4 = bytes_available					// 1
	cmp r4, r2			// if bytes_available <= max_margin:			// 1
	ble check_min			//	goto check_min					// 1 thru, 3 taken
	str r4, [r0]			// max_margin = bytes_available				// 2
check_min:
	cmp r4, r3			// if bytes_available >= min_margin:			// 1
	bge update_count		//	goto update_count				// 1 thru, 3 taken
	str r4, [r1]			// min_margin = bytes_available				// 2

update_count:
	// Finally, update the count...
	mov r0, r8             // r0 = &m0_count						// 1
	mov r1, r9             // r1 = m0_count							// 1
	add r1, r1, #32        // r1 = m0_count + size_copied					// 1
	str r1, [r0]           // m0_count = m0_count + size_copied				// 2

	b loop											// 3

tx:
	// Check for TX underrun.
	ldr r0, =REG_M4_COUNT		// r0 = &m4_count					// 2
	ldr r1, [r0]			// r1 = m4_count					// 2
	sub r1, r3			// r1 = bytes_available = m4_count - m0_count		// 1
	mov r10, r1			// r10 = bytes_available				// 1
	cmp r1, #32			// if bytes_available <= 32:				// 1
	ble tx_zeros			//     goto tx_zeros					// 1 thru, 3 taken

	// If still in TX start mode, switch to TX run.
	cmp r5, #MODE_TX_RUN		// if mode == TX_RUN:					// 1
	beq tx_write			//	goto tx_write					// 1 thru, 3 taken
	mov r5, #MODE_TX_RUN 		// r5 = MODE_TX_RUN					// 1
	str r5, [r4]			// mode = MODE_TX_RUN					// 2

tx_write:
	ldm r6!, {r0-r3}									// 5
	str r0,  [r7, #44]									// 8
	str r1,  [r7, #20]									// 8
	str r2,  [r7, #40]									// 8
	str r3,  [r7, #8 ]									// 8

	ldm r6!, {r0-r3}									// 5
	str r0,  [r7, #36]									// 8
	str r1,  [r7, #16]									// 8
	str r2,  [r7, #32]									// 8
	str r3,  [r7, #0]									// 8

	b chunk_successful									// 3

tx_zeros:

	mov r0, #0										// 1
	str r0,  [r7, #44]									// 8
	str r0,  [r7, #20]									// 8
	str r0,  [r7, #40]									// 8
	str r0,  [r7, #8 ]									// 8
	str r0,  [r7, #36]									// 8
	str r0,  [r7, #16]									// 8
	str r0,  [r7, #32]									// 8
	str r0,  [r7, #0 ]									// 8

	// If still in TX start mode, don't count as underrun.
	cmp r5, #MODE_TX_START									// 1
	beq loop										// 1 thru, 3 taken

shortfall:
	ldr r1, =REG_MIN_BUF_MARGIN		// r1 = &min_margin				// 2
	mov r0, #0				// r0 = 0					// 1
	str r0, [r1]				// min_margin = 0				// 2

	// Add to the length of the current shortfall.
	mov r0, r12				// r0 = shortfall_length			// 1
	add r0, #32				// r0 = shortfall_length + 32			// 1
	mov r12, r0				// shortfall_length = shortfall_length + 32	// 1

	// Is the new shortfall length the new maximum?
	ldr r1, =REG_LONGEST_SHORTFALL		// r1 = &longest_shortfall			// 2
	ldr r2, [r1]				// r2 = longest_shortfall			// 2
	cmp r0, r2				// if shortfall_length <= longest_shortfall:	// 1
	ble check_length			//	goto check_length			// 1 thru, 3 taken
	str r0, [r1]				// longest_shortfall = shortfall_length		// 2

	// Is the new shortfall length enough to trigger a timeout?
	ldr r1, =REG_SHORTFALL_LIMIT		// r1 = &shortfall_limit			// 2
	ldr r2, [r1]				// r2 = shortfall_limit				// 2
	cmp r0, r2				// if shortfall_length < shortfall_limit:	// 1
	blt check_length			//	goto check_length			// 1 thru, 3 taken
	mov r5, #MODE_IDLE			// r5 = MODE_IDLE				// 1
	str r5, [r4]				// mode = MODE_IDLE				// 2

check_length:
	// If we already in shortfall, skip incrementing the count of shortfalls.
	cmp r0, #32				// if shortfall_length > 32:			// 1
	bgt loop				//	goto loop				// 1 thru, 3 taken

	// Otherwise, this is a new shortfall.
	ldr r0, =REG_NUM_SHORTFALLS		// r0 = &num_shortfalls				// 2
	ldr r1, [r0]				// r1 = num_shortfalls				// 2
	add r1, #1				// r1 = num_shortfalls + 1			// 1
	str r1, [r0]				// num_shortfalls = num_shortfalls + 1		// 2

	b loop											// 3
