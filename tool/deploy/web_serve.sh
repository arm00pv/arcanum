#!/bin/bash
# Serves the Arcanum browser build to Caddy, and to nothing else.
#
#   bash ~/arcanum/tool/deploy/web_serve.sh
#
# The bundle lives in ~/arcanum/web and is uploaded from the build machine. The
# listener is bound to the docker bridge gateway, which is the address the Caddy
# container reaches the host on - the same one arcanum-sync is reached on. It is
# deliberately not bound to the public interface: https://zapp.sytes.net/arcanumweb/
# is the way in, and it is the only way in.
set -e

ROOT=/home/zixen/arcanum/web
LOG=/home/zixen/arcanum/logs/web-spike.log
PORT=8099

# Stops only the process listening on 8099. This host also serves the PopVault
# bundle from a second `caddy file-server`, on 8100; `pkill -f "caddy file-server"`
# matched by command line rather than by port and killed that one too, so
# restarting Arcanum silently took marquezhv.com/popvault/ offline.
OLD=$(ss -tlnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)
if [ -n "$OLD" ]; then
    kill "$OLD" 2>/dev/null || true
    sleep 1
fi
setsid nohup /usr/bin/caddy file-server --root "$ROOT" --listen 172.19.0.1:8099 --access-log \
    > "$LOG" 2>&1 < /dev/null &
sleep 2

echo "--- listening ---"
ss -tlnp | grep ":$PORT" || echo "not listening"
echo "--- through the bridge address ---"
curl -s -o /dev/null -w "index %{http_code}\n" http://172.19.0.1:8099/
curl -s -o /dev/null -w "wasm  %{http_code} %{content_type}\n" http://172.19.0.1:8099/sqlite3.wasm
