"""Adds the Arcanum card-art route to the docker Caddyfile, on the host.

    python3 ~/arcanum/tool/deploy/patch_caddy_art.py
    sudo docker exec n8n-docker-caddy-caddy-1 caddy reload \
        --config /etc/Caddyfile --adapter caddyfile

Kept as a script rather than a hand edit so the change is repeatable, reviewable
and always leaves a backup behind, in the same way as patch_caddy_web.py.

Art is relayed for the same reason the catalogue is: a browser reads a card's
picture by fetching its bytes itself, so a CDN that will not name the asking
origin - and two of the three the app draws from will not - leaves the app with
a placeholder. The relay is the same process on the same bridge address, so this
route is the whole of the server-side change.

The block is printed before and after so the change can be read rather than
trusted.
"""
import shutil

PATH = "/home/zixen/n8n-docker-caddy/caddy_config/Caddyfile"
BACKUP = PATH + ".bak_arcanumart"

# Every name the browser build is served from. A site that does not serve it
# has no use for the route, which is why each block is checked first.
SITES = ("marquezhv.com", "zapp.sytes.net")

HANDLE = """    # Card art, from the relay on the same address as the catalogue and for the
    # same reason: a page is not allowed the bytes of a picture whose host will
    # not name it. handle_path strips the prefix, so the app asks for
    # /arcanumweb-api/art/tcgplayer/<product>.jpg and the relay sees
    # /art/tcgplayer/<product>.jpg.
    handle /arcanumweb-api/art/* {
        uri strip_prefix /arcanumweb-api
        reverse_proxy 172.19.0.1:8098
    }
"""

with open(PATH, encoding="utf-8") as fh:
    s = fh.read()

if "/arcanumweb-api/art/*" in s:
    print("--- the card-art route is already present; nothing changed ---")
else:
    changed = False
    for site in SITES:
        start = s.index(site + " {")
        end = s.index("\n}", start)
        block = s[start:end]
        print("--- %s before ---" % site)
        print(block)
        if "/arcanumweb/*" not in block:
            print("--- %s does not serve the browser build; left alone ---" % site)
            continue
        anchor = block.index("\n    handle {") + 1
        s = s[: start + anchor] + HANDLE + s[start + anchor :]
        changed = True
        print("--- added the card-art route to %s ---" % site)
    if changed:
        shutil.copyfile(PATH, BACKUP)
        with open(PATH, "w", encoding="utf-8") as fh:
            fh.write(s)
        print("--- backup at", BACKUP, "---")

start = s.index("marquezhv.com {")
end = s.index("\n}", start)
print("--- the marquezhv.com block now ---")
print(s[start:end])
