#!/bin/sh
# Builds a debug Coffee.app and runs it from the terminal.
#
# Prefer this over `swift run`: that starts a bare executable with no bundle,
# and macOS only delivers notifications (order ready, placed, failed…) from a
# real app bundle. Running the binary inside the bundle keeps the log on
# stderr like `swift run` did.
set -eu
cd "$(dirname "$0")"

swift build
APP=.build/Coffee.app
./bundle.sh "$(swift build --show-bin-path)/coffee-menubar" dev "$APP"
exec "$APP/Contents/MacOS/coffee-menubar" "$@"
