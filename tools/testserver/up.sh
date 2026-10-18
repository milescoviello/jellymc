#!/usr/bin/env bash
# A throwaway Jellyfin 12.2 on :8096 for development, with the first-run wizard done and
# the three test libraries added. Idempotent: rerunning starts the container if it is
# stopped and skips the wizard if it has been completed.
#
#   tools/testserver/make-media.sh   # once, to generate the media
#   tools/testserver/up.sh
#   docker rm -f jellymc-testserver  # to throw it away (data stays in $DATA)
set -euo pipefail

DATA="${JELLYMC_TESTSERVER:-$HOME/.local/share/jellymc-testserver}"
IMAGE="${JELLYMC_TESTSERVER_IMAGE:-jellyfin/jellyfin:latest}"
NAME=jellymc-testserver
URL=http://localhost:8096
USER_NAME=jellymc
PASSWORD=jellymc
AUTH='MediaBrowser Client="jellymc-setup", Device="testserver", DeviceId="jellymc-testserver-setup", Version="1"'

mkdir -p "$DATA"/{config,cache,media}

if ! docker container inspect "$NAME" >/dev/null 2>&1; then
    docker run -d --name "$NAME" \
        --user "$(id -u):$(id -g)" \
        -p 8096:8096 \
        -v "$DATA/config:/config" -v "$DATA/cache:/cache" -v "$DATA/media:/media:ro" \
        "$IMAGE" >/dev/null
elif [ "$(docker container inspect -f '{{.State.Running}}' "$NAME")" != true ]; then
    docker start "$NAME" >/dev/null
fi

printf 'waiting for %s' "$URL"
for _ in $(seq 120); do
    if curl -fsS "$URL/System/Info/Public" 2>/dev/null | jq -e .Version >/dev/null 2>&1; then break; fi
    printf .; sleep 1
done
echo

info=$(curl -fsS "$URL/System/Info/Public")
echo "$info" | jq -c '{ServerName, Version, StartupWizardCompleted}'

post() { # path [json]
    curl -fsS -X POST "$URL$1" -H "Authorization: $AUTH" -H 'Content-Type: application/json' -d "${2:-{\}}"
}

if [ "$(echo "$info" | jq -r .StartupWizardCompleted)" != true ]; then
    post /Startup/Configuration '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}'
    # The wizard creates its first user on this GET; the POST then names it.
    curl -fsS "$URL/Startup/User" -H "Authorization: $AUTH" >/dev/null
    post /Startup/User "{\"Name\":\"$USER_NAME\",\"Password\":\"$PASSWORD\"}"
    post /Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}'
    post /Startup/Complete
    echo "wizard completed"
fi

token=$(post /Users/AuthenticateByName "{\"Username\":\"$USER_NAME\",\"Pw\":\"$PASSWORD\"}" | jq -r .AccessToken)
AUTH_TOKEN="$AUTH, Token=\"$token\""

existing=$(curl -fsS "$URL/Library/VirtualFolders" -H "Authorization: $AUTH_TOKEN" | jq -r '.[].Name')
add_library() { # name collectionType path
    if grep -qx "$1" <<<"$existing"; then return; fi
    curl -fsS -X POST "$URL/Library/VirtualFolders?name=$(jq -rn --arg v "$1" '$v|@uri')&collectionType=$2&refreshLibrary=false" \
        -H "Authorization: $AUTH_TOKEN" -H 'Content-Type: application/json' \
        -d "{\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"$3\"}],\"EnableTrickplayImageExtraction\":true,\"ExtractTrickplayImagesDuringLibraryScan\":true}}"
    echo "added library $1"
}
add_library Movies movies /media/movies
add_library Shows tvshows /media/shows
add_library Music music /media/music

curl -fsS -X POST "$URL/Library/Refresh" -H "Authorization: $AUTH_TOKEN"
echo "library scan started; sign in at $URL as $USER_NAME / $PASSWORD"
