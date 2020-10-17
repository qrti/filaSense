;filaSense.asm V0.7 201007 qrt@qland.de 
;
;ATTINY13 - - - - - - - - - - - - - - - - - - - - - - - - - -
;fuse bits     43210   high
;SELFPRGEN     1||||   (default off)
;DWEN           1|||   (default off)
;BODLEVEL1..0    11|   (default off) (drains power in sleep mode)
;RSTDISBL          1   (default off)
;              11111
;
;fuse bits  76543210   low
;SPIEN      0|||||||   (default on)
;EESAVE      1||||||   (default off)
;WDTON        1|||||   (default off) (watchdog force system reset mode)
;CKDIV8        1||||   no clock div during startup
;SUT1..0        10||   64 ms + 14 CK startup (default)
;CKSEL1..0        01   4.8 MHz system clock
;           01111001

;-------------------------------------------------------------------------------

;V0.5   mid level capacitor 
;V0.6   soft mid level
;V0.7   logic define

;todo

;-------------------------------------------------------------------------------

;.device ATtiny13
.include "tn13def.inc"

;-------------------------------------------------------------------------------

.define     LOGIC       0               ;0 LOW, 1 HIGH = means detection

;-------------------------------------------------------------------------------

.cseg
.org $0000
rjmp main                                ;Reset Handler
;.org $0001
;rjmp EXT_INT0                           ;External Interrupt0 Handler
;.org $0002
;rjmp PCINT0                             ;Pin Change Interrrupt Handler
;.org $0003
;rjmp TIM0_OVF                           ;Timer0 Overflow Handler
;.org $0004
;rjmp EE_RDY                             ;EEPROM Ready Handler
;.org $0005
;rjmp ANA_COMP                           ;Analog Comparator Handler
;.org $0006
;rjmp TIM0_COMPA                         ;Timer0 Compare A
;.org $0007
;rjmp TIM0_COMPB                         ;Timer0 CompareB Handler
;.org $0008
;rjmp WATCHDOG                           ;Watchdog Interrupt Handler
;.org $0009
;rjmp ADC                                ;ADC Conversion Handler

;-------------------------------------------------------------------------------

.def    a0          =   r0              ;main registers set a
.def    a1          =   r1
.def    a2          =   r2
.def    a3          =   r3
.def    a4          =   r16             ;main registers set a immediate
.def    a5          =   r17
.def    a6          =   r18
.def    a7          =   r19

.def    FLAGR       =   r29             ;flag register          YH
.def    NULR        =   r31             ;NULL value register    ZH

;-------------------------------------------------------------------------------

.def    sumFL       =   r4              ;fast average
.def    sumFH       =   r5
.def    avgF        =   r6

.def    sumSL       =   r7              ;slow mid average
.def    sumSH       =   r8
.def    avgS        =   r9

.def    ledbt       =   r20             ;led blinc ticker
.def    slsc        =   r21             ;slow service counter

.def    thclo       =   r10             ;min threshold row counter low
.def    thchi       =   r11             ;                          high

.def    foscL       =   r24             ;filament out signal counter
.def    foscH       =   r25

;-------------------------------------------------------------------------------
;abused IO registers
.equ    FLAGS0      =   ACSR            ;flags 0
.equ    UNUF00      =   ACIS0           ;unused
.equ    UNUF01      =   ACIS1           ;

.equ    FLAGS1      =   WDTCR           ;flags 1
.equ    UNUF10      =   WDP0            ;unused
.equ    UNUF11      =   WDP1            ;
.equ    UNUF12      =   WDP2            ;

;flags in FLAGR
.equ    DETOFF      =   0               ;detection off
.equ    FIOUM       =   1               ;filament out memo
.equ    KEYPR       =   2               ;key pressed memo

;-------------------------------------------------------------------------------

.equ    CTRP        =   PORTB           ;control port
.equ    CTRD        =   DDRB            ;        ddr
.equ    CTRI        =   PINB            ;        pinport
.equ    FOUT        =   PINB0           ;        filament out           out (MOSI)
.equ    KEY         =   PINB1           ;        key                        (MISO)
.equ    UNUP2       =   PINB2           ;        unused                     (SCK)
.equ    LED         =   PINB3           ;        LED                    out
.equ    ADIN        =   PINB4           ;        AD input               in  (ADC2)
.equ    UNUP5       =   PINB5           ;        unused                     (RESET)

;                         ..-al-ko      a adin, l led, k key, o fout
;                         ..-IO-IO      I input, O output, . not present, - unused
.equ    DDRBM       =   0b00001001      
.if LOGIC == 0
;                         ..-NH-PH      L low, H high, P pullup, N no pullup
.equ    PORTBM      =   0b00001010
.elif LOGIC == 1
;                         ..-NH-PL  
.equ    PORTBM      =   0b00001010
.endif

;-------------------------------------------------------------------------------
;AD frequency (10 bit, target 50..200 kHz)      4.8E6 / 64 = 75E-3
;conversion time                                75E3^-1 * 13 = 173.333 us   (ct)
;
.equ    ADMUXC      =   (1<<ADLAR|1<<MUX1)                              ;left adjust, ADC2 PB4, Ref Vcc
.equ    ADCSRAC     =   (1<<ADEN|1<<ADSC|1<<ADATE|1<<ADPS2|1<<ADPS1)    ;ADC enable, start, auto (free running -> ADSCRB), div 64
.equ    DIDR0C      =   (1<<ADC2D)                                      ;ADC2 digital input buffer off

.equ    FOSDU       =   11538               ;2 s / ct               filament out signal duration
.equ    SLSCY       =   22                  ;t = SLSCY * ct * 256   slow service cycle                           

.equ    ADVTH       =   32                  ;1 AD = 5/255 = 1/51 ~ 0.0196 V
.equ    MINTHR      =   4                   ;min threshold row

;-------------------------------------------------------------------------------

main:
        ldi     a4,low(RAMEND)              ;set stack pointer
        out     SPL,a4                      ;to top of RAM

        ldi     a4,PORTBM                   ;port B
        out     PORTB,a4
        ldi     a4,DDRBM                    ;ddr B
        out     DDRB,a4

        sbi     ACSR,ACD                    ;comparator off

;- - - - - - - - - - - - - - - - - - - -

        clr     NULR                        ;init NULR (ZH)
        ldi     ZL,29                       ;reset registers
        st      Z,NULR                      ;store indirect
        dec     ZL                          ;decrement address
        brpl    PC-2                        ;r0..29 = 0, ZL = $ff, ZH = 0 (NULR)

        ldi     ZL,low(SRAM_START)          ;clear SRAM
        st      Z+,NULR
        cpi     ZL,low(RAMEND)
        brne    PC-2

        ldi     slsc,SLSCY                  ;init slow average loop counter     
        ldi     foscL,low(FOSDU/2)          ;set signal counter
        ldi     foscH,high(FOSDU/2)

;- - - - - - - - - - - - - - - - - - - -

        ldi     a4,ADMUXC                   ;config ADC
        out     ADMUX,a4

        ldi     a4,DIDR0C
        out     DIDR0,a4

        ldi     a4,ADCSRAC
        out     ADCSRA,a4

        ; sei                               ;no IRs used

        rcall   delay40ms                   ;settle Vcc + capacitors

;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

m00:    sbis    ADCSRA,ADIF                 ;new ADC value?
        rjmp    m00                         ;no, wait

        rcall   avgFast                     ;average fast

;- - - - - - - - - - - - - - - - - - - -

        dec     slsc                        ;slow service?
        brne    m01                         ;no, jump

        rcall   avgSlow                     ;average slow
        rcall   keyLed                      ;key and LED
        ldi     slsc,SLSCY                  ;reinit slow service counter
        
;- - - - - - - - - - - - - - - - - - - -

m01:    rcall   filOutSig                   ;filament out signal

        brne    PC+2                        ;no detection check while counter running
        rcall   detCheck                    ;detection check

        rjmp    m00                         ;main loop

;-------------------------------------------------------------------------------

avgFast:
        in      a4,ADCH                     ;read ADC, left adjusted
        sbi     ADCSRA,ADIF                 ;reset ADC IR flag

        tst     avgF                        ;init fast average
        brne    PC+3
        mov     sumFH,a4
        rjmp    PC+5

        add     sumFL,a4                    ;fast average 173 us cycle
        adc     sumFH,NULR
        sub     sumFL,avgF
        sbc     sumFH,NULR
        mov     avgF,sumFH                  ;/ 256 -> 44.372 ms average
        ret

;-------------------------------------------------------------------------------

avgSlow:
        tst     avgS                        ;init slow average
        brne    PC+3
        mov     sumSH,avgF
        rjmp    PC+5

        add     sumSL,avgF                  ;slow average
        adc     sumSH,NULR
        sub     sumSL,avgS
        sbc     sumSH,NULR
        mov     avgS,sumSH                  ;/ 256
        ret

;-------------------------------------------------------------------------------

keyLed:
        sbic    CTRI,KEY                    ;key released?
        rjmp    keyRel                      ;yes, jump
        
keyPre: ori     FLAGR,(1<<KEYPR)            ;set flag
        rjmp    lh01                        ;LED handling

keyRel: sbrs    FLAGR,KEYPR                 ;key was pressed?
        rjmp    lh01                        ;no, LED handling

        sbrs    FLAGR,FIOUM                 ;filament out memo?
        rjmp    kr01                        ;no, jump            
        andi    FLAGR,~(1<<FIOUM)           ;reset flag    

.if LOGIC == 0
        sbi     CTRP,FOUT                   ;filament ok, pin H
.elif LOGIC == 1
        cbi     CTRP,FOUT                   ;filament ok, pin L
.endif

        rjmp    kr09                       

kr01:   ldi     a4,(1<<DETOFF)              ;toggle detection on/off
        eor     FLAGR,a4                    ;
        
kr09:   andi    FLAGR,~(1<<KEYPR)           ;reset key press flag

;- - - - - - - - - - - - - - - - - - - -

lh01:   ldi     a5,0b00000000               ;detection on       --------

        sbrc    FLAGR,DETOFF                ;detection off      -.......
        ldi     a5,0b11111110               

        sbrc    FLAGR,FIOUM                 ;filament out memo  ----....
        ldi     a5,0b10000000

        inc     ledbt                       ;led blinc ticker ++
        mov     a4,ledbt                    ;copy ticker
        and     a4,a5                       ;blinc pattern
        cp      a4,a5
        breq    PC+3

        cbi     CTRP,LED                    ;LED off
        ret

        sbi     CTRP,LED                    ;LED on
        ret                                 ;exit

;-------------------------------------------------------------------------------

filOutSig:
        cp      foscL,NULR                  ;filament out signal active?
        cpc     foscH,NULR                  ;
        breq    fo09                        ;no, exit
        
        sbiw    foscH:foscL,1               ;count down      
        brne    fo09                        ;counter down? no, exit

.if LOGIC == 0
        sbi     CTRP,FOUT                   ;filament ok, pin H
.elif LOGIC == 1
        cbi     CTRP,FOUT                   ;filament ok, pin L
.endif

fo09:   ret                                 ;exit, Z=0 counter running, Z=1 counter stopped

;-------------------------------------------------------------------------------

detCheck:        
        sbrc    FLAGR,DETOFF                ;detection off?
        rjmp    dc08                        ;yes, reset threshold counters and exit

        mov     a4,avgS                     ;copy slow average, detection check
        sub     a4,avgF                     ;fast level lower than slow mid level?
        brcc    thlo                        ;yes, check low thresholds

        mov     a4,avgF                     ;copy fast average
        sub     a4,avgS                     ;fast level higher than slow mid level?
        brcc    thhi                        ;yes, check high thresholds

;- - - - - - - - - - - - - - - - - - - -

dc08:   clr     thclo                       ;reset threshold counters
        clr     thchi                       ;
dc09:   ret                                 ;exit

;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

thlo:   cpi     a4,ADVTH                    ;>= AD voltage threshold?
        brlo    dc08                        ;no, reset threshold counters and exit

        inc     thclo                       ;count up low threshold counter
        mov     a4,thclo                    ;copy counter
        rjmp    th01                        

thhi:   cpi     a4,ADVTH                    ;>= AD voltage threshold?
        brlo    dc08                        ;no, reset threshold counters and exit

        inc     thchi                       ;count up high threshold counter
        mov     a4,thchi                    ;copy counter
th01:   cpi     a4,MINTHR                   ;< min threshold row
        brlo    dc09                        ;yes, exit

;- - - - - - - - - - - - - - - - - - - -

detection:
.if LOGIC == 0
        cbi     CTRP,FOUT                   ;filament out, pin L
.elif LOGIC == 1
        sbi     CTRP,FOUT                   ;filament out, pin H
.endif
        ori     FLAGR,(1<<FIOUM)            ;             memo
        ldi     foscL,low(FOSDU)            ;set signal counter
        ldi     foscH,high(FOSDU)           ;
        rjmp    dc08                        ;reset threshold counters and exit

;-------------------------------------------------------------------------------

delay40ms:
        ldi     a4,250
        ldi     a5,255
        dec     a5
        brne    PC-1
        dec     a4
        brne    PC-4

        ret
