//! Declarative command-line parsing driven by an options struct.
//!
//! The caller describes its CLI as a plain struct: each field is an option,
//! its type decides how the value is parsed, and its default is the option's
//! default. Metadata lives in declarations on the same struct, so the parser
//! and the generated help page share one source of truth:
//!
//!     const Options = struct {
//!         file: []const u8,
//!         page: u32 = 1,
//!
//!         pub const positional = .{ .file = "PDF file to open" };
//!         pub const shorts = .{ .page = 'p' };
//!         pub const help = .{ .page = "Open at page N" };
//!     };
//!
//!     const options = try Cli(Options, .{ .name = "ptz", ... }).parse(init);
//!
//! Field `foo_bar` becomes `--foo-bar`, or `--no-foo-bar` for a bool that
//! defaults to true. Fields without a default are required.
//! `-h`/`--help` and `--version` are built in. Inconsistent metadata (missing
//! help, unknown keys, duplicate shorts) is a compile error.

// std
const std = @import("std");

// aliases
const Terminal = std.Io.Terminal;

// ====================================================================================================
// Types
// ====================================================================================================

/// Program-level information shown by `--help` and `--version`.
pub const Info = struct {
    name: []const u8,
    summary: []const u8,
    version: []const u8,
    examples: []const []const u8 = &.{},
};

/// Why parsing stopped without producing options. Help and version requests
/// are included because, like errors, they must short-circuit validation:
/// `ptz --help` has no `<file>` but must not fail for it.
pub const Stop = error{
    HelpRequested,
    VersionRequested,
    UnknownOption,
    MissingValue,
    UnexpectedValue,
    InvalidValue,
    MissingArgument,
    UnexpectedArgument,
};

/// Context for the most recent `Stop`, since Zig errors cannot carry the
/// offending argument.
pub const Diagnostic = struct {
    /// The option or argument the error refers to, e.g. `--page` or `<file>`.
    subject: []const u8 = "",
    /// The rejected value, for `error.InvalidValue`.
    value: []const u8 = "",
    /// What the value should have looked like, for `error.InvalidValue`.
    expected: []const u8 = "",

    pub fn write(d: Diagnostic, stop: Stop, t: Terminal) Terminal.SetColorError!void {
        try t.setColor(.bold);
        try t.setColor(.red);
        try t.writer.writeAll("error:");
        try t.setColor(.reset);
        switch (stop) {
            error.HelpRequested, error.VersionRequested => unreachable,
            error.UnknownOption => try t.writer.print(" unknown option '{s}'\n", .{d.subject}),
            error.MissingValue => try t.writer.print(" option '{s}' requires a value\n", .{d.subject}),
            error.UnexpectedValue => try t.writer.print(" option '{s}' does not take a value\n", .{d.subject}),
            error.InvalidValue => try t.writer.print(
                " invalid value '{s}' for '{s}', expected {s}\n",
                .{ d.value, d.subject, d.expected },
            ),
            error.MissingArgument => try t.writer.print(" missing required {s}\n", .{d.subject}),
            error.UnexpectedArgument => try t.writer.print(" unexpected argument '{s}'\n", .{d.subject}),
        }
    }
};

/// Comptime description of one field of the options struct.
const FieldSpec = struct {
    long: []const u8,
    short: ?u8,
    /// Position among positional arguments, or null for flags.
    positional_order: ?usize,
    is_bool: bool,
    required: bool,
    /// How the field is named in messages: `--page` or `<file>`.
    display: []const u8,
    /// Value placeholder shown in help, e.g. `<N>` or `<auto|kitty>`.
    value_hint: []const u8,
    help: []const u8,
    default: ?[]const u8,
};

const HelpRow = struct {
    left: []const u8,
    right: []const u8,
};

const HelpLayout = struct {
    usage_suffix: []const u8,
    arguments: []const HelpRow,
    options: []const HelpRow,
    /// Width of the widest left column, shared by both sections so their
    /// descriptions line up.
    width: usize,
};

// ====================================================================================================
// Public API
// ====================================================================================================

pub fn Cli(comptime Options: type, comptime info: Info) type {
    return struct {
        /// Parses the process arguments. Prints help, version or an error and
        /// exits when the arguments call for it.
        pub fn parse(init: std.process.Init) !Options {
            const args = try init.minimal.args.toSlice(init.arena.allocator());
            var diag: Diagnostic = .{};
            const stop = if (parseArgs(args[1..], &diag)) |options| return options else |stop| stop;

            const requested = stop == error.HelpRequested or stop == error.VersionRequested;
            const file: std.Io.File = if (requested) .stdout() else .stderr();
            const env = init.environ_map;
            const no_color = if (env.get("NO_COLOR")) |v| v.len > 0 else false;
            const force_color = if (env.get("CLICOLOR_FORCE")) |v| v.len > 0 else false;
            var buffer: [4096]u8 = undefined;
            var file_writer: std.Io.File.Writer = .init(file, init.io, &buffer);
            const t: Terminal = .{
                .writer = &file_writer.interface,
                .mode = try .detect(init.io, file, no_color, force_color),
            };

            switch (stop) {
                error.HelpRequested => try writeHelp(t),
                error.VersionRequested => try t.writer.print("{s} {s}\n", .{ info.name, info.version }),
                else => |err| {
                    try diag.write(err, t);
                    try t.writer.print("Try '{s} --help' for more information.\n", .{info.name});
                },
            }
            try t.writer.flush();
            std.process.exit(if (requested) 0 else 2);
        }

        /// Pure core of `parse`: no I/O, no exiting. `args` excludes the
        /// program name; returned strings borrow from it.
        pub fn parseArgs(args: []const [:0]const u8, diag: *Diagnostic) Stop!Options {
            const specs = comptime fieldSpecs(Options);
            const fields = @typeInfo(Options).@"struct";

            var options: Options = undefined;
            inline for (fields.field_names, fields.field_types, fields.field_attrs) |name, T, attrs| {
                if (attrs.defaultValue(T)) |value| @field(options, name) = value;
            }
            var seen: [specs.len]bool = @splat(false);
            var positionals_taken: usize = 0;
            var options_ended = false;

            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const arg = args[i];

                if (options_ended or arg.len < 2 or arg[0] != '-') {
                    const index = for (specs, 0..) |spec, j| {
                        if (spec.positional_order == positionals_taken) break j;
                    } else {
                        diag.* = .{ .subject = arg };
                        return error.UnexpectedArgument;
                    };
                    positionals_taken += 1;
                    try setField(Options, &options, index, arg, diag);
                    seen[index] = true;
                    continue;
                }

                // `--name`, `--name=value`, `-c` or `-cvalue`.
                var flag: []const u8 = undefined;
                var attached: ?[]const u8 = null;
                if (arg[1] == '-') {
                    if (arg.len == 2) {
                        options_ended = true;
                        continue;
                    }
                    const eq = std.mem.indexOfScalar(u8, arg, '=');
                    flag = arg[0 .. eq orelse arg.len];
                    if (eq) |e| attached = arg[e + 1 ..];
                    if (std.mem.eql(u8, flag, "--help")) return error.HelpRequested;
                    if (std.mem.eql(u8, flag, "--version")) return error.VersionRequested;
                } else {
                    flag = arg[0..2];
                    if (arg.len > 2) attached = arg[2..];
                    if (arg[1] == 'h' and attached == null) return error.HelpRequested;
                }

                const index = for (specs, 0..) |spec, j| {
                    if (spec.positional_order != null) continue;
                    if (std.mem.eql(u8, flag, spec.long)) break j;
                    if (flag.len == 2 and spec.short == flag[1]) break j;
                } else {
                    diag.* = .{ .subject = flag };
                    return error.UnknownOption;
                };
                const spec = specs[index];

                if (spec.is_bool) {
                    if (attached != null) {
                        // `-wfoo` is more likely a typo than a value for a boolean.
                        diag.* = .{ .subject = if (arg[1] == '-') flag else arg };
                        return if (arg[1] == '-') error.UnexpectedValue else error.UnknownOption;
                    }
                    try setField(Options, &options, index, "", diag);
                } else {
                    const value = attached orelse blk: {
                        i += 1;
                        if (i == args.len) {
                            diag.* = .{ .subject = flag };
                            return error.MissingValue;
                        }
                        break :blk args[i];
                    };
                    try setField(Options, &options, index, value, diag);
                }
                seen[index] = true;
            }

            for (specs, seen) |spec, was_seen| {
                if (spec.required and !was_seen) {
                    diag.* = .{ .subject = spec.display };
                    return error.MissingArgument;
                }
            }
            return options;
        }

        pub fn writeHelp(t: Terminal) Terminal.SetColorError!void {
            const layout = comptime helpLayout(Options);
            const w = t.writer;

            try w.print("{s}\n\n", .{info.summary});

            try writeHeader(t, "Usage:");
            try w.print("  {s} [options]{s}\n", .{ info.name, layout.usage_suffix });

            if (layout.arguments.len > 0) {
                try w.writeAll("\n");
                try writeHeader(t, "Arguments:");
                try writeRows(t, layout.arguments, layout.width);
            }

            try w.writeAll("\n");
            try writeHeader(t, "Options:");
            try writeRows(t, layout.options, layout.width);

            if (info.examples.len > 0) {
                try w.writeAll("\n");
                try writeHeader(t, "Examples:");
                for (info.examples) |example| try w.print("  {s}\n", .{example});
            }
        }
    };
}

// ====================================================================================================
// Private Functions
// ====================================================================================================

fn fieldSpecs(comptime Options: type) [@typeInfo(Options).@"struct".field_names.len]FieldSpec {
    comptime {
        // Formatting defaults at comptime is costly; scale the budget with
        // the number of options.
        @setEvalBranchQuota(20_000 * (@typeInfo(Options).@"struct".field_names.len + 1));
        const info = @typeInfo(Options).@"struct";
        const positional = if (@hasDecl(Options, "positional")) Options.positional else .{};
        const shorts = if (@hasDecl(Options, "shorts")) Options.shorts else .{};
        const helps = if (@hasDecl(Options, "help")) Options.help else .{};
        const positional_names = std.meta.fieldNames(@TypeOf(positional));

        for (std.meta.fieldNames(@TypeOf(positional))) |key| checkKey(Options, "positional", key);
        for (std.meta.fieldNames(@TypeOf(shorts))) |key| checkKey(Options, "shorts", key);
        for (std.meta.fieldNames(@TypeOf(helps))) |key| {
            checkKey(Options, "help", key);
            if (@hasField(@TypeOf(positional), key))
                @compileError("argparse: '" ++ key ++ "' is positional; describe it in `positional`, not `help`");
        }

        var specs: [info.field_names.len]FieldSpec = undefined;
        for (info.field_names, info.field_types, info.field_attrs, &specs) |name, T, attrs, *spec| {
            if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "version"))
                @compileError("argparse: option name '" ++ name ++ "' is reserved");

            const default = attrs.defaultValue(T);
            const order: ?usize = for (positional_names, 0..) |p, i| {
                if (std.mem.eql(u8, p, name)) break i;
            } else null;
            var long: [name.len]u8 = name[0..name.len].*;
            std.mem.replaceScalar(u8, &long, '_', '-');
            const long_final = long;
            if (T == bool and default == null)
                @compileError("argparse: bool option '" ++ name ++ "' needs a default");
            // A bool that defaults to true can only be switched off.
            const prefix = if (T == bool and default.? == true) "--no-" else "--";

            spec.* = .{
                .long = prefix ++ &long_final,
                .short = if (@hasField(@TypeOf(shorts), name)) @field(shorts, name) else null,
                .positional_order = order,
                .is_bool = T == bool,
                .required = default == null,
                .display = if (order != null) "<" ++ name ++ ">" else prefix ++ &long_final,
                .value_hint = valueHint(T),
                .help = if (order != null)
                    @field(positional, name)
                else if (@hasField(@TypeOf(helps), name))
                    @field(helps, name)
                else
                    @compileError("argparse: option '" ++ name ++ "' has no entry in `help`"),
                .default = if (default) |value| defaultText(T, value) else null,
            };
            if (spec.is_bool and spec.positional_order != null)
                @compileError("argparse: positional '" ++ name ++ "' cannot be bool");
        }

        for (specs, 0..) |a, i| {
            const short = a.short orelse continue;
            if (short == 'h') @compileError("argparse: short '-h' is reserved for help");
            for (specs[i + 1 ..]) |b| {
                if (b.short == short) @compileError("argparse: duplicate short '-" ++ [_]u8{short} ++ "'");
            }
        }
        return specs;
    }
}

fn checkKey(comptime Options: type, comptime decl: []const u8, comptime key: []const u8) void {
    if (!@hasField(Options, key))
        @compileError("argparse: `" ++ decl ++ "` names unknown field '" ++ key ++ "'");
}

fn valueHint(comptime T: type) []const u8 {
    comptime {
        if (T == bool) return "";
        if (T == []const u8) return "<STR>";
        return switch (@typeInfo(T)) {
            .optional => |o| valueHint(o.child),
            .int => "<N>",
            .float => "<X>",
            .@"enum" => |e| blk: {
                var hint: []const u8 = "<";
                for (e.field_names, 0..) |tag, i| hint = hint ++ (if (i > 0) "|" else "") ++ tag;
                break :blk hint ++ ">";
            },
            else => @compileError("argparse: unsupported option type " ++ @typeName(T)),
        };
    }
}

/// Describes what `parseValue` accepts, for error messages.
fn expectedText(comptime T: type) []const u8 {
    comptime {
        if (T == []const u8) return "a string";
        return switch (@typeInfo(T)) {
            .optional => |o| expectedText(o.child),
            .int => "an integer",
            .float => "a number",
            .@"enum" => |e| blk: {
                var text: []const u8 = "one of: ";
                for (e.field_names, 0..) |tag, i| text = text ++ (if (i > 0) ", " else "") ++ tag;
                break :blk text;
            },
            else => unreachable,
        };
    }
}

/// Default value as shown in help, or null when it is not worth showing
/// (false, null, empty string).
fn defaultText(comptime T: type, comptime value: T) ?[]const u8 {
    comptime {
        if (T == bool) return null;
        if (T == []const u8) return if (value.len == 0) null else "\"" ++ value ++ "\"";
        return switch (@typeInfo(T)) {
            .optional => |o| if (value) |v| defaultText(o.child, v) else null,
            .int, .float => std.fmt.comptimePrint("{d}", .{value}),
            .@"enum" => @tagName(value),
            else => unreachable,
        };
    }
}

fn setField(
    comptime Options: type,
    options: *Options,
    index: usize,
    text: []const u8,
    diag: *Diagnostic,
) error{InvalidValue}!void {
    const info = @typeInfo(Options).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, T, attrs, i| {
        if (i == index) {
            if (T == bool) {
                // Giving the flag flips the default: `--watch` or `--no-watch`.
                @field(options, name) = !attrs.defaultValue(bool).?;
            } else {
                @field(options, name) = parseValue(T, text) catch {
                    diag.* = .{
                        .subject = comptime fieldSpecs(Options)[i].display,
                        .value = text,
                        .expected = comptime expectedText(T),
                    };
                    return error.InvalidValue;
                };
            }
            return;
        }
    }
    unreachable;
}

fn parseValue(comptime T: type, text: []const u8) error{InvalidValue}!T {
    if (T == []const u8) return text;
    return switch (@typeInfo(T)) {
        .optional => |o| try parseValue(o.child, text),
        .int => std.fmt.parseInt(T, text, 10) catch error.InvalidValue,
        .float => std.fmt.parseFloat(T, text) catch error.InvalidValue,
        .@"enum" => std.meta.stringToEnum(T, text) orelse error.InvalidValue,
        else => comptime unreachable,
    };
}

fn helpLayout(comptime Options: type) HelpLayout {
    comptime {
        const specs = fieldSpecs(Options);
        var usage_suffix: []const u8 = "";
        var arguments: []const HelpRow = &.{};
        var options: []const HelpRow = &.{};

        for (0..specs.len) |order| {
            for (specs) |spec| {
                if (spec.positional_order != order) continue;
                usage_suffix = usage_suffix ++ " " ++ if (spec.required) spec.display else "[" ++ spec.display ++ "]";
                arguments = arguments ++ &[_]HelpRow{.{ .left = spec.display, .right = describe(spec) }};
            }
        }
        for (specs) |spec| {
            if (spec.positional_order != null) continue;
            const short = if (spec.short) |c| "-" ++ [_]u8{c} ++ ", " else "    ";
            const hint = if (spec.is_bool) "" else " " ++ spec.value_hint;
            options = options ++ &[_]HelpRow{.{ .left = short ++ spec.long ++ hint, .right = describe(spec) }};
        }
        options = options ++ &[_]HelpRow{
            .{ .left = "-h, --help", .right = "Show this help" },
            .{ .left = "    --version", .right = "Show version" },
        };

        var width: usize = 0;
        for (arguments ++ options) |row| width = @max(width, row.left.len);
        return .{ .usage_suffix = usage_suffix, .arguments = arguments, .options = options, .width = width };
    }
}

fn describe(comptime spec: FieldSpec) []const u8 {
    return if (spec.default) |d| spec.help ++ " (default: " ++ d ++ ")" else spec.help;
}

fn writeHeader(t: Terminal, text: []const u8) Terminal.SetColorError!void {
    try t.setColor(.bold);
    try t.writer.writeAll(text);
    try t.setColor(.reset);
    try t.writer.writeAll("\n");
}

fn writeRows(t: Terminal, rows: []const HelpRow, width: usize) Terminal.SetColorError!void {
    for (rows) |row| {
        try t.writer.writeAll("  ");
        try t.setColor(.cyan);
        try t.writer.writeAll(row.left);
        try t.setColor(.reset);
        try t.writer.splatByteAll(' ', width - row.left.len + 2);
        try t.writer.print("{s}\n", .{row.right});
    }
}

// ====================================================================================================
// Tests
// ====================================================================================================

const TestCli = Cli(struct {
    file: []const u8,
    page: u32 = 1,
    mode: enum { light, dark } = .light,
    watch: bool = false,
    zoom_level: ?f32 = null,
    color: bool = true,

    pub const positional = .{ .file = "File to open" };
    pub const shorts = .{ .page = 'p', .watch = 'w' };
    pub const help = .{
        .page = "Start page",
        .mode = "Colour mode",
        .watch = "Reload on change",
        .zoom_level = "Initial zoom",
        .color = "Disable colour",
    };
}, .{
    .name = "tool",
    .summary = "Does things",
    .version = "1.0.0",
    .examples = &.{"tool a.pdf"},
});

fn expectStop(expected: Stop, subject: []const u8, args: []const [:0]const u8) !void {
    var diag: Diagnostic = .{};
    try std.testing.expectError(expected, TestCli.parseArgs(args, &diag));
    try std.testing.expectEqualStrings(subject, diag.subject);
}

test "defaults apply and every value syntax is accepted" {
    var diag: Diagnostic = .{};
    const defaults = try TestCli.parseArgs(&.{"a.pdf"}, &diag);
    try std.testing.expectEqualStrings("a.pdf", defaults.file);
    try std.testing.expectEqual(1, defaults.page);
    try std.testing.expectEqual(null, defaults.zoom_level);

    for ([_][]const [:0]const u8{
        &.{ "-p", "7", "a.pdf" },
        &.{ "-p7", "a.pdf" },
        &.{ "--page", "7", "a.pdf" },
        &.{ "a.pdf", "--page=7" },
    }) |args| {
        try std.testing.expectEqual(7, (try TestCli.parseArgs(args, &diag)).page);
    }

    try std.testing.expect(defaults.color);
    const all = try TestCli.parseArgs(&.{ "-w", "--mode", "dark", "--zoom-level=1.5", "--no-color", "a.pdf" }, &diag);
    try std.testing.expect(all.watch);
    try std.testing.expect(!all.color);
    try std.testing.expectEqual(.dark, all.mode);
    try std.testing.expectEqual(1.5, all.zoom_level.?);
}

test "double dash ends options" {
    var diag: Diagnostic = .{};
    const options = try TestCli.parseArgs(&.{ "--", "-p.pdf" }, &diag);
    try std.testing.expectEqualStrings("-p.pdf", options.file);
    try std.testing.expectEqual(1, options.page);
}

test "help and version skip required-argument validation" {
    try expectStop(error.HelpRequested, "", &.{"-h"});
    try expectStop(error.VersionRequested, "", &.{"--version"});
}

test "errors name the offending argument" {
    try expectStop(error.UnknownOption, "--pgae", &.{ "--pgae", "3", "a.pdf" });
    try expectStop(error.UnknownOption, "-wx", &.{ "-wx", "a.pdf" });
    try expectStop(error.MissingValue, "--page", &.{ "a.pdf", "--page" });
    try expectStop(error.UnexpectedValue, "--watch", &.{ "--watch=yes", "a.pdf" });
    try expectStop(error.UnknownOption, "--color", &.{ "--color", "a.pdf" });
    try expectStop(error.InvalidValue, "--page", &.{ "--page", "x", "a.pdf" });
    try expectStop(error.InvalidValue, "--mode", &.{ "--mode", "sepia", "a.pdf" });
    try expectStop(error.MissingArgument, "<file>", &.{ "-p", "2" });
    try expectStop(error.UnexpectedArgument, "b.pdf", &.{ "a.pdf", "b.pdf" });
}

test "help page aligns all rows and shows defaults" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try TestCli.writeHelp(.{ .writer = &writer, .mode = .no_color });

    try std.testing.expectEqualStrings(
        \\Does things
        \\
        \\Usage:
        \\  tool [options] <file>
        \\
        \\Arguments:
        \\  <file>                   File to open
        \\
        \\Options:
        \\  -p, --page <N>           Start page (default: 1)
        \\      --mode <light|dark>  Colour mode (default: light)
        \\  -w, --watch              Reload on change
        \\      --zoom-level <X>     Initial zoom
        \\      --no-color           Disable colour
        \\  -h, --help               Show this help
        \\      --version            Show version
        \\
        \\Examples:
        \\  tool a.pdf
        \\
    , writer.buffered());
}
