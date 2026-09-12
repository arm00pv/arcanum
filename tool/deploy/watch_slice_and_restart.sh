#!/usr/bin/env bash
# Waits for a running price slice to finish, then restarts the sync service so
# it serves the database that was just swapped in.
#
# The sync service holds the old database open and caches its counters, so a
# finished rebuild is invisible to it until it restarts. The weekly rebuild
# timer does this in its own ExecStartPost; this script is the same step for a
# rebuild that was started by hand.
while pgrep -f slice_prices.py > /dev/null; do sleep 60; done
/bin/systemctl restart arcanum-sync.service
echo "arcanum-sync restarted after the slice finished"
