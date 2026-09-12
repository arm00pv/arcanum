"""Adds the Arcanum price-history route to the docker Caddyfile.

Run on the watchtower host. Kept as a script rather than a hand edit so the
change is repeatable, reviewable, and always leaves a backup behind.

    python3 ~/arcanum/patch_caddy.py
    sudo docker exec n8n-docker-caddy-caddy-1 caddy reload \
        --config /etc/caddy/Caddyfile --adapter caddyfile
"""
import shutil

PATH = "/home/zixen/n8n-docker-caddy/caddy_config/Caddyfile"
BACKUP = PATH + ".bak_arcanum"

NEW_ZAPP = """zapp.sytes.net {
    # Arcanum card price history, served by arcanum-sync.service on the host.
    # strip_prefix turns https://zapp.sytes.net/arcanum/v1/history/<id>.json
    # into the /v1/history/<id>.json that the service answers.
    handle /arcanum/* {
        uri strip_prefix /arcanum
        reverse_proxy 172.19.0.1:8787
    }
    handle {
        reverse_proxy 172.19.0.1:3000
    }
}
"""

N8N = """
8n8.sytes.net {
    reverse_proxy 172.19.0.1:5678
}
"""


def block_span(text, header):
    """The span of a top-level site block, closing brace included."""
    i = text.index(header)
    start = text.rindex("\n", 0, i) + 1
    end = text.index("\n}", i) + 2
    return start, end


with open(PATH, encoding="utf-8") as fh:
    s = fh.read()

shutil.copyfile(PATH, BACKUP)

if "/arcanum/*" not in s:
    start, end = block_span(s, "zapp.sytes.net {")
    s = s[:start] + NEW_ZAPP + s[end:]
    print("rewrote the zapp.sytes.net block")
else:
    print("arcanum route already present")

if "8n8.sytes.net {" not in s:
    s += N8N
    print("added 8n8.sytes.net")
else:
    print("8n8.sytes.net already present")

with open(PATH, "w", encoding="utf-8") as fh:
    fh.write(s)
print("backup at", BACKUP)
