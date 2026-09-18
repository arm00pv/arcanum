"""Adds the Arcanum browser build to the docker Caddyfile, on the host.

    python3 ~/arcanum/tool/deploy/patch_caddy_web.py
    sudo docker exec n8n-docker-caddy-caddy-1 caddy reload \
        --config /etc/caddy/Caddyfile --adapter caddyfile

Kept as a script rather than a hand edit so the change is repeatable, reviewable
and always leaves a backup behind, in the same way as patch_caddy.py.

The browser build is a Flutter web bundle, so it brings its own base href
(/arcanumweb/) and every asset it asks for is under that prefix. handle_path
strips the prefix before the request reaches the static file server, which is
why that server needs no knowledge of the prefix at all. It listens on the
docker bridge gateway rather than on the public interface, so nothing outside
the host can reach it and only Caddy ever does - the same arrangement
arcanum-sync already has on 8787.
"""
import shutil

PATH = "/home/zixen/n8n-docker-caddy/caddy_config/Caddyfile"
BACKUP = PATH + ".bak_arcanumweb"

WEB_HANDLE = """    # The browser build of Arcanum, served by a static Caddy file server bound
    # to the docker bridge gateway. handle_path strips the /arcanumweb prefix,
    # so what the bundle asks for and what the file server answers already
    # agree. Both are listed because a bare /arcanumweb would otherwise fall
    # through to the Open WebUI catch-all below.
    redir /arcanumweb /arcanumweb/ permanent
    handle_path /arcanumweb/* {
        reverse_proxy 172.19.0.1:8099
    }
"""

with open(PATH, encoding="utf-8") as fh:
    s = fh.read()

shutil.copyfile(PATH, BACKUP)

if "/arcanumweb/*" in s:
    print("the arcanumweb route is already present")
else:
    anchor = "    handle {\n        reverse_proxy 172.19.0.1:3000"
    index = s.index(anchor)
    s = s[:index] + WEB_HANDLE + s[index:]
    with open(PATH, "w", encoding="utf-8") as fh:
        fh.write(s)
    print("added the arcanumweb route")

print("backup at", BACKUP)
