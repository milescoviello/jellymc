#!/usr/bin/env bash
# Generates a small library for the local test server: films named after Blender's open
# movies (so the server finds real posters and cast) and a three-episode series. The pictures are test patterns with the title and a clock burnt in; what matters
# is the mix of containers, codecs, subtitle formats and HDR signalling.
set -euo pipefail

ROOT="${JELLYMC_TESTSERVER:-$HOME/.local/share/jellymc-testserver}/media"
FONT=/usr/share/fonts/dejavu/DejaVuSans.ttf
mkdir -p "$ROOT"/{movies,shows}

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# A picture with a caption and a running clock.
picture() { # size rate seconds caption
    echo "testsrc2=size=$1:rate=$2:duration=$3,drawtext=fontfile=$FONT:text='$4  %{pts\\:hms}':fontsize=h/14:fontcolor=white:box=1:boxcolor=black@0.6:x=(w-tw)/2:y=h-th-h/12"
}

tone() { # seconds frequency
    echo "sine=frequency=$2:sample_rate=48000:duration=$1"
}

write_srt() {
    cat > "$1" <<'SRT'
1
00:00:02,000 --> 00:00:06,000
This is a plain SubRip subtitle.

2
00:00:10,000 --> 00:00:16,000
It arrives as a sidecar file next to the video.
SRT
}

write_ass() {
    cat > "$1" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,DejaVu Sans,64,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,60,1
Style: Sign,DejaVu Sans,80,&H0000D7FF,&H000000FF,&H00400000,&H00000000,1,0,0,0,100,100,0,-8,1,4,0,8,40,40,80,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:02.00,0:00:08.00,Default,,0,0,0,,Styled ASS dialogue, bottom centre.
Dialogue: 0,0:00:04.00,0:00:12.00,Sign,,0,0,0,,{\pos(960,200)}A rotated, coloured sign at the top
Dialogue: 0,0:00:14.00,0:00:20.00,Default,,0,0,0,,{\i1}Italic{\i0} and {\c&H00FF00&}green{\c} inline overrides.
ASS
}

write_chapters() { # file seconds
    local total=$(( $2 * 1000 ))
    cat > "$1" <<EOF
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=$(( total / 4 ))
title=Opening
[CHAPTER]
TIMEBASE=1/1000
START=$(( total / 4 ))
END=$(( total * 3 / 4 ))
title=The middle
[CHAPTER]
TIMEBASE=1/1000
START=$(( total * 3 / 4 ))
END=$total
title=Credits
EOF
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. H.264/AAC in MP4 with a sidecar SRT: AVPlayer direct play. Seven minutes, because the
#    server keeps no resume point for anything under five.
d="$ROOT/movies/Big Buck Bunny (2008)"; mkdir -p "$d"
if [ ! -f "$d/Big Buck Bunny (2008).mp4" ]; then
    ff -f lavfi -i "$(picture 1920x1080 24 420 'H.264 AAC MP4')" -f lavfi -i "$(tone 420 440)" \
        -c:v libx264 -preset veryfast -crf 30 -pix_fmt yuv420p -c:a aac -b:a 160k -movflags +faststart \
        "$d/Big Buck Bunny (2008).mp4"
    write_srt "$d/Big Buck Bunny (2008).en.srt"
fi

# 2. HEVC 10-bit MKV, two audio languages, styled ASS with an attached font, chapters:
#    mpv direct play; AVPlayer needs a remux and a burn-in.
d="$ROOT/movies/Sintel (2010)"; mkdir -p "$d"
if [ ! -f "$d/Sintel (2010).mkv" ]; then
    write_ass "$TMP/sintel.ass"; write_chapters "$TMP/sintel.chapters" 120
    ff -f lavfi -i "$(picture 1920x1080 24 120 'HEVC 10-bit MKV, ASS')" \
        -f lavfi -i "$(tone 120 330)" -f lavfi -i "$(tone 120 550)" \
        -i "$TMP/sintel.ass" -i "$TMP/sintel.chapters" \
        -map 0:v -map 1:a -map 2:a -map 3:s -map_metadata 4 -map_chapters 4 \
        -c:v libx265 -preset fast -crf 26 -pix_fmt yuv420p10le -x265-params log-level=error \
        -c:a:0 libopus -b:a:0 128k -c:a:1 aac -b:a:1 128k -c:s ass \
        -metadata:s:a:0 language=jpn -metadata:s:a:0 title="Japanese" \
        -metadata:s:a:1 language=eng -metadata:s:a:1 title="English" \
        -metadata:s:s:0 language=eng -metadata:s:s:0 title="Styled" \
        -attach "$FONT" -metadata:s:t mimetype=application/x-truetype-font \
        "$d/Sintel (2010).mkv"
fi

# 3. H.264 + AC-3 5.1 with an embedded SubRip track (FFmpeg cannot encode bitmap
#    subtitles from text, so PGS/VobSub need real discs to test).
d="$ROOT/movies/Elephants Dream (2006)"; mkdir -p "$d"
if [ ! -f "$d/Elephants Dream (2006).mkv" ]; then
    write_srt "$TMP/ed.srt"
    ff -f lavfi -i "$(picture 1920x1080 24 60 'AC-3 5.1, embedded SRT')" \
        -f lavfi -i "$(tone 60 220)" -i "$TMP/ed.srt" \
        -map 0:v -map 1:a -map 2:s \
        -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
        -c:a ac3 -b:a 384k -ac 6 -c:s subrip \
        -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng \
        "$d/Elephants Dream (2006).mkv"
fi

# 4. 4K HEVC 10-bit with HDR10 signalling: tone-mapping on Linux, HDR on the iPhone.
d="$ROOT/movies/Tears of Steel (2012)"; mkdir -p "$d"
if [ ! -f "$d/Tears of Steel (2012).mkv" ]; then
    ff -f lavfi -i "$(picture 3840x2160 24 30 'UHD HEVC HDR10')" -f lavfi -i "$(tone 30 660)" \
        -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
        -x265-params "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400" \
        -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
        -c:a eac3 -b:a 448k -ac 6 \
        "$d/Tears of Steel (2012).mkv"
fi

# 5. A series: three five-and-a-half-minute episodes, so resume, Next Up and up-next all
#    have something to do.
d="$ROOT/shows/Pioneer One (2010)/Season 01"; mkdir -p "$d"
for e in 1 2 3; do
    f="$d/Pioneer One S01E0$e.mkv"
    [ -f "$f" ] && continue
    write_chapters "$TMP/ep.chapters" 330
    ff -f lavfi -i "$(picture 1280x720 25 330 "S01E0$e")" -f lavfi -i "$(tone 330 $(( 300 + e * 50 )))" \
        -i "$TMP/ep.chapters" -map 0:v -map 1:a -map_chapters 2 \
        -c:v libx264 -preset veryfast -crf 30 -pix_fmt yuv420p -c:a aac -b:a 128k "$f"
done

echo "media in $ROOT"
du -sh "$ROOT"
