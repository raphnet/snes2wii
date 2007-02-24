/*
	Register usages:

	r0: Constant 0

	r4-r5: Nes/Snes controller latest read bytes (r4 filled first)
	
	r16: Temporary register for non-interrupt context
	r17: Loop counter for reading from controller
	r18: Temporary storage while reading from controller


	r1: SREG backup in interrupt
	r2: return value for interrupt subs
	r19: Temporary register for interrupt context
	r20: Temporary register for interrupt context
	r23: Bit Counter for interrupt context

	r3: Set to non-zero after each interrupt, used to read from the slave
		controller immediately after each interrupt.
*/

#include <avr/io.h>

.lcomm gc_rx_buf, 24
.lcomm gc_tx_buf, 65	; reply is 64 bit + 1 stop bit

.text
.global main
.global SIG_INTERRUPT0
.global gc_rx_buf

#define IO_SREG	_SFR_IO_ADDR(SREG)
#define IO_PORTD _SFR_IO_ADDR(PORTD)
#define IO_DDRD _SFR_IO_ADDR(DDRD)
#define IO_PIND	_SFR_IO_ADDR(PIND)
#define IO_PORTC _SFR_IO_ADDR(PORTC)
#define IO_DDRC _SFR_IO_ADDR(DDRC)
#define IO_PINC _SFR_IO_ADDR(PINC)
#define IO_PORTB _SFR_IO_ADDR(PORTB)
#define IO_DDRB _SFR_IO_ADDR(DDRB)
#define IO_MCUCR _SFR_IO_ADDR(MCUCR)
#define IO_GICR	_SFR_IO_ADDR(GICR)

#define CLK_H_LATCH_H	0x30
#define CLK_H_LATCH_L	0x20
#define CLK_L_LATCH_L	0x00

#define DEBUG_PORTD_BIT 0x00	/* In PORTD */
#define GC_DATA_BIT		0x02	/* in PORTD */
#define GC_DATA_MASK	0x04	
#define DATA_FALL_TIMEOUT	0x15
#define DATA_RAISE_TIMEOUT	0x15 

/* Useful */
#define zl	r30
#define zh	r31

SIG_INTERRUPT0:
	in r1, IO_SREG
	ldi	r30, lo8(gc_rx_buf)
	ldi r31, hi8(gc_rx_buf)
	ldi r23, 24				/* We will receive a 24bit command */

	rjmp fell


readNextBit:
	ldi r19, DATA_FALL_TIMEOUT	/* setup a timeout */
waitFall:				
	dec r19					/* 1 */
	breq timeout			/* 1 */
	in r20, IO_PIND			/* 1 : read the input port */
	andi r20, GC_DATA_MASK	/* 1 : isolate the input bit */
	brne waitFall			/* 2 : if still high, loop */

	/* When we first jump to 'fell' (when the interrupt
	occurs), we have already wasted many cycles. Those
	delays are there to compensate and make sure we
	always sample the data line where we want. */
	nop
	nop
	nop
	nop
	nop
	nop
fell:

	/* Ok, so there is now a 0 on the wire. 
	  Worst case, we are at the 9th cycle.
	  Best case, we are at the 3rd cycle.

	  Lets assumbe we are at cycle 6.

	  cycle: 1-16 16-32 32-48 48-64
	   high:  0     1     1     1
	    low:  0     0     0     1

	  I check the pin on the 32th cycle which is 
	  the safest place. Assuming we are on the 6th cycle,
	  we need to waste 26 cycles. This is done by
	  adjusting the align_delay subroutine.
	*/

	rcall align_delay	/* waste enough cycles to be aligned on cycle 32 */
	sbi IO_PORTD, DEBUG_PORTD_BIT	/* DEBUG */
	in r20, IO_PIND				/* read the input port */
	cbi IO_PORTD, DEBUG_PORTD_BIT	/* DEBUG */
	andi r20, GC_DATA_MASK			/* isolate the data bit */
	st z+, r20						/* store the value */

	dec r23					; One less bit to receive...
	breq gotCommand

	ldi r19, DATA_RAISE_TIMEOUT
waitHigh:
	dec r19
	breq timeout
	in r20, IO_PIND
	andi r20, GC_DATA_MASK
	breq waitHigh			; Still high? Keep looping

	rjmp readNextBit

	/* At this point, we have read a full 24bit command. A document
	I found says that there is a 6ms second delay before a real gamecube
	controller responds. That leaves us a lot of time :) */
gotCommand:
	ldi	r30, lo8(gc_rx_buf)
	ldi r31, hi8(gc_rx_buf)
#if 0
	rcall conv8bytes8bits	/* places result in r2 */
	ldi r19, 0x40
	sub r19, r2
	brne unknown_cmd;
	
	rcall conv8bytes8bits
	ldi r19, 0x03
	sub r19, r2
	brne unknown_cmd
#endif
	/*  note: Last byte not checked... it contains a bit for rumble motor.. I'm 
	not sure about the others. I'd rather reply anyway than not doing it and
	having the console beleiving the controller is gone or failing... 
	rcall conv8bytes8bits
	ldi r19, 0x02
	*/

	rjmp buildAndSendPacket

timeout:
	/* If we had received only 9 bits, the command is possibly getID+status. We
	   _must_ respond to this if we want the console to detect us. 

	   r23 is a count-down from 24 during the receive phase so it should
	   contain a value of 15.. 
	*/
	ldi r19, 15
	sub r19, r23 
	brne interrupt_done

	/* TODO : Get ID + Status command is 0x00 + 1 stop bit. Check before
	replying... */
	rjmp buildAndSendIdPacket

unknown_cmd:
interrupt_done:
	inc r3				; when r3 is non-zero, mainloop reads one time from the
						; slave controller and clears this register.
	out IO_SREG, r1
	reti

align_delay:
	ldi r19, 3						/* 1 */
lp634534:	
	dec r19							/* 1 */
	brne lp634534					/* 2 */
	ret

buildAndSendIdPacket:
	rcall clrTxBuf
	
	/* My controller replies with this:

		  [   Device ID   ] [status] 
		  00001001 00000000 00100000 1
		      ^  ^                   ^
			  |  |                   +--- Stop bit
			  |  +-- 0: non standard controller, 1: Dolphin standard controller
			  +----- 0: N64, 1: Dolphin
	*/
	ldi r19, 1
	ldi	zl, lo8(gc_tx_buf)
	ldi zh, hi8(gc_tx_buf)
	adiw zl, 4
	st z, r19	; Dolphin
	adiw zl, 3
	st z, r19	; Dolphin
	adiw zl, 11
	st z, r19	; Mysterious status bit
	adiw zl, 6
	st z, r19	; Stop bit

	ldi	zl, lo8(gc_tx_buf)
	ldi zh, hi8(gc_tx_buf)
	ldi r23, 25
	rcall sendGCData
	rjmp interrupt_done



	/******************************************
		Build a 64bit data packet for the GC using
		the latest values from the snes controller
	******************************************/
buildAndSendPacket:
	rcall clrTxBuf

	ldi	zl, lo8(gc_tx_buf)
	ldi zh, hi8(gc_tx_buf)
	adiw zl, 3 ; first 3 bits are always 0

	ldi r19, 1	; used to set values in reply buffer

	/* Test each button/direciton bit from the controller, and set the
	  appropriate bytes in response. SNES bits are active low, GC bits are
	  active high. */
	sbrs r4, 4	/* SNES START */
	st z, r19	/* GC START */
	adiw zl, 1

	sbrs r4, 6	/* SNES Y */
	st z, r19	/* GC Y */
	adiw zl, 1

	sbrs r5, 6	/* SNES X */
	st z, r19	/* GC X */
	adiw zl, 1

	sbrs r4, 7	/* SNES B */
	st z, r19	/* GC B */
	adiw zl, 1

	sbrs r5, 7	/* SNES A */
	st z, r19	/* GC A */
	adiw zl, 1

	st z+, r19	/* This is the first bit of the 2nd byte. Always 1 */

	sbrs r5, 5	/* SNES L */
	st z, r19	/* GC L */
	adiw zl, 1

	sbrs r5, 4	/* SNES R */
	st z, r19	/* GC R */
	adiw zl, 1

	sbrs r4, 5	/* SNES SELECT */
	st z, r19	/* GC Z */
	adiw zl, 1

	sbrs r4, 3	/* SNES UP */
	st z, r19	/* GC UP */
	adiw zl, 1

	sbrs r4, 2	/* SNES DOWN */
	st z, r19	/* GC DOWN */
	adiw zl, 1

	sbrs r4, 0	/* SNES RIGHT */
	st z, r19	/* GC RIGHT */
	adiw zl, 1

	sbrs r4, 1	/* SNES LEFT */
	st z, r19	/* GC LEFT */
	adiw zl, 1

	/* Set the stop bit to 1 */
	ldi	zl, lo8(gc_tx_buf)
	ldi zh, hi8(gc_tx_buf)
	adiw zl, 64
	st z, r19	/* Stop bit. Always 1 */

	/* Send the packet */
	ldi	zl, lo8(gc_tx_buf)
	ldi zh, hi8(gc_tx_buf)
	ldi r23, 64
	rcall sendGCData
	rjmp interrupt_done

	/*********************************************
	Clear the 64 bytes of the transmission buffer
	FOR INTERRUPT CONTEXT
	*********************************************/
clrTxBuf:
	ldi	zl, lo8(gc_tx_buf)
	ldi zh, hi8(gc_tx_buf)

	; start by clearing all the reply buffer
	ldi r19, 65
lp342:
	clr r20
	st z+, r20
	dec r19
	brne lp342

	ret

	/************************************************
	* Send data using the N64/GC serial protocol which
	* is as follows:
	*   0          1
	*     __        _____
	* ____|       __|
	* ^   ^ ^     ^ ^   ^
	*  3us 1us    1us 3us
	*
	* To send a 1, the pin direction is set to input.
	* To send a 0, the pin direction is set to output. 
	*	(of course, it's value is preset to zero)
	* 
	* At 16 mhz, a 1us period is 16 cycles. Thus a 3us period
	* is 48 cycles.
	*
	* Number of bits to send is passed in r23
	* Z must point to first byte of data. Every byte
	* represents one bit (programming laziness..). A logic
	* 1 is sent when a byte is non-zero.
	* Used registers: r19, r20
	************************************************/
sendGCData:

lp_sendGCData_bits:
	ld r19, z+
	tst r19
	brne send1
	nop
send0:
	sbi IO_DDRD, GC_DATA_BIT	; Pull bus to 0 
	
	ldi r20, 15
lp_send0_3us:
	dec r20
	brne lp_send0_3us
	nop

	cbi IO_DDRD, GC_DATA_BIT	; Release bus to 1

	ldi r20, 2
lp_send0_1us:
	dec r20
	brne lp_send0_1us

	dec r23
	brne lp_sendGCData_bits

	ret

send1:
	sbi IO_DDRD, GC_DATA_BIT	; Pull bus to 0

	ldi r20, 4
lp_send1_1us:
	dec r20
	brne lp_send1_1us
	nop
	nop
	
	cbi IO_DDRD, GC_DATA_BIT	; Release bus to 1

	ldi r20, 12
lp_send1_3us:
	dec r20
	brne lp_send1_3us
	nop
	nop

	dec r23
	brne lp_sendGCData_bits

	ret

	/*************************************************
	* Read 8 bytes starting where Z currently points.
	* Non-zero bytes are considered 1, other 0. Result
	* is placed in r2. First byte corresponds to most
	* significative bit.
	* Uses: r23, r19
	*************************************************/
conv8bytes8bits:
	ldi r23, 8
	clr r2
lp1664:
	lsl r2
	ld r19, z+
	tst r19
	breq lp1664
	mov r19,r2
	ori r19, 0x01
	mov r2, r19
	dec r23
	brne lp1664
	ret	


	/*  -- PORTC --
	 * 7: NC
	 * 6: NC
	 * 5: SNES Clock out
	 * 4: SNES Latch out

	 * 3: Snes Data in
	 * 2: NC
	 * 1: NC
	 * 0: NC
	 *
	 * -- PORTB --
	 * 0: Jumpers common
	 * 1: JP0 
	 * 2: JP1
	 *
	 * -- PORTD --
	 * 2: Int0 (GC Data In (simulated open collector by toggling direction))
	 * 1: NC or Shorted with 0
	 * 0: Debug bit
	 */
main:
	clr r0

	/* Configure Latch and Clock as outputs and
	   enable pull-ups on inputs/unused pins, 
	   data normally high, latch normally low */
	ldi r16, 0xef	/* 1110 1111 */
	out IO_PORTC, r16
	ldi r16, 0x30	/* 0011 0000 */
	out IO_DDRC, r16

	/* Configure Jumpers as inputs with pull-ups. 
	   Other PORTB pins are ISP pins. Configure those
	   in the same way. */
	ldi r16, 0xff
	out IO_PORTB, r16
	ldi r16, 0x00
	out IO_DDRB, r16

	/* All PORTD as input with pullups everywhere, except
	   the Int0 (PD2) pin. The later must not have a pullup
	   for we dont want to send 5volts to the host (Gamecube, Wii or
	   compatible adapter. Bit0 is also reserved for debugging 
	   purposes. It is set as output, no pullup.  */
	ldi r16, 0xfa 	/* 1111 1010 */
	out IO_PORTD, r16
	ldi r16, 0x01	/* 0000 0001 */
	out IO_DDRD, r16

	/* Configure external interrupt INT0 (falling edge) */
	ldi r16, 0x02	/* 0000 0010 */ 
	out IO_MCUCR, r16
	ldi r16, 0x40	/* INT0 set */
	out IO_GICR, r16

#if 0
	/********* TESTING ********/
	ldi	r30, lo8(gc_tx_buf)
	ldi r31, hi8(gc_tx_buf)
	ldi r16, 0x01	; 1
	st z+, r16
	ldi r16, 0x01	; 2
	st z+, r16
	ldi r16, 0x01	; 3
	st z+, r16
	ldi r16, 0x00	; 4
	st z+, r16
	ldi r16, 0x00	; 5
	st z+, r16
	ldi r16, 0x01	; 6
	st z+, r16
	ldi r16, 0x00	; 7
	st z+, r16
	ldi r16, 0x00	; 8
	st z+, r16

lp123123:
	ldi	r30, lo8(gc_tx_buf)
	ldi r31, hi8(gc_tx_buf)
	ldi r23, 8
	rcall sendGCData 
	rcall delay_16ms
	rjmp lp123123

#endif
	
	sei
mainloop:
	/* A real Snes polls the controller at 60hz. But we
	poll the controller after each interrupt (our only
	interrupt source is when the gamecube sends us a
	command. */

//	tst r3				; set inside int handler
//	breq mainloop;
	
//	clr r3

	rcall readSnes
	rcall delay_16ms	; dont read the controller again too soon?
						; just in case some non-standard snes compatible
						; controller does not like this.

	rjmp mainloop


	/*******************************************************
	 * Subroutine which reads the status of an SNES controller
	 * into the r4 and r5 registers.
	 *******************************************************/
readSnes:
	push r17

	/* Latch the buttons output into the shift register */
	ldi r16, CLK_H_LATCH_H
	out IO_PORTC, r16
	rcall delay_6us
	rcall delay_6us
	ldi r16, CLK_H_LATCH_L
	out IO_PORTC, r16	
	rcall delay_6us
	
	/* Generate 8 clock pulses, reading data on the falling edge */
	rcall r8bits
	mov r4, r18
	rcall r8bits
	mov r5, r18

	pop r17
	ret

	/*****************************************************
	 * Subroutine which reads 8 bits from the controller
	 * Uses r17, r16
	 * Returns result in r18
	 *****************************************************/
r8bits:
	ldi r17, 8
	clr r18
r8bits_lp:
	lsl r18

	ldi r16, CLK_L_LATCH_L
	out IO_PORTC, r16

	in r16, IO_PINC
	andi r16, 0x08	/* mask the data bit */
	lsr r16
	lsr r16
	lsr r16
	or r18, r16

	rcall delay_6us

	ldi r16, CLK_H_LATCH_L
	out IO_PORTC, r16

	rcall delay_6us

	dec r17
	brne r8bits_lp
	
	ret

	/*************************************************************
	 * Subroutine which busy-loops for 6 microseconds (at 16 mhz)
	 *************************************************************/
delay_6us:
	/* At 16 Mhz, 1us is 16 cycle so 6 us is 96 cycles... */
	ldi r16, 30
delay_6us_loop:
	dec r16				/* 1 */
	brne delay_6us_loop	/* 2 when taken */
	ret

	
	/*************************************************************
	 * Subroutine which busy-loops for 16 milliseconds (at 16 mhz)
	 * (it is in fact tweaked for a 59.94hz update rate
	 *************************************************************/
delay_16ms: 
	push r17
	ldi r17, 103
delay_16ms_outer_lp:
	ldi r16, 0xff
delay_16ms_lp:
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	dec r16
	brne delay_16ms_lp

	nop
	nop
	nop
	nop

	dec r17
	brne delay_16ms_outer_lp
delay_16ms_done:
	pop r17
	ret
	

