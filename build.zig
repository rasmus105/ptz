// std
const std = @import("std");

// packages
const builtin = @import("builtin");

// ====================================================================================================
// Constants
// ====================================================================================================

const mupdf_directory = "mupdf-1.28.6-source";

// ====================================================================================================
// Types
// ====================================================================================================

const Engine = struct {
    source: std.Build.LazyPath,
    libraries: std.Build.LazyPath,
};

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .macos)
            .{ .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } }
        else
            .{},
    });
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;

    // Version comes from build.zig.zon so release tags have a single source.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    if (!((os == .macos and arch == .aarch64) or (os == .linux and arch == .x86_64)))
        std.debug.panic("ptz: unsupported target {t}-{t}", .{ arch, os });
    // MuPDF's makefile uses native build tools. Do not silently link host
    // libraries when the caller requested another target.
    if (os != builtin.os.tag or arch != builtin.cpu.arch or target.result.abi != builtin.abi)
        std.debug.panic("ptz: MuPDF must be built on the target platform", .{});
    // Both are null on the first configure pass while they are being fetched.
    const mupdf = b.lazyDependency("mupdf", .{});
    const ghostty = b.lazyDependency("ghostty", .{});
    const engine: ?Engine = if (mupdf) |dep| blk: {
        // Keep the pinned package pristine; the distributed source includes
        // the same narrow corrections used to build the libraries.
        const prepare = b.addSystemCommand(&.{"sh"});
        prepare.addFileArg(b.path("vendor/mupdf/prepare.sh"));
        prepare.addDirectoryArg(dep.path(""));
        const source = prepare.addOutputDirectoryArg(mupdf_directory);
        prepare.addFileArg(b.path("vendor/mupdf/single-column.patch"));
        prepare.addFileArg(b.path("vendor/mupdf/jpeg-diagnostics.patch"));
        prepare.addFileArg(b.path("vendor/mupdf/scalable-image.patch"));
        const make = b.addSystemCommand(&.{
            "make",    "-j4",        "libs",            "USE_SYSTEM_LIBS=no", "HAVE_LIBCRYPTO=no",
            "mujs=no", "extract=no", "HAVE_OBJCOPY=no",
        });
        make.setCwd(source);
        make.addArg(if (optimize == .debug) "build=debug" else "build=release");
        make.addArg(if (os == .macos)
            b.fmt("XCFLAGS=-fPIC -mmacosx-version-min={f}", .{target.result.os.version_range.semver.min})
        else
            "XCFLAGS=-fPIC");
        const libraries = make.addOutputDirectoryArg2("mupdf", .{ .prefix = "OUT=" });

        const archive = b.addSystemCommand(&.{ "tar", "-czf" });
        archive.setEnvironmentVariable("COPYFILE_DISABLE", "1");
        const archive_file = archive.addOutputFileArg(b.fmt("{s}.tar.gz", .{mupdf_directory}));
        archive.addArg("-C");
        archive.addDirectoryArg(source.dirname());
        archive.addArg(mupdf_directory);
        const install_source = b.addInstallFileWithDir(archive_file, .prefix, b.fmt("{s}.tar.gz", .{mupdf_directory}));
        b.step("source", "Package the pinned MuPDF source for distribution").dependOn(&install_source.step);

        for ([_][]const u8{
            "COPYING",                          "README",                          "docs/other/third-party.rst",
            "thirdparty/brotli/LICENSE",        "thirdparty/cmark-gfm/COPYING",    "thirdparty/freetype/LICENSE.TXT",
            "thirdparty/freetype/docs/FTL.TXT", "thirdparty/gumbo-parser/COPYING", "thirdparty/harfbuzz/COPYING",
            "thirdparty/jbig2dec/COPYING",      "thirdparty/jbig2dec/LICENSE",     "thirdparty/libjpeg/README",
            "thirdparty/lcms2/LICENSE",         "thirdparty/openjpeg/LICENSE",     "thirdparty/zlib/LICENSE",
            "resources/fonts/han/LICENSE.txt",  "resources/fonts/sil/OFL.txt",     "resources/fonts/noto/COPYING",
            "resources/fonts/urw/OFL.txt",      "resources/fonts/droid/NOTICE",    "thirdparty/harfbuzz/src/ms-use/COPYING",
            // These components carry their notices in source headers.
            "source/fitz/ucdn.c",               "source/fitz/ftoa.c",              "source/fitz/icc34.h",
            "source/fitz/crypt-aes.c",          "source/fitz/crypt-arc4.c",        "source/fitz/crypt-md5.c",
        }) |path| {
            const install = b.addInstallFileWithDir(source.path(b, path), .prefix, b.fmt("share/ptz/licenses/mupdf/{s}", .{path}));
            b.getInstallStep().dependOn(&install.step);
        }
        const hyphen_licenses = b.addInstallDirectory(.{
            .source_dir = source.path(b, "resources/hyphen/license"),
            .install_dir = .prefix,
            .install_subdir = "share/ptz/licenses/mupdf/resources/hyphen/license",
        });
        b.getInstallStep().dependOn(&hyphen_licenses.step);
        break :blk .{ .source = source, .libraries = libraries };
    } else null;

    // The executable, tests and harness share sources but get separate root
    // modules, so only tests and the harness link Ghostty.
    const exe_module = createModule(b, target, optimize, "src/main.zig", engine);
    exe_module.addOptions("build_options", build_options);
    const exe = b.addExecutable(.{ .name = "ptz", .root_module = exe_module });
    b.installArtifact(exe);
    b.installFile("LICENSE", "share/ptz/LICENSE");
    b.installFile("NOTICE", "share/ptz/NOTICE");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run ptz");
    run_step.dependOn(&run_cmd.step);

    const test_module = createModule(b, target, optimize, "src/main.zig", engine);
    test_module.addCSourceFile(.{ .file = b.path("src/document/test.c"), .flags = &.{"-std=c11"} });
    test_module.addOptions("build_options", build_options);
    if (ghostty) |dep| test_module.addImport("ghostty-vt", dep.module("ghostty-vt"));
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    // Test fixtures are opened by paths relative to the project root.
    run_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const harness_module = createModule(b, target, optimize, "src/harness.zig", engine);
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
    engine: ?Engine,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(b.path("src/document"));
    module.addCSourceFile(.{ .file = b.path("src/document/mupdf.c"), .flags = &.{"-std=c11"} });
    if (target.result.os.tag == .linux) module.linkSystemLibrary("m", .{});
    if (engine) |compiled| {
        module.addIncludePath(compiled.source.path(b, "include"));
        module.addObjectFile(compiled.libraries.path(b, "libmupdf.a"));
        module.addObjectFile(compiled.libraries.path(b, "libmupdf-third.a"));
    }
    return module;
}
