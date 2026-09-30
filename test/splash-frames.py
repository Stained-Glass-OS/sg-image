#!/usr/bin/env python3
"""Did the boot show our splash? Reads the screendumps boot-test took while the
machine started (PPM) and passes when one of them is the splash: the theme's
near-black background at the corners and over most of the screen, and the
diamond's purple and teal in the middle -- not text on black (Plymouth's
"details" fallback) and not the desktop.

    splash-frames.py FRAME.ppm...   exit 0 when one frame is the splash
"""
import sys

BG = (16, 16, 20)


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts, i = [], 0
    while len(parts) < 4:                      # P6 W H MAX, comments skipped
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            i = data.index(b"\n", i) + 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        parts.append(data[i:j])
        i = j
    if parts[0] != b"P6":
        raise ValueError("not a P6 PPM")
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[i + 1:i + 1 + w * h * 3]


def near(p, q, d=12):
    return all(abs(a - b) <= d for a, b in zip(p, q))


def is_splash(path):
    w, h, px = read_ppm(path)
    at = lambda x, y: tuple(px[(y * w + x) * 3:(y * w + x) * 3 + 3])
    if not all(near(at(x, y), BG) for x, y in ((4, 4), (w - 5, 4), (4, h - 5), (w - 5, h - 5))):
        return False
    bg = purple = teal = total = 0
    for y in range(0, h, 4):
        for x in range(0, w, 4):
            r, g, b = at(x, y)
            total += 1
            if near((r, g, b), BG):
                bg += 1
            elif r > 70 and g < 70 and b > 120:
                purple += 1
            elif r < 60 and g > 90 and b > 90:
                teal += 1
    return bg > total * 0.9 and purple > 20 and teal > 20


def main():
    seen = [p for p in sys.argv[1:] if is_splash(p)]
    print("%d of %d frames show the splash" % (len(seen), len(sys.argv) - 1))
    return 0 if seen else 1


if __name__ == "__main__":
    sys.exit(main())
