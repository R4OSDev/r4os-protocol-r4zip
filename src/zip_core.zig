// ZIP records are decoded explicitly; no host filesystem or global session.
const std = @import("std");
const wire = @import("r4os").zip;
const Error = wire.Error;
const Directory = struct { offset: u64, bytes: u64, count: u32 };

fn range(bytes: []const u8, at: u64, len: u64) Error![]const u8 {
    if (at > bytes.len or len > bytes.len - at) return error.Bounds;
    return bytes[@intCast(at)..][0..@intCast(len)];
}
fn number(comptime T: type, bytes: []const u8, at: u64) Error!T {
    const field = try range(bytes, at, @sizeOf(T));
    return std.mem.readInt(T, field[0..@sizeOf(T)], .little);
}
fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.Bounds;
}
fn overlap(a: anytype, b: anytype) bool {
    if (a.len == 0 or b.len == 0) return false;
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    const an = std.math.mul(usize, a.len, @sizeOf(@TypeOf(a[0]))) catch return true;
    const bn = std.math.mul(usize, b.len, @sizeOf(@TypeOf(b[0]))) catch return true;
    return if (x <= y) y - x < an else x - y < bn;
}

fn directory(bytes: []const u8) Error!Directory {
    if (bytes.len < 22) return error.InvalidArchive;
    var at: u64 = bytes.len - 22;
    const first = bytes.len -| (22 + 65535);
    while (true) {
        if (try number(u32, bytes, at) == 0x06054b50 and at + 22 + try number(u16, bytes, at + 20) == bytes.len) break;
        if (at == first) return error.InvalidArchive;
        at -= 1;
    }
    if (try number(u16, bytes, at + 4) != 0 or try number(u16, bytes, at + 6) != 0) return error.Unsupported;
    const disk_count = try number(u16, bytes, at + 8);
    const count = try number(u16, bytes, at + 10);
    const cd_size = try number(u32, bytes, at + 12);
    const cd_offset = try number(u32, bytes, at + 16);
    var result = Directory{ .offset = cd_offset, .bytes = cd_size, .count = count };
    var cd_end = at;
    const need64 = disk_count == 0xffff or count == 0xffff or cd_size == 0xffffffff or cd_offset == 0xffffffff;
    const locator = at >= 20 and try number(u32, bytes, at - 20) == 0x07064b50;
    if (need64 and !locator) return error.InvalidArchive;
    if (locator) {
        const loc = at - 20;
        if (try number(u32, bytes, loc + 4) != 0 or try number(u32, bytes, loc + 16) != 1) return error.Unsupported;
        const e64 = try number(u64, bytes, loc + 8);
        _ = try range(bytes, e64, 56);
        if (try number(u32, bytes, e64) != 0x06064b50 or try number(u64, bytes, e64 + 4) != 44) return error.Unsupported;
        if (try add(e64, 56) != loc or try number(u16, bytes, e64 + 14) > 45) return error.InvalidArchive;
        if (try number(u32, bytes, e64 + 16) != 0 or try number(u32, bytes, e64 + 20) != 0) return error.Unsupported;
        const count64 = try number(u64, bytes, e64 + 32);
        if (count64 != try number(u64, bytes, e64 + 24)) return error.Unsupported;
        if (count64 > wire.max_entries) return error.Limit;
        result = .{ .offset = try number(u64, bytes, e64 + 48), .bytes = try number(u64, bytes, e64 + 40), .count = @intCast(count64) };
        if ((count != 0xffff and count != result.count) or (disk_count != 0xffff and disk_count != result.count) or
            (cd_size != 0xffffffff and cd_size != result.bytes) or (cd_offset != 0xffffffff and cd_offset != result.offset)) return error.InvalidArchive;
        cd_end = e64;
    } else if (disk_count != count) return error.Unsupported;
    if (result.count > wire.max_entries) return error.Limit;
    if (result.offset > cd_end or result.bytes != cd_end - result.offset or result.count > result.bytes / 46) return error.InvalidArchive;
    return result;
}

fn extra64(bytes: []const u8) Error!?[]const u8 {
    var at: u64 = 0;
    var found: ?[]const u8 = null;
    while (at < bytes.len) {
        const tag = try number(u16, bytes, at);
        const len = try number(u16, bytes, at + 2);
        const field = try range(bytes, at + 4, len);
        if (tag == 1) {
            if (found != null) return error.InvalidArchive;
            found = field;
        }
        at += 4 + @as(u64, len);
    }
    return found;
}

// A deliberately portable subset, matching the release producer on both
// hosts. Non-ASCII/codepage names have an explicit Unsupported result.
pub fn safePath(path: []const u8, is_directory: bool) Error!void {
    if (path.len == 0 or path.len > wire.max_path) return error.Limit;
    if (is_directory != (path[path.len - 1] == '/')) return error.UnsafePath;
    const content = if (is_directory) path[0 .. path.len - 1] else path;
    var components = std.mem.splitScalar(u8, content, '/');
    while (components.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.UnsafePath;
        for (part) |c| {
            if (c > 126) return error.Unsupported;
            if (c < 32 or std.mem.indexOfScalar(u8, "<>:\"\\|?*", c) != null) return error.UnsafePath;
        }
    }
}

const Parsed = struct { entry: wire.Entry, next: u64 };
fn readEntry(bytes: []const u8, at: u64, cd: Directory) Error!Parsed {
    if (at < cd.offset or at > cd.offset + cd.bytes or cd.offset + cd.bytes - at < 46) return error.Bounds;
    if (try number(u32, bytes, at) != 0x02014b50) return error.InvalidArchive;
    const need_version = try number(u16, bytes, at + 6);
    if (need_version > 45) return error.Unsupported;
    const flags = try number(u16, bytes, at + 8);
    const method = try number(u16, bytes, at + 10);
    if (method != 0 and method != 8) return error.Unsupported;
    if (flags & ~@as(u16, 0x080e) != 0 or (method == 0 and flags & 6 != 0)) return error.Unsupported;
    const name_len = try number(u16, bytes, at + 28);
    const extra_len = try number(u16, bytes, at + 30);
    const comment_len = try number(u16, bytes, at + 32);
    const next = try add(at, 46 + @as(u64, name_len) + extra_len + comment_len);
    if (next > cd.offset + cd.bytes) return error.Bounds;
    const name = try range(bytes, at + 46, name_len);
    const attrs = try number(u32, bytes, at + 38);
    const unix_type = (attrs >> 16) & 0xf000;
    const unix = try number(u16, bytes, at + 4) >> 8;
    if ((unix == 3 or unix == 19) and unix_type != 0 and unix_type != 0x8000 and unix_type != 0x4000) return error.Unsupported;
    const is_dir = name.len != 0 and name[name.len - 1] == '/';
    if ((attrs & 0x10 != 0 or ((unix == 3 or unix == 19) and unix_type == 0x4000)) and !is_dir) return error.UnsafePath;
    try safePath(name, is_dir);
    var entry = wire.Entry{ .central_offset = at, .name_offset = at + 46, .name_bytes = name_len, .compressed_bytes = try number(u32, bytes, at + 20), .bytes = try number(u32, bytes, at + 24), .local_offset = try number(u32, bytes, at + 42), .crc32 = try number(u32, bytes, at + 16), .method = method, .flags = flags, .directory = @intFromBool(is_dir) };
    var disk: u64 = try number(u16, bytes, at + 34);
    const extra = try extra64(try range(bytes, at + 46 + name_len, extra_len));
    const sizes64 = entry.bytes == 0xffffffff or entry.compressed_bytes == 0xffffffff;
    const need64 = sizes64 or entry.local_offset == 0xffffffff or disk == 0xffff;
    if (need64) {
        if (need_version < 45) return error.InvalidArchive;
        const ext = extra orelse return error.InvalidArchive;
        var pos: u64 = 0;
        inline for (.{ "bytes", "compressed_bytes", "local_offset" }) |field| {
            if (@field(entry, field) == 0xffffffff) {
                @field(entry, field) = try number(u64, ext, pos);
                pos += 8;
            }
        }
        if (disk == 0xffff) {
            disk = try number(u32, ext, pos);
            pos += 4;
        }
        if (pos != ext.len) return error.InvalidArchive;
    } else if (extra != null) return error.InvalidArchive;
    if (disk != 0) return error.Unsupported;
    if (is_dir and (entry.bytes != 0 or entry.crc32 != 0)) return error.InvalidArchive;
    if (method == 0 and entry.compressed_bytes != entry.bytes) return error.InvalidArchive;

    const local = entry.local_offset;
    if (local > cd.offset or cd.offset - local < 30) return error.Bounds;
    const local_version = try number(u16, bytes, local + 4);
    if (local_version > 45) return error.Unsupported;
    if (try number(u32, bytes, local) != 0x04034b50 or
        try number(u16, bytes, local + 6) != flags or try number(u16, bytes, local + 8) != method) return error.InvalidArchive;
    const local_name = try number(u16, bytes, local + 26);
    const local_extra = try number(u16, bytes, local + 28);
    entry.data_offset = try add(local, 30 + @as(u64, local_name) + local_extra);
    if (entry.data_offset > cd.offset or !std.mem.eql(u8, name, try range(bytes, local + 30, local_name))) return error.InvalidArchive;
    const local64 = try extra64(try range(bytes, local + 30 + local_name, local_extra));
    var compressed: u64 = try number(u32, bytes, local + 18);
    var decoded: u64 = try number(u32, bytes, local + 22);
    if (local64) |ext| {
        if (local_version < 45 or compressed != 0xffffffff or decoded != 0xffffffff or ext.len != 16) return error.InvalidArchive;
        decoded = try number(u64, ext, 0);
        compressed = try number(u64, ext, 8);
    } else if (compressed == 0xffffffff or decoded == 0xffffffff) return error.InvalidArchive;
    const crc = try number(u32, bytes, local + 14);
    if (flags & 8 != 0) {
        if ((compressed != 0 and compressed != entry.compressed_bytes) or (decoded != 0 and decoded != entry.bytes) or (crc != 0 and crc != entry.crc32)) return error.InvalidArchive;
    } else if (compressed != entry.compressed_bytes or decoded != entry.bytes or crc != entry.crc32) return error.InvalidArchive;
    entry.end_offset = try add(entry.data_offset, entry.compressed_bytes);
    if (entry.end_offset > cd.offset) return error.Bounds;
    if (flags & 8 != 0) {
        const wide = local64 != null or sizes64;
        const signed = descriptor(bytes, entry.end_offset, cd.offset, entry, wide, true);
        const unsigned = descriptor(bytes, entry.end_offset, cd.offset, entry, wide, false);
        if (signed != null and unsigned != null) return error.InvalidArchive;
        entry.end_offset = signed orelse unsigned orelse return error.InvalidArchive;
    }
    return .{ .entry = entry, .next = next };
}

fn descriptor(bytes: []const u8, start: u64, end: u64, entry: wire.Entry, wide: bool, signed: bool) ?u64 {
    const width: u64 = if (wide) 8 else 4;
    const len: u64 = 4 + width * 2 + @as(u64, if (signed) 4 else 0);
    if (start > end or len > end - start) return null;
    var at = start;
    if (signed) {
        if ((number(u32, bytes, at) catch return null) != 0x08074b50) return null;
        at += 4;
    }
    if ((number(u32, bytes, at) catch return null) != entry.crc32) return null;
    const compressed = if (wide) number(u64, bytes, at + 4) catch return null else number(u32, bytes, at + 4) catch return null;
    const decoded = if (wide) number(u64, bytes, at + 4 + width) catch return null else number(u32, bytes, at + 4 + width) catch return null;
    if (compressed != entry.compressed_bytes or decoded != entry.bytes) return null;
    return start + len;
}
fn key(bytes: []const u8, entry: wire.Entry) []const u8 {
    const name = bytes[@intCast(entry.name_offset)..][0..entry.name_bytes];
    return if (entry.directory != 0) name[0 .. name.len - 1] else name;
}
fn lessName(bytes: []const u8, a: wire.Entry, b: wire.Entry) bool {
    return std.ascii.orderIgnoreCase(key(bytes, a), key(bytes, b)) == .lt;
}
fn lessOffset(_: void, a: wire.Entry, b: wire.Entry) bool {
    return a.local_offset < b.local_offset;
}
pub fn inspect(bytes: []const u8, storage: []wire.Entry) Error!wire.Info {
    if (overlap(bytes, storage)) return error.BadRequest;
    const cd = try directory(bytes);
    if (storage.len < cd.count) return error.OutputTooSmall;
    const entries = storage[0..cd.count];
    var info = wire.Info{ .entries = cd.count, .central_offset = cd.offset, .central_bytes = cd.bytes };
    var cursor = cd.offset;
    for (entries) |*entry| {
        const parsed = try readEntry(bytes, cursor, cd);
        entry.* = parsed.entry;
        cursor = parsed.next;
        info.total_bytes = try add(info.total_bytes, entry.bytes);
        if (entry.directory == 0) info.files += 1;
    }
    if (cursor != cd.offset + cd.bytes) return error.InvalidArchive;
    std.sort.pdq(wire.Entry, entries, {}, lessOffset);
    var previous_end: u64 = 0;
    for (entries) |entry| {
        if (entry.local_offset < previous_end) return error.InvalidArchive;
        previous_end = entry.end_offset;
    }
    std.sort.pdq(wire.Entry, entries, bytes, lessName);
    for (entries, 0..) |entry, i| {
        const name = key(bytes, entry);
        if (i != 0 and std.ascii.eqlIgnoreCase(name, key(bytes, entries[i - 1]))) return error.DuplicatePath;
        for (name, 0..) |c, pos| {
            if (c != '/') continue;
            const parent = name[0..pos];
            var left: usize = 0;
            var right: usize = entries.len;
            while (left < right) {
                const middle = left + (right - left) / 2;
                switch (std.ascii.orderIgnoreCase(key(bytes, entries[middle]), parent)) {
                    .lt => left = middle + 1,
                    .gt => right = middle,
                    .eq => {
                        if (entries[middle].directory == 0) return error.UnsafePath;
                        break;
                    },
                }
            }
        }
    }
    return info;
}

// Caller-owned private format. Increment magic on incompatible state layout
// changes. No allocation, I/O, protocol context or callback survives a call.
const magic: u64 = 0x32504f5a34525354;
const Deflate = @import("flate/Decompress.zig");
const State = struct {
    magic: u64,
    owner: usize,
    input: std.Io.Reader,
    decoder: Deflate,
    output: []u8,
    written: usize,
    expected_bytes: usize,
    streaming: bool,
    window_end: usize,
    expected_crc: u32,
    crc: std.hash.Crc32,
    method: u16,
    finished: bool,
};
comptime {
    if (@sizeOf(State) > wire.work_bytes or @alignOf(State) > wire.work_alignment) @compileError("ZIP workspace contract too small");
}
pub fn begin(bytes: []const u8, entry: wire.Entry, output: []u8, work: []align(wire.work_alignment) u8) Error!wire.Progress {
    return beginMode(bytes, entry, output, work, false);
}
pub fn beginStream(bytes: []const u8, entry: wire.Entry, output: []u8, work: []align(wire.work_alignment) u8) Error!wire.Progress {
    return beginMode(bytes, entry, output, work, true);
}
fn beginMode(bytes: []const u8, entry: wire.Entry, output: []u8, work: []align(wire.work_alignment) u8, streaming: bool) Error!wire.Progress {
    if (work.len != wire.work_bytes or overlap(bytes, work) or overlap(output, work) or overlap(bytes, output)) return error.BadRequest;
    const state: *State = @ptrCast(work.ptr);
    state.magic = 0;
    const parsed = try readEntry(bytes, entry.central_offset, try directory(bytes));
    if (!std.meta.eql(parsed.entry, entry)) return error.Stale;
    if (entry.bytes > std.math.maxInt(usize)) return error.Limit;
    if (streaming) {
        if (output.len < wire.stream_history_bytes + wire.min_step_bytes) return error.OutputTooSmall;
    } else if (entry.bytes > output.len) return error.OutputTooSmall;
    const compressed = try range(bytes, entry.data_offset, entry.compressed_bytes);
    state.owner = @intFromPtr(state);
    state.input = std.Io.Reader.fixed(compressed);
    state.decoder = .init(&state.input, .raw, &.{});
    state.output = if (streaming) output else output[0..@intCast(entry.bytes)];
    state.expected_bytes = @intCast(entry.bytes);
    state.streaming = streaming;
    state.window_end = wire.stream_history_bytes;
    state.written = 0;
    state.expected_crc = entry.crc32;
    state.crc = .init();
    state.method = entry.method;
    state.finished = false;
    state.magic = magic;
    return .{};
}
pub fn step(work: []align(wire.work_alignment) u8, budget: u32) Error!wire.Progress {
    return stepMode(work, budget, false);
}
pub fn streamStep(work: []align(wire.work_alignment) u8, budget: u32) Error!wire.Progress {
    return stepMode(work, budget, true);
}
fn stepMode(work: []align(wire.work_alignment) u8, budget: u32, streaming: bool) Error!wire.Progress {
    if (work.len != wire.work_bytes or budget < wire.min_step_bytes or budget > wire.max_step_bytes) return error.BadRequest;
    const state: *State = @ptrCast(work.ptr);
    if (state.magic != magic or state.owner != @intFromPtr(state)) return error.Stale;
    if (state.streaming != streaming) return error.BadRequest;
    return advance(state, budget) catch |err| {
        state.magic = 0;
        return err;
    };
}
fn advance(state: *State, budget: u32) Error!wire.Progress {
    if (state.finished) return .{ .written = state.written, .done = 1 };
    const total_before = state.written;
    if (state.streaming) {
        const keep = @min(total_before, wire.stream_history_bytes);
        @memmove(state.output[wire.stream_history_bytes - keep .. wire.stream_history_bytes], state.output[state.window_end - keep .. state.window_end]);
    }
    const before = if (state.streaming) wire.stream_history_bytes else total_before;
    const limit = @min(@as(usize, budget), state.output.len - before);
    const remaining = state.expected_bytes - total_before;
    var end = before;
    var ended = false;
    if (state.method == 0) {
        const count = @min(limit, remaining);
        @memcpy(state.output[before..][0..count], state.input.buffer[total_before..][0..count]);
        end += count;
        state.input.seek = total_before + count;
        ended = count == remaining;
    } else {
        // Restore current module vtables on entry; only decoder data is kept
        // in the caller's workspace between dispatches.
        state.input.vtable = std.Io.Reader.fixed(state.input.buffer).vtable;
        state.decoder.input = &state.input;
        state.decoder.reader.vtable = Deflate.init(&state.input, .raw, &.{}).reader.vtable;
        const origin = if (state.streaming) wire.stream_history_bytes - @min(total_before, wire.stream_history_bytes) else 0;
        var writer = std.Io.Writer.fixed(state.output[origin..]);
        writer.end = before - origin;
        // Clamp to the declared output remainder. A final empty stored
        // Deflate block must still be consumed with a zero-byte limit, while
        // pending literals/matches after that boundary are an invalid size.
        if (remaining == 0) switch (state.decoder.state) {
            .fixed_block_literal, .dynamic_block_literal, .fixed_block_match, .dynamic_block_match => return error.InvalidArchive,
            else => {},
        };
        const input_before = state.input.seek;
        const bits_before = state.decoder.consumed_bits;
        const tag_before = std.meta.activeTag(state.decoder.state);
        _ = state.decoder.reader.stream(&writer, .limited(@min(limit, remaining))) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return error.Inflate,
        };
        end = origin + writer.end;
        ended = state.decoder.state == .end;
        if (!ended and end == before and state.input.seek == input_before and
            state.decoder.consumed_bits == bits_before and std.meta.activeTag(state.decoder.state) == tag_before) return error.InvalidArchive;
    }
    state.written = total_before + end - before;
    state.window_end = end;
    state.crc.update(state.output[before..end]);
    if (ended) {
        if (state.written != state.expected_bytes or state.input.seek != state.input.end) return error.InvalidArchive;
        if (state.crc.final() != state.expected_crc) return error.Checksum;
        state.finished = true;
    }
    return .{ .written = state.written, .done = @intFromBool(ended), .reserved = if (state.streaming) @intCast(end - before) else 0 };
}
