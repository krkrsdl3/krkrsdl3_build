"""Check the alpha captures produced by logo_end_test.tjs for this logo fixture."""
from pathlib import Path
import struct
import sys


def pixels(path):
    data = path.read_bytes()
    assert data[:2] == b"BM", path
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    assert struct.unpack_from("<H", data, 28)[0] == 32, path
    size = width * abs(height) * 4
    assert width > 0 and size > 0 and len(data) >= offset + size, path
    return data[offset:offset + size]


for argument in sys.argv[1:]:
    folder = Path(argument)
    for frame in (143, 144, 145, 227):
        assert any(pixels(folder / f"frame_{frame}.bmp")), f"Prematurely hidden at {frame}: {folder}"
    for frame in (240, 241, 242, 260, 360):
        assert not any(pixels(folder / f"frame_{frame}.bmp")), f"Logo reappeared at {frame}: {folder}"
    print(f"PASS: {folder} (visible before the end, then transparent through frame 360)")
