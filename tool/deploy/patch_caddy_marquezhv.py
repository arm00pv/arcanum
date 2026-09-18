"""Serves the Arcanum browser build from marquezhv.com as well.

    python3 ~/arcanum/tool/deploy/patch_caddy_marquezhv.py
    sudo docker exec n8n-docker-caddy-caddy-1 caddy reload \
        --config /etc/caddy/Caddyfile --adapter caddyfile

This host turns out to be the watchtower itself: marquezhv.com and
zapp.sytes.net both resolve here and are both served by this one Caddy, so the
app needs no new machine and no tailscale hop - just a route on the site that
already exists, pointing at the same static file server.

The block is printed before and after so the change can be read rather than
trusted."""
import shutil

PATH = "/home/zixen/n8n-docker-caddy/caddy_config/Caddyfile"
BACKUP = PATH + ".bak_arcanumweb_marquezhv"

HANDLE = """    # The browser build of Arcanum, on the name people will actually type.
    # handle_path strips the prefix, so the bundle built with
    # --base-href /arcanumweb/ lines up with a file server that knows nothing
    # about it. Listed before the catch-all, which answers every other path on
    # this site with the landing page.
    redir /arcanumweb /arcanumweb/ permanent
    handle_path /arcanumweb/* {
        reverse_proxy 172.19.0.1:8099
    }
"""

with open(PATH, encoding="utf-8") as fh:
    s = fh.read()

start = s.index("marquezhv.com {")
end = s.index("\n}", start)
block = s[start:end]

print("--- the marquezhv.com block as it stands ---")
print(block)

if "/arcanumweb/*" in block:
    print("--- already routed; nothing changed ---")
else:
    shutil.copyfile(PATH, BACKUP)
    anchor = block.index("\n    handle {") + 1
    s = s[: start + anchor] + HANDLE + s[start + anchor :]
    with open(PATH, "w", encoding="utf-8") as fh:
        fh.write(s)
    print("--- added the arcanumweb route, backup at", BACKUP, "---")

start = s.index("marquezhv.com {")
end = s.index("\n}", start)
print("--- the block now ---")
print(s[start:end])
