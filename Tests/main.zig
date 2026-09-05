const std = @import("std");
const wire = @import("r4os").zip;
const core = @import("core");
const t = std.testing;
const payload = @embedFile("Fixtures/payload.bin");

fn unpack(bytes: []const u8, budget: u32) !void {
    return unpackExpected(bytes, payload, budget);
}
fn unpackExpected(bytes: []const u8, expected: []const u8, budget: u32) !void {
    var entries: [8]wire.Entry = undefined;
    const info = try core.inspect(bytes, &entries);
    try t.expectEqual(@as(u32, 1), info.files);
    try t.expectEqual(@as(u64, expected.len), info.total_bytes);
    const output = try t.allocator.alloc(u8, expected.len + 2);
    defer t.allocator.free(output);
    @memset(output, 0x5a);
    const work = try t.allocator.create(wire.Work);
    defer t.allocator.destroy(work);
    var progress = try core.begin(bytes, entries[0], output[1 .. output.len - 1], &work.data);
    var steps: usize = 0;
    while (progress.done == 0) {
        const before = progress.written;
        progress = try core.step(&work.data, budget);
        try t.expect(progress.written >= before and progress.written - before <= budget);
        steps += 1;
        if (steps > expected.len + 10) return error.TestUnexpectedResult;
    }
    try t.expectEqualSlices(u8, expected, output[1 .. output.len - 1]);
    try t.expectEqual(@as(u8, 0x5a), output[0]);
    try t.expectEqual(@as(u8, 0x5a), output[output.len - 1]);
    try t.expectEqual(progress, try core.step(&work.data, budget));
}

test "Stored and Deflate with 32/64-bit descriptors and local/end ZIP64" {
    inline for (.{ "stored.zip", "deflate.zip", "dotnet.zip", "descriptor.zip", "unsigned-descriptor.zip", "local64.zip", "central64.zip", "descriptor64.zip", "end64.zip" }) |file| {
        try unpack(@embedFile("Fixtures/" ++ file), 32768);
    }
    try unpack(@embedFile("Fixtures/deflate.zip"), wire.min_step_bytes);
}

test "fixed-to-stored Deflate transition respects the remaining step budget" {
    for ([_]u32{ wire.min_step_bytes, 333, 32768 }) |budget|
        try unpackExpected(@embedFile("Fixtures/mixed-blocks.zip"), @embedFile("Fixtures/mixed-blocks.bin"), budget);
}

test "portable paths, case collisions and file-parent conflicts precede extraction" {
    var entries: [8]wire.Entry = undefined;
    try t.expectError(error.DuplicatePath, core.inspect(@embedFile("Fixtures/collision.zip"), &entries));
    try t.expectError(error.UnsafePath, core.inspect(@embedFile("Fixtures/parent-file.zip"), &entries));
    try t.expectError(error.UnsafePath, core.inspect(@embedFile("Fixtures/traversal.zip"), &entries));
    try t.expectError(error.Unsupported, core.inspect(@embedFile("Fixtures/symlink.zip"), &entries));
    try t.expectError(error.InvalidArchive, core.inspect(@embedFile("Fixtures/overlap.zip"), &entries));
    for ([_][]const u8{ "/absolute", "C:/x", "a\\b", "a//b", "a/./b", "a/../b", "a. ", "a\x00b" }) |path| try t.expectError(error.UnsafePath, core.safePath(path, false));
    try t.expectError(error.Unsupported, core.safePath("a/\xc3\xb6", false));
    const info = try core.inspect(@embedFile("Fixtures/directories.zip"), &entries);
    try t.expectEqual(@as(u32, 3), info.entries);
    try t.expectEqual(@as(u32, 2), info.files);
}

test "truncations, CRC damage, stale entries, undersized buffers and invalid work fail" {
    const original = @embedFile("Fixtures/stored.zip");
    const bytes = try t.allocator.dupe(u8, original);
    defer t.allocator.free(bytes);
    var entries: [8]wire.Entry = undefined;
    for ([_]usize{ 0, 1, 21, 22, 50, original.len - 1 }) |len| {
        if (core.inspect(bytes[0..len], &entries)) |_| return error.TestUnexpectedResult else |_| {}
    }
    try t.expectError(error.OutputTooSmall, core.inspect(bytes, &.{}));
    _ = try core.inspect(bytes, &entries);
    const output = try t.allocator.alloc(u8, payload.len);
    defer t.allocator.free(output);
    const work = try t.allocator.create(wire.Work);
    defer t.allocator.destroy(work);
    @memset(&work.data, 0);
    try t.expectError(error.Stale, core.step(&work.data, wire.min_step_bytes));
    try t.expectError(error.OutputTooSmall, core.begin(bytes, entries[0], output[0..1], &work.data));
    var stale = entries[0];
    stale.bytes -= 1;
    try t.expectError(error.Stale, core.begin(bytes, stale, output, &work.data));
    bytes[@intCast(entries[0].data_offset)] ^= 1;
    _ = try core.begin(bytes, entries[0], output, &work.data);
    try t.expectError(error.BadRequest, core.step(&work.data, 0));
    try t.expectError(error.BadRequest, core.step(&work.data, wire.min_step_bytes - 1));
    try t.expectError(error.Checksum, core.step(&work.data, wire.max_step_bytes));
    try t.expectError(error.Stale, core.step(&work.data, wire.min_step_bytes));
}

test "protocol error codes are disjoint from generic dispatch errors" {
    inline for (std.meta.fields(wire.Error)) |field| {
        const err = @field(wire.Error, field.name);
        try t.expectError(err, wire.check(wire.status(err)));
    }
    try t.expectError(error.Unavailable, wire.check(-5));
}

test "empty Deflate blocks and a final zero-output block terminate without overrun" {
    var entries: [8]wire.Entry = undefined;
    const work = try t.allocator.create(wire.Work);
    defer t.allocator.destroy(work);
    inline for (.{ "empty-stored-block.zip", "final-empty-block.zip" }) |name| {
        const bytes = @embedFile("Fixtures/" ++ name);
        _ = try core.inspect(bytes, &entries);
        var out: [5]u8 = .{0x5a} ** 5;
        var state = try core.begin(bytes, entries[0], out[1..][0..@intCast(entries[0].bytes)], &work.data);
        var steps: usize = 0;
        while (state.done == 0 and steps < 8) : (steps += 1) state = try core.step(&work.data, wire.min_step_bytes);
        try t.expectEqual(@as(u32, 1), state.done);
        try t.expectEqual(@as(u8, 0x5a), out[0]);
        try t.expectEqual(@as(u8, 0x5a), out[entries[0].bytes + 1]);
        if (entries[0].bytes != 0) try t.expectEqualSlices(u8, "abc", out[1..4]);
    }
    const bad = @embedFile("Fixtures/wrong-output-size.zip");
    _ = try core.inspect(bad, &entries);
    var out: [2]u8 = undefined;
    _ = try core.begin(bad, entries[0], &out, &work.data);
    _ = try core.step(&work.data, wire.min_step_bytes);
    try t.expectError(error.InvalidArchive, core.step(&work.data, wire.min_step_bytes));
}
