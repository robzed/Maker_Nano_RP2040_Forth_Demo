\ Cytron Maker Nano RP2040 Forth I/O Test by Rob Probin, August 2023.
\ 
\ BRIEF: Similar to the out-of-the-box supplied with this device (that was 
\        CircuitPython) - but in Forth. This tests the I/O on the board and 
\        gives melody upon power up, lights up the two RGB LEDs and does
\        something on GP20 Button. 
\
\        This shows basic Zeptoforth usage on the Maker Nano RP2040 module.
\
\ USE WITH: Zeptoforth RP2040 zeptoforth_full_usb-1.x.x.uf2
\
\ Other Notes
\ ===========
\
\   - For high level overview, start at the bottom of this file, and work up. 
\
\   - Forth runs at the same time as this program - feel free to type in 
\     commands. We run the program on a here on a seperate thread!
\
\   - It's possible to get it running on the other core by changing the
\     command at the bottom of this file.
\
\   - To get your Forth back to defaults you use the word 'restore-state'
\
\   - You want to use Zeptoforth with USB to access the terminal because
\     this program overrides GPIO0 and GPIO1. This can be stopped by making
\     changes to the array `LEDs` and the word `startup_loop`.
\
\   - To stop the task use demo-task @ stop
\
\   - See the Zeptoforth Wiki and documentation for more information on
\     Zeptoforth
\
\   - Owners of any melody are respected and used to duplicate the original
\ 
\   - The original button code doesn't seem to work as intended by the code,
\     so I've fixed in in main_loop below.
\ 
\ MIT License
\
\ Copyright (c) 2023 Rob Probin
\ 
\ Permission is hereby granted, free of charge, to any person obtaining a copy
\ of this software and associated documentation files (the "Software"), to deal
\ in the Software without restriction, including without limitation the rights
\ to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
\ copies of the Software, and to permit persons to whom the Software is
\ furnished to do so, subject to the following conditions:
\ 
\ The above copyright notice and this permission notice shall be included in all
\ copies or substantial portions of the Software.
\ 
\ THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
\ IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
\ FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
\ AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
\ LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
\ OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE

compile-to-flash    \ write the code to flash

pio import
pio-registers import
neopixel import

\
\ Constants
\
22 constant PIEZO_PIN
3 constant pwm-out-index        \ this is related to the PIEZO_PIN !!

20 constant BUTTON

\
\ Neopixel constants
\
11 constant NEOPIXEL_PIN

\ The number of Neopixels
2 constant neopixel-count

\ Neopixel PIO
PIO0 constant neopixel-pio

\ Neopixel state machine
0 constant neopixel-sm

\ buffer
neopixel-count neopixel-size buffer: my-neopixel

\ RP2040 system frequency
125000000 constant FSYS


\
\ LED helper code
\

pin import

\ These define the GPIO for the LEDs we want turn on
create LEDs
0 , 1 ,  2 ,  3 ,  4 ,  5 ,  6 , 7 ,
8 , 9 , 17 , 19 , 16 , 18 , -1 ,

0 value number_of_LEDs
: calculate_number_of_LEDs ( -- )
    0 LEDs
    begin dup @ 0 >=
    while
        swap 1+ swap
        CELL+
    repeat
    drop
    to number_of_LEDs
;

: get_LED_pin ( index -- pin )
    CELLS LEDs + @
;

: led_on ( led-pin -- )
    high swap pin!
;

: led_off ( led-pin -- )
    low swap pin!
;

: setup_leds
    number_of_LEDs 0 do \ assume there is always at leat one LED
        I get_LED_pin output-pin
    loop
;


\
\ This is the tune we play. Notes are in Hertz, Durations in milliseconds.
\
\ Remember Forth requires a space then a comma after each value
\

create MELODY_NOTE     659 , 659 ,   0 , 659 ,   0 , 523 , 659 ,   0 , 784 ,
create MELODY_DURATION 150 , 150 , 150 , 150 , 150 , 150 , 150 , 150 , 200 ,
9 constant NUMBER_OF_NOTES


\
\ PWM helper code to make notes
\

pwm import

\ calculate closest dividers for a PWM frequency
\
\ This routine produces the three parameters for PWM. It's been tested on a 
\ limited amount of audio frequencies and at the moment doesn't use the 
\ fraction part at all - although it might be possible to adjust it 
\ if the scaling part is changed from 2* to, say 1.5 or 1.2. Changes 
\ will need to be made to make the int/frac into a S31.32 fixed point number.
\
\ As mentioned above this routine currently doesn't use the fractional part, just int divider 
\ 
: calculate_closest_dividers ( S31.32-frequency-in-Hz -- frac-divider int-divider top-count )
    0 -rot  \ fraction part - currently always zero (we could bind this with frac divider, and make it divide by less than 2 each time...
    1 -rot  \ scaling = int-divider
    ( 0 1 S31.32-freq )
    FSYS s>f 2swap f/
    begin
        \ if it's above top count, then it won't fit! (we adjust top-count by 1 because fsys/((top+1)*(div_int+div_frac/16))
        2dup 65536 s>f d>
    while
        \ make it smaller, but record how much we divided it by
        2 s>f f/
        rot 2* -rot
    repeat
    f>s 1-  \ topcount-1
;

\
\ This routine prints the actual PWM frequency for a non-phase-correct produced by the routine above
\ 
: print-actual_frequency ( frac-divider int-divider top-count -- )
    dup 65535 u> if
        ." Top count=" u. ." -Error!!!!"
        65535
    then
    1+ \ top+1 equation is fsys/((top+1)*(div_int+div_frac/16))
    s>f FSYS s>f 2swap f/
    ( frac-divider int-divider S31.32-freq-base)
    2swap
    dup 255 u> if
        ." Integer Divider=" u. ." - Error!!!!"
        255
    then
    swap dup 15 u> if
        ." Frac Divider=" u. ." - Error!!!"
        15
    then
    \ convert fraction part to actual fraction
    s>f 16,0 f/
    rot s>f d+  \ combine integer and fraactional parts
    ( D.Fsys/ [TOP+1] D.int+frac )
    f/ 
    ." Freq =" F.
;

: tone_on ( S31.32-frequency-in-Hz  -- )
    \ this line prints out all the frequency details for debugging...
    \ 2dup 2dup f. ." = " calculate_closest_dividers 0 2over 2over drop . . . drop print-actual_frequency cr exit
    pwm-out-index bit disable-pwm
    0 pwm-out-index pwm-counter!

    \ Freq-PWM = Fsys / period
    \ period = (TOP+1) * (CSR_PH_CORRECT+1) + (DIV_INT + DIV_FRAC/16)
    \ e.g. 125 MHz / 16.0 = 7.8125 MHz rate base rate
    \ divider is 8 bit integer part, 4 bit fractional part
    \ Since phase correct is false/0, we only need to worry about TOP and Divider

    calculate_closest_dividers
    dup ( pwm-wrap-count ) pwm-out-index pwm-top!
    2/ ( 50% of pwm-wrap-count ) pwm-out-index pwm-counter-compare-a!
    ( frac-divider int-divider ) pwm-out-index pwm-clock-div!

    pwm-out-index free-running-pwm
    false pwm-out-index pwm-phase-correct!
    pwm-out-index bit enable-pwm
    PIEZO_PIN pwm-pin
;

: tone_off ( -- )
    PIEZO_PIN input-pin
    pwm-out-index bit disable-pwm
;

: tone ( duration-in-milliseconds frequency-in-Hz -- )
\ Note: Frequency 0 = off
    dup if
        \ if we want to use fractional Hertz, e.g. for accuracy, fix the s>f
        s>f tone_on
    else
        \ no tone
        drop
        tone_off
    then
    ms
    tone_off
;

: play_note ( index -- )
    CELLS dup MELODY_DURATION + @ swap MELODY_NOTE + @ tone
;



\
\ These are the functions that main calls
\

: setup_gpio
    setup_leds
    BUTTON input-pin
    BUTTON pull-up-pin
    
    neopixel-sm neopixel-pio neopixel-count NEOPIXEL_PIN my-neopixel init-neopixel

    ( red green blue index neopixel -- )
    \ r g b = 0 = off
    0 0 0 0 my-neopixel neopixel!
    0 0 0 1 my-neopixel neopixel!
    my-neopixel update-neopixel
;


\ The start up loop turns on the I/O LEDs on the Maker Nano RP2040 in turn
\ and plays a tune

: startup_loop
    \ Zeptoforth probably sets these up as terminal - turn them off 
    0 led_off
    1 led_off
     
    100 ms

    \ show leds and play melody
    number_of_LEDs 0 do \ assume there is always at leat one LED
        I get_LED_pin led_on
        I NUMBER_OF_NOTES < if
            I play_note
        else
            150 ms
        then
    loop

    \ turn leds off
    \ This time we use a begin-while-repeat loop, just to demonstrate one of those.
    \ We could also use a begin-until loop or a do-loop
    LEDs
    begin
        dup @ 0 >= 
    while
        dup @ led_off
        20 ms
        CELL+
    repeat
    drop
;

: RGB_split ( RGBcolour -- r g b )
    dup dup
    #8 rshift $ff and -rot  \ green
    #16 rshift $ff and -rot \ red
    $ff and \ blue
;

: pixel.set ( RGBcolour led-index -- )
    if
        RGB_split 0 my-neopixel neopixel!
    else
        RGB_split 1 my-neopixel neopixel!
    then
    my-neopixel update-neopixel
;

: pixels.fill ( RGBcolour -- )
    dup
    0 pixel.set
    1 pixel.set
;

0 value rgb_colour \ this is British / UK spelling
0 value rgb_state
variable led_state  \ I added this because the original code didn't work as expected

\
\ This checks the button and indicates on the RGB leds
\

: main_loop
    false led_state !   \ LEDs initially off

    begin
        BUTTON pin@ not if

            led_state @ if
            \ LEDs @ pin@ if    \ original code
                
                number_of_LEDs 0 do
                    I get_LED_pin led_off
                loop

                100 784 tone 
                150 659 tone
                200 262 tone
            else

                number_of_LEDs 0 do
                    I get_LED_pin led_on
                loop

                100 262 tone
                150 659 tone
                200 784 tone
            then 

            led_state @ not led_state !

        then

        \ RGB pixel colours
        rgb_state   \ get the current state
        dup 0 = if
            rgb_colour $101010 < if
                rgb_colour $010101 + to rgb_colour
            else
                rgb_state 1+ to rgb_state
            then
        then
        dup 1 = if
            rgb_colour $00FF00 and 0> if
                rgb_colour $000100 - to rgb_colour  \ decrease green to zero
            else
                rgb_state 1+ to rgb_state
            then
        then
        dup 2 = if
            rgb_colour $FF0000 and 0> if
                rgb_colour $010000 - to rgb_colour  \ decrease red to zero
            else
                rgb_state 1+ to rgb_state
            then
        then
        dup 3 = if
            rgb_colour $00FF00 and $1000 < if
                rgb_colour $000100 + to rgb_colour  \ increase green
            else
                rgb_state 1+ to rgb_state
            then
        then
        dup 4 = if
            rgb_colour $0000FF and 0> if
                rgb_colour $000001 - to rgb_colour  \ decrease blue to zero
            else
                rgb_state 1+ to rgb_state
            then
        then
        dup 5 = if
            rgb_colour $FF0000 and $100000 < if
                rgb_colour $010000 + to rgb_colour  \ increase red
            else
                rgb_state 1+ to rgb_state
            then
        then
        dup 6 = if
            rgb_colour $00FF00 and 0> if
                rgb_colour $000100 - to rgb_colour  \ decrease green to zero
            else
                rgb_state 1+ to rgb_state
            then
        then
        dup 7 = if
            rgb_colour $00FFFF and $001010 < if
                rgb_colour $000101 + to rgb_colour  \ increase green + blue
            else
                1 to rgb_state
            then
        then
        drop

        rgb_colour pixels.fill


        \ sleep to debounce buttons and change the speed of the RGB colour
        50 ms
    again
;

: main
    calculate_number_of_LEDs
    setup_gpio
    startup_loop
    main_loop       \ never returns
;

task import
variable demo-task
: start_main
    \ spawn arguments ( task-args, task-xt, dict-size, stack-size, ret-size -- task )
    0 ['] main 256 128 512 spawn demo-task ! 

    \ this version will spawn it on the second core on the RP2040. Comment out
    \ other spawn line to avoid conflicts
    \ 0 ['] main 256 128 512 1 spawn-on-core demo-task !

    demo-task @ run
;


\ you only need one of these...
\ : init init start_main ;  \ Forth console running
: turnkey start_main ;
\ : turnkey main ;          \ no Forth console, task in foreground

compile-to-ram

