# ptz

Terminal PDF viewer written in Zig 0.17.

## Code style

### Imports

Any file in the same directory may be imported. Other directories are entered
only through their `main.zig`, and at most one level deep:

```zig
@import("test.zig")           // ok: same directory
@import("bar/main.zig")       // ok
@import("../../foo/main.zig") // ok: any depth up, then one level down
@import("foo/bar/main.zig")   // no: two levels down
@import("../foo/bar.zig")     // no: not main.zig
```

Imports open the file without a banner, grouped in this order under plain
labels, omitting empty groups:

```zig
// std
const std = @import("std");

// packages
const build_options = @import("build_options"); // named modules from build.zig

// project
const render = @import("../render/main.zig"); // other directories

// local
const argparse = @import("argparse.zig"); // same directory

// aliases
const Terminal = std.Io.Terminal;
```

### Naming

Names are read qualified, so don't repeat the enclosing namespace or type:
`cli.parse`, `cli.Options`, not `Parser.parse`, `cli.CliOptions`,
`argparse.ArgParser`.

### File layout

After the imports, split files into banner sections, in this order, omitting
empty ones:

1. Constants
2. Types
3. Fields (only in files that are themselves a type, i.e. `TitleCase.zig`)
4. Public API
5. Private Functions
6. Tests

```zig
// ====================================================================================================
// Types
// ====================================================================================================
```

## Testing

- `zig build test` runs all tests. Fixtures are opened relative to the
  project root.
- Code that talks to the terminal takes its input and output as streams
  (`*std.Io.Reader`, `*std.Io.Writer`), never stdin/stdout directly, so tests
  can run it against `src/emulator/main.zig`, an emulated terminal built on
  Ghostty's `ghostty-vt`. Only tests and the harness may import it.
- To see what ptz draws, run `zig build harness -- <file.pdf> [--page N]`.
  It prints the emulated screen's text and writes a screenshot of its images
  to `zig-out/screen.png`.
- For behaviour that needs a real terminal (raw mode, resizing, detection in
  an actual emulator), run ptz in a background Rex tab and read it with
  `rex capture`; Rex captures text only.
