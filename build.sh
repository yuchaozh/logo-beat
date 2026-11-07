#!/bin/bash
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Logo Beat.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$SOURCE/build"
cp "$SOURCE/Info.plist" "$APP/Contents/Info.plist"
clang -fobjc-arc -O2 -Wall -Wextra -Werror -framework AppKit \
    "$SOURCE/make-icon.m" -o "$SOURCE/build/make-icon"
"$SOURCE/build/make-icon" "$SOURCE/build/LogoBeat.iconset"
iconutil -c icns "$SOURCE/build/LogoBeat.iconset" -o "$APP/Contents/Resources/LogoBeat.icns"
clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -mmacosx-version-min=14.4 -framework AppKit -framework CoreAudio -framework IOKit \
    "$SOURCE/main.m" "$SOURCE/Playful.m" -o "$APP/Contents/MacOS/LogoBeat"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/LogoBeat" --self-test "$SOURCE/build/playground-preview.png"
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
