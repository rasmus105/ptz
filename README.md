# About

Vibe-coded CLI tool to render PDFs and raster images in the terminal using the
Kitty graphics protocol.

**Install:**
```bash
brew install rasmus105/tap/ptz
brew upgrade ptz
```

**Usage:**
```bash
ptz [options] <file>

ptz my-document.pdf
ptz photo.jpg
```

## Features

- PDF, PNG, JPEG, GIF (first frame), BMP, TGA, PSD, HDR and binary PGM/PPM
- Vim-like motions (`j/k` + `Ctrl+u/d` for scrolling, `h/l` for next/prev page,
  `:` for command line,...)
- Continuous scrolling, zoom and panning
- Dark mode (`i`, or start with `--dark`)
- Reloads when the file changes, e.g. while compiling LaTeX (`--no-watch` to disable)
- Renders in the background and, in a local terminal, sends pages through shared
  memory, so scrolling and zooming stay fast

## Shortcuts

| Keys | Action |
|---|---|
| `j` / `k`, `Down` / `Up` | Scroll down / up |
| `Ctrl-d` / `Ctrl-u` | Scroll half a screen |
| `Ctrl-f` / `Ctrl-b`, `Space`, `PageDown` / `PageUp` | Scroll a screen |
| `l` / `h` | Next / previous page |
| `gg` / `G`, `{n}G` | First / last page, page `n` |
| `+` / `-` / `=` | Zoom in / out / fit width |
| `Left` / `Right` | Pan when zoomed in |
| `i` | Toggle dark mode |
| `:` | Command line: `:{n}`, `:zoom {percent}`, `:dark`, `:reload`, `:q` |
| `q`, `Ctrl-c` | Quit |

Counts work as in Vim, e.g. `5j` or `3l`.

## Dependencies

- [stb_image](https://github.com/nothings/stb/blob/master/stb_image.h): raster image decoding
- [PDFium](https://pdfium.googlesource.com/pdfium/)
- [Ghostty VT](https://github.com/ghostty-org/ghostty) (only for testing
  purposes)
