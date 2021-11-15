/*
 * This file is part of GreatFET
 *
 * Specialized SGPIO interrupt handler for Rhododendron.
 */

// Base addresses of groups of SGPIO registers.
.equ SGPIO_SHADOW_REGISTERS_BASE,          0x40101100
.equ SGPIO_EXCHANGE_INTERRUPT_BASE,        0x40101F00

// Offsets into the interrupt control registers.
.equ INT_CLEAR,                            0x30
.equ INT_STATUS,                           0x2C

// Buffer that we're funneling data to/from.
.equ TARGET_DATA_BUFFER,                   0x20008000
.equ BUF_SIZE,                             0x8000
.equ BUF_SIZE_MASK,                        0x7fff

// Base address of the buffer statistics.
.equ STATS_BASE,                           0x20007000

// Offsets into the buffer statistics.
.equ MODE,                                 0x00
.equ M0_COUNT,                             0x04
.equ M4_COUNT,                             0x08
.equ MAX_BUF_MARGIN,                       0x0C
.equ MIN_BUF_MARGIN,                       0x10
.equ NUM_SHORTFALLS,                       0x14
.equ LONGEST_SHORTFALL,                    0x18
.equ SHORTFALL_LIMIT,                      0x1C

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
	// Initialise registers used for fixed addresses.
	ldr r7, =SGPIO_EXCHANGE_INTERRUPT_BASE							// 2
	ldr r6, =SGPIO_SHADOW_REGISTERS_BASE							// 2
	ldr r5, =STATS_BASE									// 2
idle:
	// Initialise registers used for persistent state.
	mov r0, #0	// r0 = 0								// 1
	mov r12, r0	// r12 = shortfall_length = 0						// 1
loop:
	// Spin until we're ready to handle an SGPIO packet:
	// Grab the exchange interrupt staus...
	ldr r0, [r7, #INT_STATUS]								// 2

	// ... check to see if it has any interrupt bits set...
	lsr r0, #1										// 1

	// ... and if not, jump back to the beginning.
	bcc loop										// 1 thru, 3 taken

	// Clear the interrupt pending bits for the SGPIO slices we're working with.
	ldr r0, =0xffff										// 2
	str r0, [r7, #INT_CLEAR]								// 2

	// ... and grab the address of the buffer segment we want to write to / read from.
	ldr r0, =TARGET_DATA_BUFFER	// r0 = &buffer						// 2
	ldr r1, =BUF_SIZE_MASK		// r1 = mask						// 2
	ldr r2, [r5, #M0_COUNT]		// r2 = m0_count					// 2
	and r1, r2, r1			// r1 = position_in_buffer = m0_count & mask		// 1
	add r4, r0, r1			// r4 = buffer_target = &buffer + position_in_buffer	// 1

	mov r8, r2			// r8 = m0_count					// 1

	// Our slice chain is set up as follows (ascending data age; arrows are reversed for flow):
	//     L  -> F  -> K  -> C -> J  -> E  -> I  -> A
	// Which has equivalent shadow register offsets:
	//     44 -> 20 -> 40 -> 8 -> 36 -> 16 -> 32 -> 0

	// Load mode
	ldr r3, [r5, #MODE]		// r3 = mode						// 2

	// Branch for idle or TX mode.
	cmp r3, #MODE_RX		// if mode < RX:					// 1
	blt idle			//	goto idle					// 1 thru, 3 taken
	bgt tx				// else if mode > RX: goto tx				// 1 thru, 3 taken

	// Otherwise, in RX mode.

rx:
	// Check for RX overrun.
	ldr r0, [r5, #M4_COUNT]		// r0 = m4_count					// 2
	sub r2, r0			// r2 = bytes_used = m0_count - m4_count		// 1
	ldr r1, =BUF_SIZE		// r1 = buf_size					// 2
	sub r1, r2			// r1 = bytes_available = buf_size - bytes_used		// 1
	mov r9, r1			// r9 = bytes_available					// 1
	cmp r1, #32			// if bytes_available <= 32:				// 1
	ble shortfall			//     goto shortfall					// 1 thru, 3 taken

	// Read data from SGPIO.
	ldr r0,  [r6, #44] 									// 10
	ldr r1,  [r6, #20] 									// 10
	ldr r2,  [r6, #40] 									// 10
	ldr r3,  [r6, #8 ] 									// 10
	stm r4!, {r0-r3}   									// 5

	ldr r0,  [r6, #36] 									// 10
	ldr r1,  [r6, #16] 									// 10
	ldr r2,  [r6, #32] 									// 10
	ldr r3,  [r6, #0]  									// 10
	stm r4!, {r0-r3}									// 5

chunk_successful:
	// Not in shortfall, so zero shortfall length.
	mov r0, #0										// 1
	mov r12, r0										// 1

	// Update max/min levels in buffer stats.
	ldr r0, [r5, #MAX_BUF_MARGIN]	// r0 = max_margin					// 2
	ldr r1, [r5, #MIN_BUF_MARGIN]	// r1 = min_margin					// 2
	mov r2, r9			// r2 = bytes_available					// 1
	cmp r2, r0			// if bytes_available <= max_margin:			// 1
	ble check_min			//	goto check_min					// 1 thru, 3 taken
	str r2, [r5, #MAX_BUF_MARGIN]	// max_margin = bytes_available				// 2
check_min:
	cmp r2, r1			// if bytes_available >= min_margin:			// 1
	bge update_count		//	goto update_count				// 1 thru, 3 taken
	str r2, [r5, #MIN_BUF_MARGIN]	// min_margin = bytes_available				// 2

update_count:
	// Finally, update the count...
	mov r0, r8             		// r0 = m0_count					// 1
	add r0, r0, #32        		// r0 = m0_count + size_copied				// 1
	str r0, [r5, #M0_COUNT]		// m0_count = m0_count + size_copied			// 2

	b loop											// 3

tx:
	// Check for TX underrun.
	ldr r0, [r5, #M4_COUNT]		// r0 = m4_count					// 2
	sub r0, r2			// r0 = bytes_available = m4_count - m0_count		// 1
	mov r9, r0			// r9 = bytes_available					// 1
	cmp r0, #32			// if bytes_available <= 32:				// 1
	ble tx_zeros			//     goto tx_zeros					// 1 thru, 3 taken

	// If still in TX start mode, switch to TX run.
	cmp r3, #MODE_TX_RUN		// if mode == TX_RUN:					// 1
	beq tx_write			//	goto tx_write					// 1 thru, 3 taken
	mov r3, #MODE_TX_RUN 		// r3 = MODE_TX_RUN					// 1
	str r3, [r5, #MODE]		// mode = MODE_TX_RUN					// 2

tx_write:
	ldm r4!, {r0-r3}									// 5
	str r0,  [r6, #44]									// 8
	str r1,  [r6, #20]									// 8
	str r2,  [r6, #40]									// 8
	str r3,  [r6, #8 ]									// 8

	ldm r4!, {r0-r3}									// 5
	str r0,  [r6, #36]									// 8
	str r1,  [r6, #16]									// 8
	str r2,  [r6, #32]									// 8
	str r3,  [r6, #0]									// 8

	b chunk_successful									// 3

tx_zeros:
	mov r0, #0										// 1
	str r0,  [r6, #44]									// 8
	str r0,  [r6, #20]									// 8
	str r0,  [r6, #40]									// 8
	str r0,  [r6, #8 ]									// 8
	str r0,  [r6, #36]									// 8
	str r0,  [r6, #16]									// 8
	str r0,  [r6, #32]									// 8
	str r0,  [r6, #0 ]									// 8

	// If still in TX start mode, don't count as underrun.
	cmp r3, #MODE_TX_START									// 1
	beq loop										// 1 thru, 3 taken

shortfall:
	mov r0, #0				// r0 = 0					// 1
	str r0, [r5, #MIN_BUF_MARGIN]		// min_margin = 0				// 2

	// Add to the length of the current shortfall.
	mov r1, r12				// r1 = shortfall_length			// 1
	add r1, #32				// r1 = shortfall_length + 32			// 1
	mov r12, r1				// shortfall_length = shortfall_length + 32	// 1

	// Is the new shortfall length the new maximum?
	ldr r2, [r5, #LONGEST_SHORTFALL]	// r1 = longest_shortfall			// 2
	cmp r1, r2				// if shortfall_length <= longest_shortfall:	// 1
	ble check_length			//	goto check_length			// 1 thru, 3 taken
	str r1, [r5, #LONGEST_SHORTFALL]	// longest_shortfall = shortfall_length		// 2

	// Is the new shortfall length enough to trigger a timeout?
	ldr r2, [r5, #SHORTFALL_LIMIT]		// r1 = shortfall_limit				// 2
	cmp r1, r2				// if shortfall_length < shortfall_limit:	// 1
	blt check_length			//	goto check_length			// 1 thru, 3 taken
	str r0, [r5, #MODE]			// mode = 0 = MODE_IDLE				// 2

check_length:
	// If we already in shortfall, skip incrementing the count of shortfalls.
	cmp r1, #32				// if shortfall_length > 32:			// 1
	bgt loop				//	goto loop				// 1 thru, 3 taken

	// Otherwise, this is a new shortfall.
	ldr r2, [r5, #NUM_SHORTFALLS]		// r2 = num_shortfalls				// 2
	add r2, #1				// r2 = num_shortfalls + 1			// 1
	str r2, [r5, #NUM_SHORTFALLS]		// num_shortfalls = num_shortfalls + 1		// 2

	b loop											// 3
