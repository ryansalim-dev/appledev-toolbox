#!/bin/bash
# Double-click this in Finder, pick your Xcode project folder, and VS Code gets set up for it.
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$(osascript -e 'POSIX path of (choose folder with prompt "Choose your Xcode project folder")' 2>/dev/null)" \
  || { echo "Cancelled."; exit 0; }
bash "$HERE/setup-vscode-xcode.sh" "$DIR"
status=$?
echo
read -r -n 1 -s -p "Press any key to close this window."
exit $status
