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

    // PDFium ships only as a shared library. It is installed to lib/ next to
    // bin/, and the executable finds it relative to itself.
    const pdfium_dep_name: []const u8 = if (os == .macos and arch == .aarch64)
        "pdfium_macos_aarch64"
    else if (os == .linux and arch == .x86_64)
        "pdfium_linux_x86_64"
    else
        std.debug.panic("ptz: no PDFium build configured for {t}-{t}", .{ arch, os });
    const pdfium_lib_name = if (os == .macos) "libpdfium.dylib" else "libpdfium.so";
    // Both are null on the first configure pass while they are being fetched.
    const pdfium = b.lazyDependency(pdfium_dep_name, .{});
    const ghostty = b.lazyDependency("ghostty", .{});

    // The executable, tests and harness share sources but get separate root
    // modules, so only tests and the harness link Ghostty.
    const exe_module = createModule(b, target, optimize, "src/main.zig", pdfium);
    exe_module.addOptions("build_options", build_options);
    exe_module.addRPathSpecial(if (os == .macos) "@executable_path/../lib" else "$ORIGIN/../lib");
    const exe = b.addExecutable(.{ .name = "ptz", .root_module = exe_module });
    // Keep the fetch location out of shipped binaries; tests and the harness
    // keep the default so they load PDFium from where it was fetched.
    exe.each_lib_rpath = false;
    b.installArtifact(exe);
    if (pdfium) |dep| {
        const lib = dep.path(b.fmt("lib/{s}", .{pdfium_lib_name}));
        b.getInstallStep().dependOn(&b.addInstallLibFile(lib, pdfium_lib_name).step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run ptz");
    run_step.dependOn(&run_cmd.step);

    const test_module = createModule(b, target, optimize, "src/main.zig", pdfium);
    test_module.addOptions("build_options", build_options);
    if (ghostty) |dep| test_module.addImport("ghostty-vt", dep.module("ghostty-vt"));
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    // Test fixtures are opened by paths relative to the project root.
    run_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const harness_module = createModule(b, target, optimize, "src/harness.zig", pdfium);
    if (ghostty) |dep| harness_module.addImport("ghostty-vt", dep.module("ghostty-vt"));
    const run_harness = b.addRunArtifact(b.addExecutable(.{ .name = "harness", .root_module = harness_module }));
    run_harness.addPassthruArgs();
    const harness_step = b.step("harness", "Show a page in an emulated terminal and capture the screen");
    harness_step.dependOn(&run_harness.step);
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn createModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: []const u8,
    pdfium: ?*std.Build.Dependency,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (pdfium) |dep| {
        module.addLibraryPath(dep.path("lib"));
        module.linkSystemLibrary("pdfium", .{ .use_pkg_config = .no });
    }
    return module;
}
