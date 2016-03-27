.data
.ascii "Snes2Wii version 1.4, (C) 2007-2015 Raphael Assenat <raph@raphnet.net>"
.ascii "Released under the GPL. See http://www.raphnet.net/electronique/x2wii/index_en.php"

;
;	snes2wii: AVR Microcontroller firmware for converting SNES/NES controller
;	          protocol to Nintendo Wii/Gamecube controller protocol.
;    Copyright (C) 2007  Raphael Assenat <raph@raphnet.net>
;
;    This program is free software; you can redistribute it and/or modify
;    it under the terms of the GNU General Public License as published by
;    the Free Software Foundation; either version 2 of the License, or
;    (at your option) any later version.
;
;    This program is distributed in the hope that it will be useful,
;    but WITHOUT ANY WARRANTY; without even the implied warranty of
;    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;    GNU General Public License for more details.
;
;    You should have received a copy of the GNU General Public License along
;    with this program; if not, write to the Free Software Foundation, Inc.,
;    51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
;
;	------------------------------------------------------------------------   
;
;	Register usages:
;
;	------ read only registers 
;		r0: Constant 0
;
;	------ registers shared between interrupt and non-interrupt context
;		r3: Set to non-zero after each interrupt, used to read from the slave
;		controller immediately after each interrupt.
;		r4-r5: Nes/Snes controller latest read bytes (r4 filled first)
;		r8: If not zero, report C stick pointing to the left instead of center
;		r9: Copy of r4
;		r10: Copy of r5
;		r6: When non-zero, swaps A and B nes buttons
;
;
;	------ registers for non-interrupt context
;		r2: Contains 0 in snes mode, non-zero in nes mode
;		r16: Temporary register for non-interrupt context
;		r17: Loop counter for reading from controller
;		r18: Temporary storage while reading from controller
;
;	------ Interrupt context registers (some are used before enabling interrupts though)
;		r1: SREG backup in interrupt. Faster than pushing it to stack.
;		r7: Variable. Non-zero: Send 80 bit reply instead of 64 bit reply.
;		r19: Temporary register for interrupt context
;		r20: Temporary register for interrupt context
;		r23: Bit Counter for interrupt context


#include <avr/io.h>

.lcomm id_status, 24	; reply to 0000 0000 1 (0x00)
.lcomm origins_buf, 80	; reply to 0100 0001 1 (0x41)
.lcomm gc_rx_buf, 24
.lcomm gc_tx_buf, 64	; reply is 64 bit + 1 stop bit
.lcomm gc_tx_buf_extra, 16	; for mysterious 80bit response

.text
.global main
.global INT0_vect
.global gc_rx_buf

#define HIGHRATE_POLLING

#define IO_SREG	_SFR_IO_ADDR(SREG)
#define IO_PORTD _SFR_IO_ADDR(PORTD)
#define IO_DDRD _SFR_IO_ADDR(DDRD)
#define IO_PIND	_SFR_IO_ADDR(PIND)
#define IO_PORTC _SFR_IO_ADDR(PORTC)
#define IO_DDRC _SFR_IO_ADDR(DDRC)
#define IO_PINC _SFR_IO_ADDR(PINC)
#define IO_PORTB _SFR_IO_ADDR(PORTB)
#define IO_DDRB _SFR_IO_ADDR(DDRB)
#define IO_PINB	_SFR_IO_ADDR(PINB)
#define IO_MCUCR _SFR_IO_ADDR(MCUCR)
#define IO_GICR	_SFR_IO_ADDR(GICR)
#define IO_GIFR	_SFR_IO_ADDR(GIFR)
#define IO_EIFR	_SFR_IO_ADDR(EIFR)
#define IO_EIMSK _SFR_IO_ADDR(EIMSK)

#define LATCH_BIT		4 /* In PORTC */
#define CLOCK_BIT		5 /* In PORTC */

#define DEBUG_PORTD_BIT 0x00	/* In PORTD */
#define GC_DATA_BIT		0x02	/* in PORTD */
#define GC_DATA_MASK	0x04	
#define DATA_FALL_TIMEOUT	0x10
#define DATA_RAISE_TIMEOUT	0x15 

; Useful
#define yl	r28
#define yh	r29
#define zl	r30
#define zh	r31

INT0_vect:
	in r1, IO_SREG
	ldi	zl, lo8(gc_rx_buf)
	ldi zh, hi8(gc_rx_buf)
	ldi r23, 24				; We will receive a 24bit command

	rjmp fell


readNextBit:
	ldi r19, DATA_FALL_TIMEOUT	; setup a timeout
waitFall:				
	dec r19						; 1
	breq timeout				; 1
	in r20, IO_PIND				; 1 : read the input port
	andi r20, GC_DATA_MASK		; 1 : isolate the input bit
	brne waitFall				; 2 : if still high, loop

	; When we first jump to 'fell' (when the interrupt
	; occurs), we have already wasted many cycles. Those
	; delays are there to compensate and make sure we
	; always sample the data line where we want.
	nop
	nop
	nop
	nop
	nop
	nop
fell:

	; Ok, so there is now a 0 on the wire. 
	;  Worst case, we are at the 9th cycle.
	;  Best case, we are at the 3rd cycle.
	;  Lets assumbe we are at cycle 6.

	;  cycle: 1-16 16-32 32-48 48-64
	;   high:  0     1     1     1
	;   low:  0     0     0     1

	;  I check the pin on the 32th cycle which is 
	;  the safest place. Assuming we are on the 6th cycle,
	;  we need to waste 26 cycles. This is done by
	;  adjusting the align_delay subroutine.

	rcall align_delay				; waste enough cycles to be aligned on cycle 32
;	sbi IO_PORTD, DEBUG_PORTD_BIT	; DEBUG
	nop
	in r20, IO_PIND					; read the input port
;	cbi IO_PORTD, DEBUG_PORTD_BIT	; DEBUG
	nop
	andi r20, GC_DATA_MASK			; isolate the data bit
	st z+, r20						; store the value

	dec r23							; One less bit to receive...
	breq gotCommand

	ldi r19, DATA_RAISE_TIMEOUT
waitHigh:
	dec r19
	breq timeout
	in r20, IO_PIND
	andi r20, GC_DATA_MASK
	breq waitHigh					; Still high? Keep looping

	rjmp readNextBit

	; At this point, we have read a full 24bit command. A document
	; I found says that there is a 6ms second delay before a real gamecube
	; controller responds. That leaves us a lot of time :)
gotCommand:
	ldi	zl, lo8(gc_rx_buf)
	ldi zh, hi8(gc_rx_buf)

	sbi IO_PORTD, DEBUG_PORTD_BIT	; DEBUG
	cbi IO_PORTD, DEBUG_PORTD_BIT	; DEBUG
	; note: Last byte not checked... it contains a bit for rumble motor.. I'm 
	; not sure about the others. I'd rather reply anyway than not doing it and
	; having the console beleiving the controller is gone or failing... 

	; 64 bit replies: 0x400300, 0x400302  ...
	; 80 bit replies: 0x420000, 0x420302

	; test only bit 6 (0x020000)
	ldd r7, Z+6

	rjmp buildAndSendPacket

timeout:
	;  If we had received only 9 bits, the command is possibly getID+status. We
	;   _must_ respond to this if we want the console to detect us. 
	;
	; r23 is a count-down from 24 during the receive phase so it should
	; contain a value of 15.. 
	ldi r19, 15
	sub r19, r23 
	brne interrupt_done

	ldi zl, lo8(gc_rx_buf)
	ldi zh, hi8(gc_rx_buf)

	; Commands: 0x00 = Get ID + Status, 0x40 = Get origins? 
	adiw zl, 1
	ld r19, z
	tst r19
	breq not_40
	rjmp sendOriginsPacket
not_40: ; probably 0x00
	rjmp sendIdPacket

unknown_cmd:
interrupt_done:
	inc r3				; when r3 is non-zero, mainloop reads one time from the
						; slave controller and clears this register.
	out IO_SREG, r1

	; Clear the interrupt flag to prevent re-entering the handler right away. When we
	; transmit data, it triggers interrupts....
#if defined(__AVR_ATmega8__)
	ldi r19, 0x40
	out IO_GIFR, r19
#elif defined(__AVR_ATmega168__)
	ldi r19, 0x01
	out IO_EIFR, r19
#else
#error MCU not supported
#endif

	reti

align_delay:
	ldi r19, 3
lp634534:
	dec r19
	brne lp634534
	ret

sendIdPacket:
	ldi	zl, lo8(id_status)
	ldi zh, hi8(id_status)
	ldi r23, 24
	rcall sendGCData
	rjmp interrupt_done

sendOriginsPacket:
	ldi	zl, lo8(origins_buf)
	ldi zh, hi8(origins_buf)
	ldi r23, 80
	rcall sendGCData
	rjmp interrupt_done


	/******************************************
	Build a 64bit data packet for the GC using
	the latest values from the snes controller
	******************************************/
buildAndSendPacket:
	ldi	zl, lo8(gc_tx_buf)
	ldi zh, hi8(gc_tx_buf)
	adiw zl, 3 ; first 3 bits are always 0

	ldi r19, 1	; used to set values in reply buffer

	; Test each button/direciton bit from the controller, and set the
	;  appropriate bytes in response. SNES bits are active low, GC bits are
	;  active high.
	ldi r19, (1<<4)	; SNES START
	and r19, r9
		st z+, r19	; GC START
	ldi r19, (1<<6) ; SNES Y
	and r19, r9
		st z+, r19	; GC Y
	ldi r19, (1<<6)	; SNES X
	and r19, r10
		st z+, r19	; GC X
	ldi r19, (1<<7) ; SNES B
	and r19, r9
		st z+, r19	; GC B
	ldi r19, (1<<7)	; SNES A
	and r19, r10
		st z+, r19	; GC A
	st z+, r19	; This is the first bit of the 2nd byte. Always 1

	ldi r19, (1<<5)	; SNES L
	and r19, r10
		st z+, r19	; GC L
	ldi r19, (1<<4)	; SNES R
	and r19, r10
		st z+, r19	; GC R
	ldi r19, (1<<5)	; SNES SELECT
	and r19, r9
		st z+, r19	; GC Z
	ldi r19, (1<<3)	; SNES UP
	and r19, r9
		st z+, r19	; GC UP
	ldi r19, (1<<2)	; SNES DOWN
	and r19, r9
		st z+, r19
	ldi r19, (1<<0)	; SNES RIGHT
	and r19, r9
		st z+, r19	; GC RIGHT
	ldi r19, (1<<1)	; SNES LEFT
	and r19, r9
		st z+, r19
	
	; Point to the beginning of the packet. This will
	; be used by the transmission routine later
	ldi	zl, lo8(gc_tx_buf)
	ldi zh, hi8(gc_tx_buf)
	
	; Generate special keys on certain combinations detected in main context
checkForC:
	tst r8	; when r8 set, send CStick towards left value
	breq centered

	; TODO: Is this left or right?
	ldi r19, 0xff
	std z+32, r0	; 7 (MSB)
	std z+33, r0	; 6
	std z+34, r0	; 5
	std z+35, r0	; 4
	std z+36, r0	; 3
	std z+37, r0	; 2
	std z+38, r0	; 1
	std z+39, r19	; 0


	rjmp length_branch
centered:
	; based on our origin packet, we
	; send 1000 0001 when centered. 
	ldi r19, 0xff
	std z+32, r19	; 1
	std z+33, r0	; 2
	std z+34, r0	; 3
	std z+35, r0	; 4
	std z+36, r0	; 5
	std z+37, r0	; 6
	std z+38, r0	; 7
	std z+39, r19	; 8

length_branch:
	; Check if we must send 64 or 80 bits.
	tst r7
	breq reply64

reply80:
	ldi r23, 80
	rcall sendGCData
	rjmp interrupt_done

reply64:
	ldi r23, 64
	rcall sendGCData
	rjmp interrupt_done


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
	* 
	* A stop bit is automatically added to the end. 
	*
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

	nop
	nop
	nop
	nop
	nop
	nop
	; STOP BIT
	sbi IO_DDRD, GC_DATA_BIT ; Pull low for stop bit
	ldi r20, 4
stbdly0:
	dec r20
	brne stbdly0
	nop
	cbi IO_DDRD, GC_DATA_BIT	; Done


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

nop
nop
nop
nop
nop
nop
	; STOP BIT
	sbi IO_DDRD, GC_DATA_BIT ; Pull low for stop bit
	ldi r20,4 
stbdly1:
	dec r20
	brne stbdly1
	nop
	cbi IO_DDRD, GC_DATA_BIT	; Done


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
#if defined(__AVR_ATmega8__)
	ldi r16, 0x02	/* 0000 0010 */ 
	out IO_MCUCR, r16
	ldi r16, 0x40	/* INT0 set */
	out IO_GICR, r16
#elif defined(__AVR_ATmega168__)
	ldi r16, 0x02   /* Setupt falling edge */
	sts EICRA, r16
	ldi r16, 0x01   /* INT0 set */
	out IO_EIMSK, r16
#else
#error MCU not supported
#endif

	/* Read jumpers. 
	  PB0: Common
	  PB1: JP1
	  PB2: JP2
	*/
	sbi IO_DDRB, 0		; put a '1' on
	cbi IO_PORTB, 0		; the common pin.
	cbi IO_DDRB, 1		; setup JP1 and
	cbi IO_DDRB, 2		; JP2 as inputs
	sbi IO_PORTB, 1		; Enable JP1 pull-up
	sbi IO_PORTB, 2		; Enable JP2 pull-up
	nop
	nop
	nop
	/* At the moment, only JP1 matters. 
	   JP1 open(high) : Snes
	   JP1 close(low) : Nes
	*/
	ldi r16, 0x02	; mask for PB1 (JP1)
	in r2, IO_PINB
	com r2
	and r2, r16		; isolate the bit.
	; Now r2 contains 0 in snes mode, 0x02 in nes mode.

	; Check if the user wants to force NES mode by
	; doing a NES mode read (this works on an SNES controller
	; too) to check the
	rcall readNes

	mov r16, r4
	andi r16, 0x10
	breq notForced
	ldi r16, 0x02
	mov r2, r16	; r2 not zero means nes mode.
notForced:

	; Check for A and B being held down to enable the swap (NES)
	;
	; Setting r6 to non-zero enables the swap
	; MSB of R4 is B button
	; MSB of R5 is A button
	mov r16, r4
	or r16, r5	
	andi r16, 0x80
	mov r6, r16

	rcall clr_precooked_buffers
	rcall build_id_packet
	rcall build_origins_packet
	rcall initReplyBuf

	clr r8

	sei
mainloop:
	/* A real Snes polls the controller at 60hz. But we
	poll the controller after each interrupt (our only
	interrupt source is when the gamecube sends us a
	command. */

#ifdef HIGHRATE_POLLING
	rcall delay_5ms
#else
	tst r3				; set inside int handler
;	breq mainloop;
#endif
	
	tst r2			; ==0 snes mode, !=0 nes mode
	breq doSnes
	
	rjmp doNes


	;-- Special Button combinations for SNES --
	; L+R+Select+left -> Cstick towards right
doSnes:
	rcall readSnes

	; Check if L and R are pressed
	mov r16, r5	
	andi r16, 0x30
	cpi r16, 0x30
	brne none;	L and R not pressed. Get out.

check_sel_left:
	; Check for Select + Left
	mov r16, r4
	andi r16, 0x22
	cpi r16, 0x22
	brne none

	; set r8 to send a cstick towards the right value
	ldi r16, 0xff
	mov r8, r16
	clr r9	; dont send any..
	clr r10	; ..other keypresses.

	rjmp waitSnesIdle
	
	
	
	
	; -- Special Button combinations for NES --
	; A+B+Select+left       -> Cstick left
	; A+B+Select+up			-> L+R
doNes:
	rcall readNes

	; Check if A is pressed
	mov r16, r5
	andi r16, 0x80
	cpi r16, 0x80
	brne none

	; Test for B+Select+left
	mov r16, r4
	andi r16, 0xa2
	cpi r16, 0xa2
	brne check_bsu

	; set r8 to send a cstick towards the right value
	ldi r16, 0xff
	mov r8, r16
	clr r9	; dont send any..
	clr r10	; ..other keypresses.
	rjmp waitNesIdle

check_bsu:	; Test for B+Select+up
	clr r8	; b+sel+left was false. Dont send Cstick right
	mov r16, r4
	andi r16, 0xa8
	cpi r16, 0xa8
	brne dly	; no valid key combinations found.

	; set only L and R bits
	ldi r16, 0x30
	clr r9			; dont send any other keypresses...
	mov r10, r16		; apart from L+R.
;	rjmp waitNesIdle	; fallthrough to waitNesIdle

	; To prevent unwanted operations when exiting from a button combination, 
	; wait until all buttons have been released
waitNesIdle:
	rcall delay_16ms
	rcall readNes
	tst r4
	brne waitNesIdle
	tst r5
	brne waitNesIdle
	rjmp none	; this will clear special combinations

	; To prevent unwanted operations when exiting from a button combination, 
	; wait until all buttons have been released
waitSnesIdle:
	rcall delay_16ms
	rcall readSnes
	tst r4
	brne waitNesIdle
	tst r5
	brne waitNesIdle
	rjmp none	; this will clear special combinations

	; No special combinations active
none:
	clr r8		; Disable C-stick right thing
	rjmp dly


dly:
	mov r9, r4	; Just copy the latest values...
	mov r10, r5	; to the global register pair/
	rcall delay_16ms	; dont read the controller again too soon?
						; just in case some non-standard snes compatible
						; controller does not like this.

	clr r3
	rjmp mainloop

	/*******************************************************
	 * Subroutine which reads the status of a NES controller
	 * into the r4 and r5 registers, presenting the bits
	 * as if it was from an SNES controller.
	 ******************************************************/
readNes:
	push r17 ; for r8bits which uses it


	/* Latch the buttons output into the shift register */
	sbi IO_PORTC, LATCH_BIT
	rcall delay_6us
	rcall delay_6us
	cbi IO_PORTC, LATCH_BIT
	rcall delay_6us

	/* Generate 8 clock pulses, reading data on the falling edge */
	rcall r8bits ; result is in r18..
	
	/* NES sends data in this order:
	 * A B Select Start Up Down Left Right
	 * |------------- R18 ----------------|
	 * 
	 * SNES sends data in this order:
	 * B Y Select Start Up Down Left Right | A X L R 1 1 1 1 
	 * |--------- R4 ----------------------|------ R5 -----|
	 */
	tst r6
	breq no_a_b_swap

	mov r16, r18
	andi r16, 0x80	; Extract the A button
	lsr r16			; Now R16 is 0x40 or 0x00 depending on the A button

	ldi r17, 0x40	; Propagate B bit to msb position
	andi r18, 0x7F	; ... 
	add r18, r17 	; ...
	andi r18, ~0x40	; Clear the original B bit for the A button
	or r18, r16	; Patch in the A button

no_a_b_swap:
	ldi r16, 0x80	; mask for bit 'A'
	and r16, r18
	mov r5, r16		; set or clear snes bit A

	mov r16, r18
	andi r16, 0x40	; isolate bit 'B'
	lsl r16			; move bit 'B' for first place, for SNES
	andi r18, 0x3f	; clear snes B and Y 
	or r18, r16		; set/clear snes bit 'B'
	mov r4, r18

	pop r17
	ret

	/*******************************************************
	 * Subroutine which reads the status of an SNES controller
	 * into the r4 and r5 registers.
	 *******************************************************/
readSnes:
	push r17 ; for r8bits which uses it

	/* Latch the buttons output into the shift register */
	sbi IO_PORTC, LATCH_BIT
	rcall delay_6us
	rcall delay_6us
	cbi IO_PORTC, LATCH_BIT
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

	cbi IO_PORTC, CLOCK_BIT

	in r16, IO_PINC
	com r16			; snes active low, make bit active high
	andi r16, 0x08	; mask the data bit
	lsr r16
	lsr r16
	lsr r16
	or r18, r16

	rcall delay_6us

	sbi IO_PORTC, CLOCK_BIT

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
	dec r16				; 1
	brne delay_6us_loop	; 2 when taken
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

	/*************************************************************
	 * Subroutine which busy-loops for approx 5ms
	 *************************************************************/
delay_5ms: 
	push r17
	ldi r17, 32
delay_5ms_outer_lp:
	ldi r16, 0xff
delay_5ms_lp:
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	dec r16
	brne delay_5ms_lp

	nop
	nop
	nop
	nop

	dec r17
	brne delay_5ms_outer_lp
delay_5ms_done:
	pop r17
	ret
	
	/********************************************
		Uses r19, Z
	*/
build_id_packet:
	/* My controller replies with this:

		  [   Device ID   ] [status] 
		  00001001 00000000 00100000 1
		      ^  ^                   ^
			  |  |                   +--- Stop bit
			  |  +-- 0: non standard controller, 1: Dolphin standard controller
			  +----- 0: N64, 1: Dolphin
	*/
	ldi r19, 1
	ldi	zl, lo8(id_status)
	ldi zh, hi8(id_status)
	adiw zl, 4
	st z, r19	; Dolphin
	adiw zl, 3
	st z, r19	; Dolphin
	adiw zl, 11
	st z, r19	; Mysterious status bit
	adiw zl, 6
	st z, r19	; Stop bit

	ret

build_origins_packet:
	; When Wii sends 0100 0001 1, my gc controller replies:
	; 0000 0000   1000 0000   1000 0011   0111 1010 
	; 1000 0001   0111 1110   0001 0110   0001 0011
	; 0000 0000   0000 0000 1
	;
	ldi r19, 1
	ldi zl, lo8(origins_buf)
	ldi zh, hi8(origins_buf)
	adiw zl, 8
	st z, r19
	adiw zl, 8
	st z, r19
	adiw zl, 6
	st z+, r19
	st z, r19
	adiw zl, 2
	st z+, r19
	st z+, r19
	st z+, r19
	st z, r19
	adiw zl, 2
	st z, r19
	adiw zl, 2
	st z, r19
	adiw zl, 7
	st z, r19
	adiw zl, 2
	st z+, r19
	st z+, r19
	st z+, r19
	st z+, r19
	st z+, r19
	st z, r19
	adiw zl, 5
	st z, r19
	adiw zl, 2
	st z+, r19
	st z, r19
	adiw zl, 5
	st z, r19
	adiw zl, 3
	st z+, r19
	st z, r19
	;;;; 16 bit of 0's? 

	ret

	/*********************************************
	*********************************************/
clr_precooked_buffers:
	clr r20
	
	ldi	zl, lo8(id_status)
	ldi zh, hi8(id_status)
	
	ldi r19, 24
lp3412:
	st z+, r20
	dec r19
	brne lp3412

	ldi	zl, lo8(origins_buf)
	ldi zh, hi8(origins_buf)
	ldi r19, 80
lp34128:
	st z+, r20
	dec r19
	brne lp34128

	; extra bits for 80bit reply to different poll
	ldi zl, lo8(gc_tx_buf_extra)
	ldi zh, hi8(gc_tx_buf_extra)
	ldi r19, 16	; start by zero'ing all 16 bits
lp6343:
	st z+, r20
	dec r19
	brne lp6343

	ldi zl, lo8(gc_tx_buf_extra)
	ldi zh, hi8(gc_tx_buf_extra)

	ldi r16, 0xff ; now set 8th and 16th bits
	std Z+7, r16
	std Z+15, r16

	ret

	/**************************************************/
initReplyBuf:
	ldi	zl, lo8(gc_tx_buf)
	ldi zh, hi8(gc_tx_buf)
	ldi yl, lo8(origins_buf)
	ldi yh, hi8(origins_buf)

	; Copy the origins reply.
	ldi r16, 64
cp_lp:
	ld r20, y+
	st z+, r20
	dec r16
	brne cp_lp

	ret

