"""Upright asymmetric webcam-transport fixture; no camera/microphone capture.

Pixels are authored in display/top-left coordinates, independently of encoder
transforms. Existing transport sourceKind=1 identifies Mac camera frames.
"""
import argparse
import mmap
import os
import signal
import struct
import time

parser = argparse.ArgumentParser()
parser.add_argument("--seconds", type=float, default=60)
args = parser.parse_args()
def stop(signum, frame):
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
path = "/private/tmp/SimulatorCamera/frame.bin"
os.makedirs(os.path.dirname(path), exist_ok=True)
fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
inode = os.fstat(fd).st_ino
os.ftruncate(fd, 64 + 1920 * 1080 * 4)
store = mmap.mmap(fd, 0)
os.close(fd)
w, h = 640, 360
colors = [bytes((0, 0, 230, 255)), bytes((0, 210, 0, 255)),
          bytes((230, 0, 0, 255)), bytes((0, 220, 220, 255))]
pixels = bytearray().join((colors[0] * (w // 2) + colors[1] * (w // 2)) for _ in range(h // 2))
pixels += bytearray().join((colors[2] * (w // 2) + colors[3] * (w // 2)) for _ in range(h // 2))
glyphs = {
    "T": [31, 4, 4, 4, 4, 4, 4], "O": [14, 17, 17, 17, 17, 17, 14],
    "P": [30, 17, 17, 30, 16, 16, 16], "L": [16, 16, 16, 16, 16, 16, 31],
    "R": [30, 17, 17, 30, 20, 18, 17], "B": [30, 17, 17, 30, 17, 17, 30],
}
def label(text, x, y):
    for letter in text:
        for row, bits in enumerate(glyphs[letter]):
            for col in range(5):
                if bits & (1 << (4 - col)):
                    for dy in range(5):
                        start = ((y + row * 5 + dy) * w + x + col * 5) * 4
                        pixels[start:start + 20] = bytes((255, 255, 255, 255)) * 5
        x += 30
label("TOP", 275, 10)
label("TL", 15, 15); label("TR", 565, 15)
label("BL", 15, 310); label("BR", 565, 310)
start = time.monotonic()
frame = 0
try:
    while time.monotonic() - start < args.seconds:
        frame += 1
        data = bytearray(pixels)
        # Moving mark at the center, clear of the independent corner checks.
        x = 280 + frame % 80
        for y in range(140, 220):
            offset = (y * w + x) * 4
            data[offset:offset + 16] = bytes((255, 255, 255, 255)) * 4
        struct.pack_into("<Q", store, 24, frame * 2 - 1)
        struct.pack_into("<IIIIII", store, 0, 0x31464353, 1, w, h, w * 4, 1)
        struct.pack_into("<d", store, 32, time.time())
        store[64:64 + len(data)] = data
        struct.pack_into("<Q", store, 24, frame * 2)
        time.sleep(1 / 30)
finally:
    store.close()
    if os.path.exists(path) and os.stat(path).st_ino == inode:
        os.unlink(path)
