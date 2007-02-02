/*
	Register usages:
	
	r4-r5: Nes/Snes controller latest read bytes (r4 filled first)
	
	r6: Temporary register for non-interrupt context
	r17: Loop counter for reading from controller
	r18: Temporary storage while reading from controller

*/

#include <avr/io.h>

.global main
.global SIG_INTERRUPT0

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

SIG_INTERRUPT0:
	nop
	reti


	/*  -- PORTC --
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
	 */
main:

	/* Configure Latch and Clock as outputs and
	   enable pull-ups on inputs/unused pis, 
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
	   compatible adapter */
	ldi r16, 0xfb 	/* 1111 1011 */
	out IO_PORTD, r16
	ldi r16, 0x00
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
	rcall delay_6us_loop
	rcall delay_6us_loop	
	ldi r16, CLK_H_LATCH_L
	out IO_PORTC, r16	
	rcall delay_6us_loop

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

	rcall delay_6us_loop

	ldi r16, CLK_H_LATCH_L
	out IO_PORTC, r16

	rcall delay_6us_loop

	dec r17
	brne r8bits_lp
	
	ret

	/*************************************************************
	 * Subroutine which busy-loops for 6 microseconds (at 12 mhz)
	 *************************************************************/
delay_6us:
	/* At 12 Mhz, 1us is 12 cycle so 6 us is 72 cycles... */
	ldi r16, 22
delay_6us_loop:
	dec r16				/* 1 */
	brne delay_6us_loop	/* 2 when taken */
	ret

	
	/*************************************************************
	 * Subroutine which busy-loops for 16 milliseconds (at 12 mhz)
	 *************************************************************/
delay_16ms: 
	push r17
	/* or 16 000 us. We need to waste 192000 cycles.
	  Inner loop here has approx 2550 cycles. 192000/2550 = 75 so
	  we need to run it 75 times. */
	ldi r17, 75
	ldi r16, 0xff
delay_16ms_lp:
	dec r17
	breq delay_16ms_done
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	dec r16
	brne delay_16ms_lp
delay_16ms_done:
	pop r17
	ret
	


