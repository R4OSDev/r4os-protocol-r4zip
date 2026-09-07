# R4Zip

R4ZIP.R4P is the reusable ZIP protocol for R4OS x86_64. It inspects ZIP
records and extracts Stored/Deflate data into caller-owned buffers, including
the ZIP64 records and signed/unsigned descriptors used by release tooling.

Use `r4os.zip.Context` from the R4OS SDK (role `format.zip`). The caller owns
the immutable archive, entry table, output and 16 KB decoder state. Call
`inspect`, `begin`, then bounded `step` operations, yielding or cancelling
between calls. Release manifests and target filesystem policy belong to the
consumer. No host unzip program or global decoder session is required.

For large images, `beginStream` and `streamStep` use a fixed 160 KB output
window including 32 KB of Deflate history. Consume each returned chunk before
the next step; full-stream CRC and declared length checks still apply.

`Build.sh test install` on Linux or `Build.bat test install` on Windows uses
PowerShell 7, the Zig version and owner roots from `Settings.R4S`. An isolated
checkout can use Zig 0.16.0 directly with the SDK dependency pinned in
`build.zig.zon`. Tests include an actual .NET release-producer archive.

Supported paths are relative printable ASCII, at most 255 bytes, with
case-insensitive uniqueness. Unsupported methods, encryption, multipart
archives, symlinks, traversal, overlapping entries, excess entries and
inconsistent ZIP metadata fail explicitly. Maximum 4096 entries; output
sizes are 64 bit and the consumer supplies its own RAM/resource limit.

Original R4OS source: Apache-2.0. Zig's Deflate implementation: MIT (see
`LICENSE-Zig` and `THIRD_PARTY_NOTICES.md`). See `DOCUMENTATION.de.txt` for
the wire contract and supported record variants.
