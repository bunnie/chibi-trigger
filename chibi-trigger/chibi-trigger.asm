/*
 * chibi_trigger.asm
 *
 *  Created: 12/11/2013 18:26:47
 *   Author: bunnie
 *  See file LICENSE for licensing details (LGPLv3)
 */ 

 .include "tn5def.inc"

; register allocations. Need to be a bit careful because of side effects in ISRs
; r16 ; upper thresh
; r17 ; lower thresh
 .def  ledTime  = r18  ; how much time left on the output assertion
 .def  temp = r19     		; also end-value arg for PWM value change
 .def  temp1 = r20
 .def  temp2 = r21    ; don't use in ISRs
 .def  adcval = r22
 .def  avgval = r23
 
 ; r26 XL  used to accumulate average value before dividing
 ; r27 XH
 ; r28 YL  pointer used to compute moving average
 ; r29 YH
 ; r30 ZL  pointer to current entry for circular buffer
 ; r31 ZH
 
;set some variables
 ;time1 and time2 set the value for the final loop in each delay
 .equ  time1   = 180 ;between 0 and 255
 .equ  timef   = 120
 .equ  time2   = 2
 .equ  led     = 0 ;LED at PB0
 .equ  thresh  = 46  ; +/- threshold value

 .equ  BUFSTART = $40  ; bottom of SRAM

 // interrupt vectors
 rjmp RESET  ;go and set up PORTB as an output
 rjmp INT0_HANDLER
 rjmp PCINT0_HANDLER
 rjmp TIM0_CAPT
 rjmp TIM0_OVF
 rjmp TIM0_COMPA
 rjmp TIM0_COMPB
 rjmp ANA_COMP
 rjmp WDT
 rjmp VLM
 rjmp ADC_HANDLER

 // most handlers are do-nothing
INT0_HANDLER:
PCINT0_HANDLER:
TIM0_CAPT:
TIM0_COMPA:
TIM0_COMPB:
ANA_COMP:
WDT:
VLM:
ADC_HANDLER:
 reti  ; just return from an interrupt here

;;;;;;;; handle timer firing. 
;; The timer is set up to trigger at ~15 Hz
;; We add a sample to a circular buffer for averaging whenever the timer
;; fires. We are totally counting on there being a tight main loop polling
;; the ADC and updating "adcval" (r22) with the latest ADC value. 
;;
;; This routine also handles updating the LED output. If the LED counter value
;; is greater than zero, assert the LED output and decrement by one. This 
;; creates a "pulse-stretching" behavior, sort of.
;;
;; wheee life in 512 bytes of code....
TIM0_OVF:
 ; store a sample in the 16-byte deep circular buffer
 st     Z+, adcval  ; adcval always has the most recent conversion value, captured in a tight main loop
 andi   ZL, $4F     ; compute Z %= 16
 clr    ZH

 ; now check and see if we should assert the output for the LED
 cpi    ledTime, $00
 breq   clearLED
 cbi    PORTB, led ; LED on
 dec    ledTime
 rjmp   onwards
clearLED:
 sbi    PORTB, led ;LED off - cbi/sbi swapped for N-FET switching (ie.LED is OFF when FET is ON)

onwards:
 ; now compute the average of the circular buffer and update value in avgval
 ldi    YL, $40  ; $40 is bottom of RAM
 clr    YH
 clr    XL
 clr    XH
 clr    temp1  ; just needs to be zero

avg_sum:
 ld     temp, Y+
 add    XL, temp
 adc    XH, temp1  ; temp1 is always zero, but we're just trying to catch the carry

 cpi    YL, $50
 brne   avg_sum
 
 ; now divide X by 16 by shifting right by 4
 lsr    XL
 lsr    XL
 lsr    XL
 lsr    XL  ; XL >> 4

 lsl    XH
 lsl    XH
 lsl    XH
 lsl    XH  ; XH << 4

 or     XL, XH  ; XL = XH | XL
 mov    avgval, XL
 reti

;;;;;; Main entry point 
 ; algorithm -- determine a baseline average over the past 10 seconds
 ; then if deviation beyond baseline (+/- delta) fire trigger

RESET: ;set PB2 as an output in the Data Direction Register for PORTB
 ldi   r16, high(RAMEND)  ; set up stack pointer to top of RAM
 out   SPH, r16
 ldi   r16, low(RAMEND)
 out   SPL, R16

 ldi   ZL, $40  ; set the circular buffer to bottom of RAM, $40
 clr   ZH

 clr   ledTime  ; clear the LED output timer

 ldi   temp, $0
 out   OCR0AH, temp

 out   PUEB, temp ; clear all pull-ups

 ldi   temp, $01
 out   DDRB, temp ; pin 0 is output, all others as input

 in 	temp, DIDR0	; Load Digital Input Disable Register value to temporary
 sbr	temp, (1<<ADC2D)	; Disable Digital Inputs on ADC Channel 2
 out	DIDR0, temp	; Store it back to DIDR

 ldi	temp,$02	
 out	ADMUX,temp	; Monitor PB2 (ADC2)

 ldi	temp,$83	; Enable ADC with Clock prescaled by 8
 out	ADCSRA, temp;If Clock speed is 1MHz, then ADC clock = 1MHz/8 = 125kHz (must be 50-200kHz)
 ; converts in about 100us at this clock rate ~10kHz

 ; initialize timer to set sampling interval
 ldi	temp, $00
 out	TCCR0A, temp

 ldi    temp, $01  ; interrupt on timer overflow
 out    TIMSK0, temp

 ; 1 mhz / 65536 = 15.2 hz, 15.2hz / 1 = 15.2 Hz = cs0[2:0] = 001
 ldi    temp, $01
 out    TCCR0B, temp ; sets timer in motion

 sei   ; enable interrupts: at this point, the timer OVF callback can side-effect regsiters

forever:  ; sample the ADC as fast as we can, cherry-pick values to compute moving averages based on timer interrupts
 in 	temp2, ADCSRA
 sbr	temp2, (1<<ADSC)
 out	ADCSRA, temp2; Start the ADC Conversion
poll:	
 in 	temp2, ADCSRA ; temp2 is ISR-safe by convention
 sbrc	temp2, 6
 rjmp 	poll		;Wait till ADC Conversion is complete

 in     adcval, ADCL	;Load ADC Conversion result to temp

 ; now do a comparison against the moving average and decide if we need to trigger an output, or not
 ; do a saturating add/subtract to compute +/- bounds on average
 ldi    r16, thresh
 add    r16, avgval
 brcc   skip_satpos
 ldi    r16, $FF ; carry was set
skip_satpos:
 mov    r17, avgval
 clc
 sbci   r17, thresh
 brcc   skip_satneg
 ldi    r17, $00 ; borrow was set
skip_satneg:
 ; r16 has the upper thresh, r17 has the lower thresh
 cp     r16, adcval  ; is it larger or equal to the upper threshold?
 brlo   setOutput    ; branch if r16 < adcval
 cp     adcval, r17  ; is it less than or equal to the lower threshold?
 brlo   setOutput
 breq   setOutput

 rjmp   forever  ; maybe this should be a sleep.

setOutput:
 ; set the output timer
 ldi    ledTime, 16  ; 15.2 Hz update loop on LED counter, so about 1 seconds = 16 iterations
 rjmp   forever
