#include <avr/io.h>

.global main
.global SIG_INTERRUPT0

#define IO_PORTD _SFR_IO_ADDR(PORTD)
#define IO_DDRD _SFR_IO_ADDR(DDRD)
#define IO_PORTC _SFR_IO_ADDR(PORTC)
#define IO_DDRC _SFR_IO_ADDR(DDRC)
#define IO_PORTB _SFR_IO_ADDR(PORTB)
#define IO_DDRB _SFR_IO_ADDR(DDRB)

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
	 * 2: Int0 (GC Data In (open collector))
	 */
main:

	ldi r16, 0x30
	out IO_PORTC, r16


	ret

