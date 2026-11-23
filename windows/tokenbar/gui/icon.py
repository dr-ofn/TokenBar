"""The tray icon, drawn with Pillow: three rising bars on a dark tile."""
from __future__ import annotations

from PIL import Image, ImageDraw


def make_icon(size: int = 64) -> Image.Image:
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, s - 1, s - 1), radius=s // 5, fill=(29, 29, 31, 255))
    pad, gap = s * 0.18, s * 0.08
    bar = (s - 2 * pad - 2 * gap) / 3
    colors = [(255, 190, 90, 255), (255, 140, 70, 255), (230, 80, 40, 255)]
    heights = [0.34, 0.54, 0.76]
    for i, (c, h) in enumerate(zip(colors, heights)):
        x0 = pad + i * (bar + gap)
        top = s - pad - h * (s - 2 * pad)
        d.rounded_rectangle((x0, top, x0 + bar, s - pad), radius=bar / 3, fill=c)
    return img


def make_ico_bytes() -> bytes:
    import io
    buf = io.BytesIO()
    make_icon(256).save(buf, format="ICO", sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    return buf.getvalue()
