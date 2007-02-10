/*
	Register usages:

	r0: Constant 0

	r4-r5: Nes/Snes controller latest read bytes (r4 filled first)
	
	r16: Temporary register for non-interrupt context
	r17: Loop counter for reading from controller
	r18: Temporary storage while reading from controller


	r1: SREG backup in interrupt
	r19: Temporary register for interrupt context
	r20: Temporary register for interrupt context
	r23: Bit Counter for interrupt context
*/

#include <avr/io.h>

.lcomm gc_rx_buf, 24
.lcomm gc_tx_buf, 64

.text
.global main
.global SIG_INTERRUPT0
.global gc_rx_buf

#define IO_SREG	_SFR_IO_ADDR(SREG)
#define IO_PORTD _SFR_IO_ADDR(PORTD)
#define IO_DDRD _SFR_IO_ADDR(DDRD)
#define IO_PORTC _SFR_IO_ADDR(PORTC)
#define IO_DDRC _SFR_IO_ADDR(DDRC)
#define IO_PINC _SFR_IO_ADDR(PINC)
#define IO_PORTB _SFR_IO_ADDR(PORTB)
#define IO_DDRB _SFR_IO_ADDR(DDRB)
#define IO_MCUCR _SFR_IO_ADDR(MCUCR)

#define CLK_H_LATCH_H	0x30
#define CLK_H_LATCH_L	0x20
#define CLK_L_LATCH_L	0x00

#define DEBUG_PORTD_BIT 0x
#define DATA_FALL_TIMEOUT	0x3f
#define DATA_RAISE_TIMEOUT	0x3f

SIG_INTERRUPT0:
	in r1, IO_SREG
	ldi	r30, lo8(gc_rx_buf)
	ldi r31, hi8(gc_rx_buf)
	ldi r23, 24				/* We will receive a 24bit command */

	rjmp fell


readNextBit:
	ldi r19, DATA_FALL_TIMEOUT	/* setup a timeout */
waitFall:				
	dec r19				/* 1 */
	breq timeout		/* 1 */
	in r20, IO_PORTD	/* 1 : read the input port */
	andi r20, 0x04		/* 1 : isolate the input bit */
	brne waitFall		/* 2 : if still high, loop */
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

	cbi IO_PORTD, DEBUG_PORTD_BIT	/* 1 */
	rcall align_delay	/* waste enough cycles to be aligned on cycle 32 */

	in r19, IO_PORTD				/* read the input port */
	sbi IO_PORTD, DEBUG_PORTD_BIT	/* DEBUG */
	andi r19, 0x04					/* isolate the data bit */
	st z+, r19						/* store the value */

	dec r23
	breq gotCommand

	ldi r19, DATA_RAISE_TIMEOUT
waitHigh:
	dec r19
	breq timeout
	in r20, IO_PORTD
	andi r20, 0x04
	brne readNextBit

	/* At this point, we have read a full 24bit command. A document
	I found says that there is a 6ms second delay before a real gamecube
	controller responds. That leaves us a lot of time :) */
gotCommand:




timeout:
	/* Todo: If we had read exactly 8 bits, check
	for valid small commands (eg: detection) */



iterrupt_done:
	out IO_SREG, r1
	reti


align_delay:
	ldi r19, 6						/* 1 */
lp634534:	
	dec r19							/* 1 */
	brne lp634534					/* 2 */
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
	 * 1: NC or Shorted with 2
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
	ldi r16, 0x01
	out IO_DDRD, r16

	/* Configure external interrupt INT0 (falling edge) */
	ldi r16, 0x02	/* 0000 0010 */ 
	out IO_MCUCR, r16

mainloop:
	/* A real Snes polls the controller at 60hz */

	rcall readSnes
	rcall delay_16ms

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
	


