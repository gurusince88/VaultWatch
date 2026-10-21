"""Renders the VaultWatch app icon (AppIcon.icns + PNGs) with Pillow.
Design: indigo rounded-square tile, a vault dial in the center, ringed by two sync arrows.
Usage: python3 scripts/make_icon.py  (writes Resources/AppIcon.icns and docs/icon.png)
"""
import io, math, os, struct
from PIL import Image, ImageDraw, ImageFilter

S = 4096                     # supersampled canvas; downsampled to every icon size
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def tile():
    # macOS icon grid: 1024 canvas, 824 tile, ~185 corner radius, soft drop shadow.
    k = S / 1024
    inset, size, radius = 100 * k, 824 * k, 185 * k
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [inset, inset + 18 * k, inset + size, inset + size + 18 * k], radius, fill=(0, 0, 0, 110))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28 * k)))

    # Diagonal gradient: deep indigo (top-left) to violet-blue (bottom-right).
    grad = Image.new("RGBA", (S, S))
    top, bottom = (49, 46, 129, 255), (99, 102, 241, 255)
    gp = grad.load()
    for y in range(0, S, 4):
        for x in range(0, S, 4):
            c = lerp(top, bottom, min(1, max(0, (x + y) / (2 * S))))
            for dy in range(4):
                for dx in range(4):
                    gp[x + dx, y + dy] = c
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, inset + size, inset + size], radius, fill=255)
    canvas.paste(grad, (0, 0), mask)

    return canvas, k

def arrow_ring(d, cx, cy, r, w, color):
    # Two arcs with a gap, each ending in an arrowhead (clockwise sync).
    # PIL strokes arcs inward from the bounding box, so the stroke's centerline is r - w/2.
    gap = 40
    rc = r - w / 2
    for start in (-90 + gap / 2, 90 + gap / 2):
        end = start + 180 - gap
        d.arc([cx - r, cy - r, cx + r, cy + r], start, end, fill=color, width=int(w))
        a = math.radians(end)
        tip_len = w * 1.9
        ex, ey = cx + rc * math.cos(a), cy + rc * math.sin(a)
        tx, ty = -math.sin(a), math.cos(a)          # clockwise tangent
        nx, ny = math.cos(a), math.sin(a)           # outward normal
        tip = (ex + tx * tip_len, ey + ty * tip_len)
        left = (ex + nx * w * 1.25, ey + ny * w * 1.25)
        right = (ex - nx * w * 1.25, ey - ny * w * 1.25)
        d.polygon([tip, left, right], fill=color)
        # Round off the arc's starting cap.
        b = math.radians(start)
        sx, sy = cx + rc * math.cos(b), cy + rc * math.sin(b)
        d.ellipse([sx - w / 2, sy - w / 2, sx + w / 2, sy + w / 2], fill=color)

def vault_dial(d, cx, cy, r, k, ink, bg):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=ink)                    # door
    rr = r * 0.80
    d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=bg, width=int(10 * k))  # inner rim
    for i in range(12):                                                       # tick marks
        a = math.radians(i * 30)
        r1, r2 = rr * 0.80, rr * 0.92
        d.line([cx + r1 * math.cos(a), cy + r1 * math.sin(a), cx + r2 * math.cos(a), cy + r2 * math.sin(a)],
               fill=bg, width=int(9 * k))
    hub = r * 0.20                                                            # handle spokes + hub
    for i in range(3):
        a = math.radians(i * 120 - 90)
        d.line([cx, cy, cx + rr * 0.58 * math.cos(a), cy + rr * 0.58 * math.sin(a)], fill=bg, width=int(22 * k))
        ex, ey = cx + rr * 0.58 * math.cos(a), cy + rr * 0.58 * math.sin(a)
        d.ellipse([ex - 18 * k, ey - 18 * k, ex + 18 * k, ey + 18 * k], fill=bg)
    d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=bg)

def render():
    img, k = tile()
    d = ImageDraw.Draw(img)
    cx = cy = S / 2
    white = (255, 255, 255, 255)
    arrow_ring(d, cx, cy, 300 * k, 50 * k, white)
    vault_dial(d, cx, cy, 175 * k, k, white, (67, 64, 170, 255))
    return img

def write_icns(master, path):
    # PNG-backed icns entries (supported since macOS 10.7).
    entries = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512),
               ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
    chunks = b""
    for code, px in entries:
        buf = io.BytesIO()
        master.resize((px, px), Image.LANCZOS).save(buf, "PNG")
        data = buf.getvalue()
        chunks += code.encode() + struct.pack(">I", len(data) + 8) + data
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)

if __name__ == "__main__":
    master = render().resize((1024, 1024), Image.LANCZOS)
    os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
    master.save(os.path.join(ROOT, "docs", "icon.png"))
    write_icns(master, os.path.join(ROOT, "Resources", "AppIcon.icns"))
    print("wrote Resources/AppIcon.icns and docs/icon.png")
