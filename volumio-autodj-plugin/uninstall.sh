#!/bin/bash

echo "Removing AutoDJ Continuous Play plugin"

# Nothing beyond the plugin's own directory (removed by Volumio itself) to
# clean up - jq is left installed since other plugins/tools may use it, and
# /data/volumio_autodj_data (repeat-guard history, debug log) is left in
# place in case the plugin is reinstalled.

#requred to end the plugin uninstall
echo "pluginuninstallend"
