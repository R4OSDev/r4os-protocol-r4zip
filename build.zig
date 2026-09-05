const std = @import("std");
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const dependency = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, dependency, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));
    const root = b.createModule(.{ .root_source_file = b.path("Tests/main.zig"), .target = b.graph.host, .optimize = .Debug });
    const host_r4os = sdk.createR4osModule(b.graph.host, .Debug);
    root.addImport("r4os", host_r4os);
    const core = b.createModule(.{ .root_source_file = b.path("src/zip_core.zig"), .target = b.graph.host, .optimize = .Debug });
    core.addImport("r4os", host_r4os);
    root.addImport("core", core);
    const tests = b.addTest(.{ .root_module = root });
    const run = b.addRunArtifact(tests);
    b.step("test", "ZIP record, path, CRC and bounded extraction contract").dependOn(&run.step);
}
