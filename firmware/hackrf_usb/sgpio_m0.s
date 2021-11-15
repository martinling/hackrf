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

	There are four code paths through the loop, with the following worst-case timings:

	RX, normal:	145 cycles
	RX, overrun:	65 cycles
	TX, normal:	140 cycles
	TX, underrun:	131 cycles
*/

main:												// Cycle counts:
	// Initialise low registers with addresses that will be used with offsets.
	ldr r7, =SGPIO_EXCHANGE_INTERRUPT_BASE							// 2
	ldr r6, =SGPIO_SHADOW_REGISTERS_BASE							// 2
	ldr r5, =STATS_BASE									// 2

	// Initialise high registers used for constant values.
	ldr r0, =BUF_SIZE									// 2
	mov r11, r0										// 1
	ldr r0, =TARGET_DATA_BUFFER								// 2
	mov r10, r0										// 1
idle:
	// Initialise registers used for persistent state.
	mov r0, #0	// r0 = 0								// 1
	mov r12, r0	// r12 = shortfall_length = 0						// 1
loop:
	// Spin until we're ready to handle an SGPIO packet:
	// Grab the exchange interrupt staus...							//	1st:	2nd:
	ldr r0, [r7, #INT_STATUS]								// 2	2	8

	// ... check to see if it has any interrupt bits set...
	lsr r0, #1										// 1	3	9

	// ... and if not, jump back to the beginning.
	bcc loop										// 1-3	6	10

	// Clear the interrupt pending bits for the SGPIO slices we're working with.
	ldr r0, =0xffff										// 2	12
	str r0, [r7, #INT_CLEAR]								// 2	14

	// ... and grab the address of the buffer segment we want to write to / read from.
	ldr r4, =BUF_SIZE_MASK		// r4 = mask						// 2	16
	ldr r2, [r5, #M0_COUNT]		// r2 = m0_count					// 2	18
	and r4, r2, r4			// r4 = position_in_buffer = m0_count & mask		// 1	19
	add r4, r10, r4			// r4 = buffer_target = &buffer + position_in_buffer	// 1	20

	mov r8, r2			// r8 = m0_count					// 1	21

	// Our slice chain is set up as follows (ascending data age; arrows are reversed for flow):
	//     L  -> F  -> K  -> C -> J  -> E  -> I  -> A
	// Which has equivalent shadow register offsets:
	//     44 -> 20 -> 40 -> 8 -> 36 -> 16 -> 32 -> 0

	// Load mode
	ldr r3, [r5, #MODE]		// r3 = mode						// 2	23

	// Branch for idle or TX mode.
	cmp r3, #MODE_RX		// if mode < RX:					// 1	24
	blt idle			//	goto idle					// 1-3	25-27
	bgt tx				// else if mode > RX: goto tx				// 1-3	26-28

	// Otherwise, in RX mode.

rx:
	// Check for RX overrun.
	ldr r0, [r5, #M4_COUNT]		// r0 = m4_count					// 2	28
	sub r0, r2			// r0 = -bytes_used = m4_count - m0_count		// 1	29
	add r0, r11, r0			// r0 = bytes_available = buf_size + -bytes_used	// 1	30
	mov r9, r0			// r9 = bytes_available					// 1	31
	cmp r0, #32			// if bytes_available <= 32:				// 1	32
	ble shortfall			//     goto shortfall					// 1-3	33-35

	// Read data from SGPIO.
	ldr r0,  [r6, #44] 									// 10	43
	ldr r1,  [r6, #20] 									// 10	53
	ldr r2,  [r6, #40] 									// 10	63
	ldr r3,  [r6, #8 ] 									// 10	73
	stm r4!, {r0-r3}   									// 5	78

	ldr r0,  [r6, #36] 									// 10	88
	ldr r1,  [r6, #16] 									// 10	98
	ldr r2,  [r6, #32] 									// 10	108
	ldr r3,  [r6, #0]  									// 10	118
	stm r4!, {r0-r3}									// 5	123

chunk_successful:
	// Not in shortfall, so zero shortfall length.						//	RX:	TX:
	mov r0, #0										// 1	124	119
	mov r12, r0										// 1	125	120

	// Update max/min levels in buffer stats.
	ldr r0, [r5, #MAX_BUF_MARGIN]	// r0 = max_margin					// 2	127	122
	ldr r1, [r5, #MIN_BUF_MARGIN]	// r1 = min_margin					// 2	129	124
	mov r2, r9			// r2 = bytes_available					// 1	130	125
	cmp r2, r0			// if bytes_available <= max_margin:			// 1	131	126
	ble check_min			//	goto check_min					// 1-3	132-134	127-129
	str r2, [r5, #MAX_BUF_MARGIN]	// max_margin = bytes_available				// 2	134	129
check_min:
	cmp r2, r1			// if bytes_available >= min_margin:			// 1	135	130
	bge update_count		//	goto update_count				// 1-3	136-138	131-133
	str r2, [r5, #MIN_BUF_MARGIN]	// min_margin = bytes_available				// 2	138	133

update_count:
	// Finally, update the count...
	mov r0, r8             		// r0 = m0_count					// 1	139	134
	add r0, r0, #32        		// r0 = m0_count + size_copied				// 1	140	135
	str r0, [r5, #M0_COUNT]		// m0_count = m0_count + size_copied			// 2	142	137

	b loop											// 3	145	140

tx:
	// Check for TX underrun.
	ldr r0, [r5, #M4_COUNT]		// r0 = m4_count					// 2	30
	sub r0, r2			// r0 = bytes_available = m4_count - m0_count		// 1	31
	mov r9, r0			// r9 = bytes_available					// 1	32
	cmp r0, #32			// if bytes_available <= 32:				// 1	33
	ble tx_zeros			//     goto tx_zeros					// 1-3	34-36

	// If still in TX start mode, switch to TX run.
	cmp r3, #MODE_TX_RUN		// if mode == TX_RUN:					// 1	37
	beq tx_write			//	goto tx_write					// 1-3	38-40
	mov r3, #MODE_TX_RUN 		// r3 = MODE_TX_RUN					// 1	39
	str r3, [r5, #MODE]		// mode = MODE_TX_RUN					// 2	41

tx_write:
	ldm r4!, {r0-r3}									// 5	46
	str r0,  [r6, #44]									// 8	54
	str r1,  [r6, #20]									// 8	62
	str r2,  [r6, #40]									// 8	70
	str r3,  [r6, #8 ]									// 8	78

	ldm r4!, {r0-r3}									// 5	83
	str r0,  [r6, #36]									// 8	91
	str r1,  [r6, #16]									// 8	99
	str r2,  [r6, #32]									// 8	107
	str r3,  [r6, #0]									// 8	115

	b chunk_successful									// 3	118

tx_zeros:
	mov r0, #0										// 1	37
	str r0,  [r6, #44]									// 8	45
	str r0,  [r6, #20]									// 8	53
	str r0,  [r6, #40]									// 8	61
	str r0,  [r6, #8 ]									// 8	69
	str r0,  [r6, #36]									// 8	77
	str r0,  [r6, #16]									// 8	85
	str r0,  [r6, #32]									// 8	93
	str r0,  [r6, #0 ]									// 8	101

	// If still in TX start mode, don't count as underrun.
	cmp r3, #MODE_TX_START									// 1	102
	beq loop										// 1-3	103-105

shortfall:											// 	RX:	TX:
	mov r0, #0				// r0 = 0					// 1	36	104
	str r0, [r5, #MIN_BUF_MARGIN]		// min_margin = 0				// 2	38	106

	// Add to the length of the current shortfall.
	mov r1, r12				// r1 = shortfall_length			// 1	39	107
	add r1, #32				// r1 = shortfall_length + 32			// 1	40	108
	mov r12, r1				// shortfall_length = shortfall_length + 32	// 1	41	109

	// Is the new shortfall length the new maximum?
	ldr r2, [r5, #LONGEST_SHORTFALL]	// r1 = longest_shortfall			// 2	43	111
	cmp r1, r2				// if shortfall_length <= longest_shortfall:	// 1	44	112
	ble check_length			//	goto check_length			// 1-3	45-47	113-115
	str r1, [r5, #LONGEST_SHORTFALL]	// longest_shortfall = shortfall_length		// 2	47	115

	// Is the new shortfall length enough to trigger a timeout?
	ldr r2, [r5, #SHORTFALL_LIMIT]		// r1 = shortfall_limit				// 2	49	117
	cmp r1, r2				// if shortfall_length < shortfall_limit:	// 1	50	118
	blt check_length			//	goto check_length			// 1-3	51-53	119-121
	str r0, [r5, #MODE]			// mode = 0 = MODE_IDLE				// 2	53	121

check_length:
	// If we already in shortfall, skip incrementing the count of shortfalls.
	cmp r1, #32				// if shortfall_length > 32:			// 1	54	122
	bgt loop				//	goto loop				// 1-3	55-57	123-125

	// Otherwise, this is a new shortfall.
	ldr r2, [r5, #NUM_SHORTFALLS]		// r2 = num_shortfalls				// 2	59	125
	add r2, #1				// r2 = num_shortfalls + 1			// 1	60	126
	str r2, [r5, #NUM_SHORTFALLS]		// num_shortfalls = num_shortfalls + 1		// 2	62	128

	b loop											// 3	65	131
