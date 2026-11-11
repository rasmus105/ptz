// std
const std = @import("std");

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;

    // Version comes from build.zig.zon so release tags have a single source.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addOptions("build_options", build_options);

    // PDFium ships only as a shared library. It is installed to lib/ next to
    // bin/, and the executable finds it relative to itself.
    const pdfium_dep_name: []const u8 = if (os == .macos and arch == .aarch64)
        "pdfium_macos_aarch64"
    else if (os == .linux and arch == .x86_64)
        "pdfium_linux_x86_64"
    else
        std.debug.panic("ptz: no PDFium build configured for {t}-{t}", .{ arch, os });
    const pdfium_lib_name = if (os == .macos) "libpdfium.dylib" else "libpdfium.so";
    root_module.addRPathSpecial(if (os == .macos) "@executable_path/../lib" else "$ORIGIN/../lib");
    // Null on the first configure pass while the archive is being fetched.
    if (b.lazyDependency(pdfium_dep_name, .{})) |pdfium| {
        root_module.addLibraryPath(pdfium.path("lib"));
        root_module.linkSystemLibrary("pdfium", .{ .use_pkg_config = .no });
        const lib = pdfium.path(b.fmt("lib/{s}", .{pdfium_lib_name}));
        b.getInstallStep().dependOn(&b.addInstallLibFile(lib, pdfium_lib_name).step);
    }

    const exe = b.addExecutable(.{ .name = "ptz", .root_module = root_module });
    // Keep the fetch location out of shipped binaries; tests keep the
    // default so they load PDFium from where it was fetched.
    exe.each_lib_rpath = false;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run ptz");
    run_step.dependOn(&run_cmd.step);

    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = root_module }));
    // Test fixtures are opened by paths relative to the project root.
    run_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
