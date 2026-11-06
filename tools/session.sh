#!/bin/sh
# Guided 43s recording of your keyboard + mouse. A "tink" marks each phase change:
#   start: letters → tink: space bar → tink: enter → tink: mouse clicks → glass: done
# Tadak is paused meanwhile so its own sounds don't end up in the recording.
cd "$(dirname "$0")"
mkdir -p ../rec
osascript -e 'quit app "Tadak"' 2>/dev/null
mkdir -p ../rec
rm -f ../rec/session.wav.ready
./record ../rec/session.wav 43 &
while [ ! -f ../rec/session.wav.ready ]; do sleep 0.05; done  # cue times count from when the mic is live
cue() { sleep "$1"; afplay "/System/Library/Sounds/$2.aiff" & }
cue 6 Tink    #  6s letters
cue 12 Tink   # 18s space
cue 7 Tink    # 25s enter
cue 7 Tink    # 32s mouse
cue 10 Glass  # 42s done
wait
open /Applications/Tadak.app
