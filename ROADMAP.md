
## v0.1.0 - Initial

- [x] Basic homebrew support
- [x] Basic navigation (`j/k, Ctrl-d/u, h/l, gg/G, {n}G, q`)
- [x] Zoom (`+/-/=`)
- [x] Kitty image rendering only
- [x] Prerender neighbouring pages in the background
- [x] Status line
- [x] CI/CD
- [x] Dark mode
- [x] Command-line (`:`)
- [x] Automatic (and option for disabling) refreshing

## v0.2.0 - Polishing

- [x] Search (`/`, `n/N`)
- [x] Non-interactive mode
- [x] Searchable TOC (`t`)
- [x] Jumps (`Ctrl+o/i`)

## v0.3.0 - Extended support

- [x] Replace PDFium and stb_image with MuPDF; license under AGPL-3.0-or-later
- [x] Support raster image formats
- [x] More document formats (EPUB, XPS, CBZ/CBT, FB2, MOBI)
- [x] SVG (MuPDF's supported subset)
- [x] Multipage images

## v0.4.0

- [x] Follow visible links with keyboard hints (`f`) and preview web addresses before opening them
- [x] Reimplement text search on MuPDF (`/`, `n` / `N`), with highlights and repeats from the selected match
- [x] Restore jump history (`Ctrl-o` / `Ctrl-i`) and fix `Ctrl-i` in terminals that send CSI-u
- [x] Add shell completions for Bash, Zsh, and Fish

## vX.Y.Z

- [ ] Text selection/copying??
- [ ] Remember last position? (local state)
- [ ] Tmux support

