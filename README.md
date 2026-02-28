# MyGhost

A customized terminal emulator based on [Ghostty](https://github.com/ghostty-org/ghostty), with sidebar tab management and an integrated file browser.

## Features

- **Sidebar Tab Management** - Visual tab list with drag-to-reorder, join/unjoin tabs, and keyboard shortcuts
- **File Browser** - Built-in file browser with breadcrumb navigation
  - Quick Look preview (Space)
  - Rename files (Enter)
  - Move to Trash (Cmd+Delete)
  - Drag files to terminal to insert path
  - Right-click context menu (Open, Quick Look, Rename, Show in Finder)
- **Custom App Icon**
- All original Ghostty features (splits, themes, GPU rendering, etc.)

## Building

Requires [Zig](https://ziglang.org/) and Xcode.

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Run
open zig-out/my_ghost.app
```

## Credits

Based on [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto.
