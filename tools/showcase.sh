#!/usr/bin/env bash
# Capture the panel for the README and social posts.
#
# Puts a representative mapping on the connected tablet, opens the panel on
# the focused screen, grabs the compact view, the expanded editor and the bar
# icon, then restores the profile exactly as it was. Needs grim, wtype and
# ImageMagick (magick); run it from a Hyprland session with the plugin
# enabled in the right bar section.
#
#   tools/showcase.sh [output-dir]      default: screenshots/
set -euo pipefail

out=${1:-screenshots}
mkdir -p "$out"
here=$(cd "$(dirname "$0")/.." && pwd)
profile="$HOME/.config/omarchy-drawing-tablet/tablets.json"
backup=$(mktemp)
scratch=$(mktemp -d)
trap 'if [ -s "$backup" ]; then cp "$backup" "$profile"; fi; rm -rf "$scratch" "$backup"' EXIT

[ -f "$profile" ] && cp "$profile" "$backup"

focused=$(hyprctl -j monitors | jq -r '.[] | select(.focused) | .name')
screen_w=$(hyprctl -j monitors | jq -r '.[] | select(.focused) | (.width / .scale | floor)')
target=$(hyprctl -j monitors | jq -r '.[] | select(.focused) | .description')
target_name=$focused

# The bar's index of the widget, for togglePanelAt.
index=$(jq -r '.bar.layout.right | map(.id) | index("io.github.alxcrt.drawing-tablet") // -1' "$HOME/.config/omarchy/shell.json")
[ "$index" -ge 0 ] || { echo "plugin is not in the right bar section" >&2; exit 1; }

# A mapping worth showing: this screen, tablet proportions kept.
node -e '
const M = require(process.argv[1] + "/Model.js"); const fs = require("fs"); const cp = require("child_process")
const p = process.argv[2]; const doc = M.parseDocument(fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "")
if (!doc.tablets.length) { console.error("no tablet profile yet: open the panel once with a tablet connected"); process.exit(1) }
const t = doc.tablets[0]
t.output = { mode: "monitor", name: process.argv[3], description: process.argv[4] }
t.region = { mode: "aspect", x: 0, y: 0, w: 1, h: 1 }; t.activeArea.mode = "full"
t.transform = 0; t.leftHanded = false; t.relativeInput = false; t.enabled = true
const cmd = M.saveCommand(p, M.serializeDocument(doc)); cp.execFileSync(cmd[0], cmd.slice(1))
' "$here" "$profile" "$target_name" "$target"
sleep 2.5

# The card is found by its border: the theme's accent colour, drawn as a
# horizontal run a few pixels under the bar. Window borders share the colour
# but sit lower and span the whole window, so the first run of card-like
# length under the bar is the popup. Prints "WxH+X+Y" for magick -crop.
accent=$(grep -E '^accent' "$HOME/.local/state/omarchy/current/theme/colors.toml" | head -1 | sed -E 's/.*"(#[0-9a-fA-F]{6})".*/\1/')
find_card() {
  local image=$1 width=$2 height=$3
  python3 - "$image" "$width" "$height" "$accent" <<'PY'
import sys, subprocess
image, width, height, accent = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
target = tuple(int(accent[i:i+2], 16) for i in (1, 3, 5))
def near(p): return all(abs(a - b) <= 24 for a, b in zip(p, target))
def row(y):
    d = subprocess.run(["magick", image, "-crop", f"{width}x1+0+{y}", "+repage", "-depth", "8", "rgb:-"], capture_output=True, check=True).stdout
    return [near(tuple(d[i:i+3])) for i in range(0, len(d), 3)]
def col(x, y0):
    d = subprocess.run(["magick", image, "-crop", f"1x{height - y0}+{x}+{y0}", "+repage", "-depth", "8", "rgb:-"], capture_output=True, check=True).stdout
    return [near(tuple(d[i:i+3])) for i in range(0, len(d), 3)]
for y in range(20, 80):
    r = row(y); x = 0
    while x < width:
        if not r[x]: x += 1; continue
        start = x
        while x < width and r[x]: x += 1
        length = x - start
        if 300 <= length <= 1400:
            c = col(start, y); bottom = 0
            while bottom < len(c) and c[bottom]: bottom += 1
            if bottom >= 200:
                print(f"{length}x{bottom}+{start}+{y}"); sys.exit(0)
print("card not found", file=sys.stderr); sys.exit(1)
PY
}

screen_h=$(hyprctl -j monitors | jq -r '.[] | select(.focused) | (.height / .scale | floor)')

omarchy-shell shell togglePanelAt right "$index" >/dev/null
sleep 2.5
grim -o "$focused" "$scratch/compact-full.png"
wtype e; sleep 1.5
grim -o "$focused" "$scratch/expanded-full.png"
wtype -k Escape; sleep 0.3; wtype -k Escape; sleep 0.5
grim -o "$focused" "$scratch/bar-full.png"

compact_geometry=$(find_card "$scratch/compact-full.png" "$screen_w" "$screen_h")
expanded_geometry=$(find_card "$scratch/expanded-full.png" "$screen_w" "$screen_h")
magick "$scratch/compact-full.png" -crop "$compact_geometry" +repage "$out/compact.png"
magick "$scratch/expanded-full.png" -crop "$expanded_geometry" +repage "$out/expanded.png"
bar_h=$(hyprctl -j layers | jq -r --arg m "$focused" '.[$m].levels["2"][]? | select(.namespace=="omarchy-bar") | .h' | head -1)
magick "$scratch/bar-full.png" -crop "560x${bar_h:-26}+$((screen_w - 560))+0" +repage "$out/bar.png"
cp "$out/compact.png" "$here/preview.png"

# Social card, 16:9, the compact panel beside the pitch.
font=/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf
font_regular=/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf
bg="#101315"; fg="#cacccc"; dim="#8a8f94"
magick -size 1600x900 "xc:$bg" \
  \( "$out/compact.png" -resize x760 \( +clone -background black -shadow 60x24+0+16 \) +swap -background none -layers merge +repage \) \
  -gravity east -geometry +80+0 -composite \
  -font "$font" -fill "$fg" -pointsize 54 -gravity northwest -annotate +90+150 "Drawing Tablet\nfor Omarchy" \
  -font "$font_regular" -fill "$dim" -pointsize 24 -annotate +90+320 "Map a pen tablet to the right screen\nfrom the bar, and keep it there across\nhotplug and Hyprland reloads." \
  -fill "$fg" -pointsize 22 -annotate +90+470 "· keep the tablet's proportions, or draw a region\n· left-handed flip, mouse mode, pressure limits\n· profiles follow the tablet by make, model and serial" \
  -fill "$dim" -pointsize 17 -annotate +90+700 "omarchy plugin add https://github.com/alxcrt/omarchy-drawing-tablet.git --enable" \
  "$out/social-card.png"

# A second card for the editor itself, wide, with a one-line caption.
magick -size 1600x900 "xc:$bg" \
  \( "$out/expanded.png" -resize 1440x \( +clone -background black -shadow 60x24+0+16 \) +swap -background none -layers merge +repage \) \
  -gravity north -geometry +0+70 -composite \
  -font "$font_regular" -fill "$dim" -pointsize 22 -gravity south -annotate +0+56 "The expanded editor: drag the region on the preview, set custom areas in percent or millimetres, tune the stylus." \
  "$out/social-card-editor.png"

echo "wrote $out/compact.png $out/expanded.png $out/bar.png $out/social-card.png $out/social-card-editor.png and preview.png"
