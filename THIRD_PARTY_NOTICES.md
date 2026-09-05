# Third-party notices

R4ZIP statically uses the Zig 0.16.0 standard library, in particular its
raw Deflate decoder (`std.compress.flate.Decompress`) and CRC32 support.
The Zig project licenses this code under MIT; the complete license copied
from the pinned toolchain is in `LICENSE-Zig`. No third-party compressed
payload, PKWARE specification text or host unzip executable is bundled.

ZIP format reference: PKWARE APPNOTE 6.3.10, 2022-11-01,
https://pkwaredownloads.blob.core.windows.net/pem/APPNOTE.txt .
The record parser, protocol frame and test data are original R4OS code.
