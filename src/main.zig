const r4os = @import("r4os");
const wire = r4os.zip;
const core = @import("zip_core.zig");
comptime {
    asm (r4os.r4dev.protocolEntriesAsm("zip_init", "zip_shutdown", "zip_query", "zip_dispatch"));
}
export fn zip_init(api: *const r4os.r4dev.ProtocolApi) callconv(.c) i32 {
    var ctx = r4os.r4dev.ProtocolContext.init(api);
    _ = ctx.registerRole(wire.role, .data, 0);
    _ = ctx.setStatus(.active, "ZIP ready");
    return 0;
}
export fn zip_shutdown() callconv(.c) i32 {
    return 0;
}
export fn zip_query(out: *r4os.abi.ProtocolStatus) callconv(.c) i32 {
    out.* = .{ .state = @intFromEnum(r4os.abi.ProtocolState.active) };
    return 0;
}
fn requestOf(input: *const r4os.abi.ProtocolBuffer) wire.Error!*const wire.Request {
    const ptr = input.data orelse return error.BadRequest;
    if (input.len != @sizeOf(wire.Request) or @intFromPtr(ptr) % @alignOf(wire.Request) != 0) return error.BadRequest;
    const request: *const wire.Request = @ptrCast(@alignCast(ptr));
    if (request.version != wire.contract_version or request.size != @sizeOf(wire.Request) or request.reserved != 0) return error.BadRequest;
    return request;
}
fn outputAs(comptime T: type, output: *r4os.abi.ProtocolBuffer) wire.Error!*T {
    const ptr = output.data orelse return error.BadRequest;
    if (output.capacity < @sizeOf(T) or @intFromPtr(ptr) % @alignOf(T) != 0) return error.OutputTooSmall;
    return @ptrCast(@alignCast(ptr));
}
export fn zip_dispatch(op: u32, input: *const r4os.abi.ProtocolBuffer, output: *r4os.abi.ProtocolBuffer) callconv(.c) i32 {
    output.len = 0;
    dispatch(op, input, output) catch |err| return wire.status(err);
    return 0;
}
fn dispatch(op: u32, input: *const r4os.abi.ProtocolBuffer, output: *r4os.abi.ProtocolBuffer) wire.Error!void {
    const request = try requestOf(input);
    switch (op) {
        wire.op_inspect => {
            const out = try outputAs(wire.Info, output);
            const bytes = request.archive orelse return error.BadRequest;
            const entries = request.entries orelse return error.BadRequest;
            if (request.entry_capacity > wire.max_entries) return error.Limit;
            out.* = try core.inspect(bytes[0..@intCast(request.archive_bytes)], entries[0..request.entry_capacity]);
            output.len = @sizeOf(wire.Info);
        },
        wire.op_begin, wire.op_begin_stream => {
            const out = try outputAs(wire.Progress, output);
            const bytes = request.archive orelse return error.BadRequest;
            const entry = request.entry orelse return error.BadRequest;
            const work = request.work orelse return error.BadRequest;
            const decoded = request.output orelse return error.BadRequest;
            if (request.work_len != wire.work_bytes) return error.BadRequest;
            out.* = if (op == wire.op_begin)
                try core.begin(bytes[0..@intCast(request.archive_bytes)], entry.*, decoded[0..@intCast(request.output_bytes)], work[0..wire.work_bytes])
            else
                try core.beginStream(bytes[0..@intCast(request.archive_bytes)], entry.*, decoded[0..@intCast(request.output_bytes)], work[0..wire.work_bytes]);
            output.len = @sizeOf(wire.Progress);
        },
        wire.op_step, wire.op_step_stream => {
            const out = try outputAs(wire.Progress, output);
            const work = request.work orelse return error.BadRequest;
            if (request.work_len != wire.work_bytes) return error.BadRequest;
            out.* = if (op == wire.op_step) try core.step(work[0..wire.work_bytes], request.step_bytes) else try core.streamStep(work[0..wire.work_bytes], request.step_bytes);
            output.len = @sizeOf(wire.Progress);
        },
        else => return error.Unsupported,
    }
}
