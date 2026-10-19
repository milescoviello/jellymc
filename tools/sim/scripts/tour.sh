# The phone's main screens, and pull to refresh on Home.
launch
shot 00-signin
signin
shot 01-home
ui 01-home
# Pull to refresh: down from near the top, then let go.
swipe 200 260 200 720 0.9
pause 0.4
shot 02-refreshing
pause 4
shot 03-after-refresh
tapl "Libraries"
pause 2
shot 04-libraries
tapl "Movies"
pause 3
shot 05-movies
ui 05-movies
tap 80 300
pause 3
shot 06-film
ui 06-film
swipe 200 700 200 250 0.4
pause 1
shot 07-film-below
