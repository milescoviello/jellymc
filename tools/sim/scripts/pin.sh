# The library's pills, a film page, the PIN from Settings, the lock button, and pull to
# refresh caught while the finger is still down.
launch
signin
shot 01-home
# Pull to refresh, slowly: the shot lands mid-pull, then after letting go.
swipe 200 220 200 700 3 &
pause 1.8
shot 02-pulling
wait
pause 0.6
shot 03-released
pause 4
shot 04-settled
tapl "Libraries"
pause 2
tapl "Movies"
pause 3
shot 05-movies-pills
tapl "Library"
pause 3
shot 06-library-grid
tapl "Categories"
pause 2
shot 07-categories
tapl "Recommended"
pause 2
tapl "Sintel"
pause 3
shot 08-film
ui 08-film
swipe 200 700 200 220 0.5
pause 1
shot 09-film-below
# The PIN: Settings, down to it, on, 2580 twice.
tapl "Settings"
pause 2
swipe 200 700 200 150 0.4
pause 0.6
swipe 200 700 200 150 0.4
pause 0.8
shot 10-settings-pin
ui 10-settings
tapl "Require PIN"
pause 1.5
shot 11-choose-pin
for d in 2 5 8 0; do tapl "$d"; pause 0.2; done
pause 0.8
shot 12-again
for d in 2 5 8 0; do tapl "$d"; pause 0.2; done
pause 1.2
shot 13-pin-on
# The lock button on Home.
tapl "Home"
pause 1.5
shot 14-home-lock-button
tapl "Lock"
pause 1.5
shot 15-locked
for d in 1 1 1 1; do tapl "$d"; pause 0.2; done
pause 1
shot 16-wrong
for d in 2 5 8 0; do tapl "$d"; pause 0.2; done
pause 1.5
shot 17-unlocked
