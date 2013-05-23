CC=avr-gcc
AS=$(CC)
LD=$(CC)

CPU=atmega8
CFLAGS=-Wall -mmcu=$(CPU)
LDFLAGS=-mmcu=$(CPU) -Wl,-Map=snes2wii.map

OBJS=main.o

all: snes2wii.hex

clean:
	rm -f snes2wii.elf snes2wii.hex $(OBJS)

snes2wii.elf: $(OBJS)
	$(LD) $(OBJS) $(LDFLAGS) -o snes2wii.elf

snes2wii.hex: snes2wii.elf
	avr-objcopy -j .data -j .text -O ihex snes2wii.elf snes2wii.hex
	avr-size snes2wii.elf

fuse:
	avrdude -p m8 -P usb -c avrispmkII -Uhfuse:w:0xc9:m -Ulfuse:w:0x9f:m -B 20.0
	
flash: snes2wii.hex
	avrdude -p m8 -P usb -c avrispmkII -Uflash:w:snes2wii.hex -B 1.0


%.o: %.S
	$(CC) $(CFLAGS) -c $<
