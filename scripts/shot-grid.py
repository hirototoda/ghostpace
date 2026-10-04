#!/usr/bin/env python3
"""スクリーンショットを横に並べた1枚の画像を作る（オーナーに見せる比較用）。
使い方: scripts/shot-grid.py <出力.png> <列数> <画像1> <画像2> ...
"""
import sys
from PIL import Image

out, columns, paths = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
images = [Image.open(p) for p in paths]
w, h = images[0].size
scale, gap = 0.33, 20
W, H = int(w * scale), int(h * scale)
rows = (len(images) + columns - 1) // columns
cols = min(columns, len(images))
canvas = Image.new("RGB", (W * cols + gap * (cols - 1), H * rows + gap * (rows - 1)), "white")
for i, image in enumerate(images):
    canvas.paste(image.resize((W, H)), ((i % columns) * (W + gap), (i // columns) * (H + gap)))
canvas.save(out)
print(out)
