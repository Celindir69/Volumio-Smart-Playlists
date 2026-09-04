#!/bin/bash

echo "Installing AutoDJ Continuous Play plugin dependencies"

SCRIPTPATH="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPTPATH" || exit 1

# jq is required by the bundled volumio-autodj-local.sh but, unlike mpc/curl,
# is not part of Volumio's base image.
if ! command -v jq >/dev/null 2>&1; then
  apt-get update
  apt-get install -y jq
fi

npm install --production --no-audit --no-fund

chmod +x "$SCRIPTPATH/volumio-autodj-local.sh"

echo "AutoDJ Continuous Play plugin installed"

#requred to end the plugin install
echo "plugininstallend"
