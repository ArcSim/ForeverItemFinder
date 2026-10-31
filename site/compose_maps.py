# Lays each zone's base tiles and explored overlays into one 1002 x 668 picture, as the addon draws the map.
# usage: python -I compose_maps.py <folder with tiles.json and blp/> <out folder>   (writes <map>.jpg)
import json
import math
import os
import sys

from PIL import Image

root, out_dir = sys.argv[1], sys.argv[2]
tiles = json.load(open(os.path.join(root, "tiles.json")))
total = 0
for m, info in tiles.items():
    img = Image.new("RGBA", (1024, 768), (0, 0, 0, 255))
    for t in info["base"]:
        tile = Image.open(os.path.join(root, "blp", "%d.blp" % t["file"])).convert("RGBA")
        img.paste(tile, (t["col"] * 256, t["row"] * 256))
    for o in info["overlays"]:
        cols = math.ceil(o["w"] / 256)
        for i, f in enumerate(o["files"]):
            tile = Image.open(os.path.join(root, "blp", "%d.blp" % f)).convert("RGBA")
            x, y = o["x"] + (i % cols) * 256, o["y"] + (i // cols) * 256
            # an edge tile's file is larger than the part of the overlay it covers
            w, h = min(256, o["x"] + o["w"] - x), min(256, o["y"] + o["h"] - y)
            part = tile.crop((0, 0, min(w, tile.width), min(h, tile.height)))
            img.alpha_composite(part, (x, y))
    out = os.path.join(out_dir, m + ".jpg")
    img.crop((0, 0, 1002, 668)).convert("RGB").save(out, "JPEG", quality=84, optimize=True, progressive=True)
    total += os.path.getsize(out)
print(len(tiles), "maps,", total // 1024, "KB")
