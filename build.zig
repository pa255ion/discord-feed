//! Builds the Qt shim with the system C++ compiler (Qt from nixpkgs uses
//! libstdc++, so it can't go through zig's bundled libc++), then links the
//! Zig executable against it.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cxx = b.option([]const u8, "cxx", "C++ compiler for the Qt shim") orelse "c++";

    const qt_flags = b.run(&.{ "pkg-config", "--cflags", "--libs", "Qt6Widgets", "Qt6Network" });
    var qt_args: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, qt_flags, " \t\r\n");
    while (it.next()) |arg| qt_args.append(b.allocator, arg) catch @panic("OOM");

    const shim = b.addSystemCommand(&.{ cxx, "-std=c++17", "-shared", "-fPIC", "-O2", "-Wall", "-Wl,-soname,libdfshim.so" });
    shim.addArg("-o");
    const shim_so = shim.addOutputFileArg("libdfshim.so");
    shim.addFileArg(b.path("src/shim.cpp"));
    shim.addPrefixedDirectoryArg("-I", b.path("src"));
    shim.addArgs(qt_args.items);
    shim.addFileInput(b.path("src/shim.h"));

    const exe = b.addExecutable(.{
        .name = "discord-feed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addObjectFile(shim_so);
    exe.root_module.addRPathSpecial("$ORIGIN/../lib");
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&b.addInstallLibFile(shim_so, "libdfshim.so").step);

    // Run the installed copy so $ORIGIN/../lib finds the shim.
    const run = b.addSystemCommand(&.{b.getInstallPath(.bin, "discord-feed")});
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the overlay").dependOn(&run.step);
}
