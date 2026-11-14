# ptz

Terminal PDF viewer written in Zig 0.17.

## Architecture

- `viewer/`: the viewer's logic, pure and deterministic: keys and events in,
  frames (which tile slices go where, which tiles to render) out.
- `app/`: the I/O shell: event loop, render thread (`Renderer`), the tiles
  uploaded to the terminal (`Cache`).
- `pdf/`, `graphics/`, `terminal/`: engine-neutral wrappers around PDFium, the
  kitty graphics protocol and the terminal.

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
- To see what ptz draws, run
  `zig build harness -Doptimize=ReleaseFast -- <file.pdf> --keys '3G<C-d>+'`.
  It runs the viewer in the emulated terminal, presses the keys, prints the
  screen's text and writes a screenshot of its images to `zig-out/screen.png`.
  Add `--fuzz 300 --seed N` to press random keys and resizes instead,
  checking the screen against a fresh viewer's; failures are reproducible
  from the seed.
- For behaviour that needs a real terminal (raw mode, resizing, detection in
  an actual emulator), run ptz in a background Rex tab and read it with
  `rex capture`; Rex captures text only.
