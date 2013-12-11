chibi-trigger
=============

Trigger sticker code for chibitronics circuit stickers

The idea behind the trigger circuit is to take an analog
input value, and when an event happens, output a pulse.

Assumptions:
* Analog input tends to hang out around a DC value
* An "event" means the analog value deviates some distance off of DC

The implementation uses a fast polling loop and an interrupt
driver timer.

The fast polling loop constantly samples the ADC, checks
it against the average value, and if outside of a threshold by
either + or - excursion, sets an LED output timer to a selected
delay value.

The timer is set to fire at a rate of 15Hz, and every time it
fires it grabs the latest ADC sample,  adds it to a circular
buffer and computes the average of the circular buffer. The
buffer is 16 samples deep, so it's averaging over about
one second.

In addition to doing bookkeeping on the average value, the timer
also manages the LED output. It will decrement an LED counter
every time the timer fires, and if the value is non-zero it lights
up the LED. 
