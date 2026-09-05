# Third-party notices

R4ZIP statically uses the Zig 0.16.0 standard library, in particular its
raw Deflate decoder and CRC32 support. `src/flate/Decompress.zig` and
`src/flate/token.zig` are copies from the pinned Zig 0.16.0 toolchain.
The decoder copy omits upstream fixture tests and adjusts its std import.
Its stored-block path uses the remaining per-call output budget: the upstream
version uses the initial limit even after preceding Huffman output in the
same call. R4ZIP's mixed-block regression covers that correction.
The Zig project licenses this code under MIT; the complete license copied
from the pinned toolchain is in `LICENSE-Zig`. No third-party compressed
payload, PKWARE specification text or host unzip executable is bundled.

ZIP format reference: PKWARE APPNOTE 6.3.10, 2022-11-01,
https://pkwaredownloads.blob.core.windows.net/pem/APPNOTE.txt .
The record parser, protocol frame and test data are original R4OS code.
