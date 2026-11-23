# About

Vibe-coded CLI tool to render documents and images in the terminal using the
Kitty graphics protocol.

**Install:**
```bash
brew install rasmus105/tap/ptz
brew upgrade ptz
```

**Usage:**
```bash
ptz [options] [<path>]

ptz
ptz scans/

ptz my-document.pdf
ptz book.epub
ptz photo.jpg
```

## Features

- PDF, EPUB (DRM-free), XPS, CBZ/CBT, FB2, MOBI and SVG (MuPDF's supported subset)
- PNG, JPEG, TIFF, JPEG 2000, BMP, PSD, GIF (static) and PNM/PAM; multipage
  images expose each page
- Vim-like motions (`j/k` + `Ctrl+u/d` for scrolling, `h/l` for next/prev page,
  `:` for command line,...)
- Continuous scrolling, zoom and panning
- Dark mode (`i`, or start with `--dark`)
- Reloads when the file changes, e.g. while compiling LaTeX (`--no-watch` to disable)
- Renders in the background and, in a local terminal, sends pages through shared
  memory, so scrolling and zooming stay fast

With a directory or no path, ptz opens the first usable file in natural filename
order. File navigation browses the same directory without wrapping or entering
subdirectories.

## Shortcuts

| Keys | Action |
|---|---|
| `j` / `k`, `Down` / `Up` | Scroll down / up |
| `Ctrl-d` / `Ctrl-u` | Scroll half a screen |
| `Ctrl-f` / `Ctrl-b`, `Space`, `PageDown` / `PageUp` | Scroll a screen |
| `l` / `h` | Next / previous page |
| `L` / `H` | Next / previous file |
| `gg` / `G`, `{n}G` | First / last page, page `n` |
| `+` / `-` / `=` | Zoom in / out / fit width |
| `Left` / `Right` | Pan when zoomed in |
| `f` | Show hints for visible links. Type a hint to follow it, `Backspace` to edit, `Tab` for more, or `Esc` to cancel |
| `/`, `n` / `N` | Search text, next / previous match. `Esc` or `:noh` hides highlights |
| `Ctrl-o` / `Ctrl-i` (`Tab`) | Go back / forward through link and search jumps |
| `i` | Toggle dark mode |
| `:` | Command line: `:{n}`, `:zoom {percent}`, `:dark`, `:reload`, `:q` |
| `q`, `Ctrl-c` | Quit |

Counts work as in Vim, e.g. `5j` or `3l`.
Check the address of an HTTP(S) link and press `Enter` to open it in your browser.
International addresses use percent-encoded paths and Punycode hostnames.

## Dependencies

- [MuPDF](https://mupdf.com/): document and image rendering, built from pinned
  source on the first `zig build` (requires GNU Make, patch and C/C++ compilers)
- [Ghostty VT](https://github.com/ghostty-org/ghostty) (only for testing
  purposes)

EPUB, FB2 and MOBI use a fixed page layout; resizing and zooming scale those
pages without changing pagination. Images honor their resolution and orientation.

Licensed under AGPL-3.0-or-later; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
