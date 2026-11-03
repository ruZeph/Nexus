# Cyberpunk DLC Copy

Part of the **[Nexus](../../README.md)** toolkit — `python/cyberpunk-dlc-copy/`.

Pulls the Phantom Liberty / `ep1` DLC archives out of a Cyberpunk 2077 install into a tidy
`DLC Files` folder, driven by a fixed manifest of file names and `robocopy` per file. Made for
moving DLC content between installs (GOG ↔ Steam ↔ Epic) without dragging 80 GB along.

## Usage

```bat
python cyberpunk_dlc_copy.py
```

Two folder pickers:

1. **Source** — the Cyberpunk 2077 root folder (the one containing `archive\pc\ep1`).
2. **Destination** — canceled = `<source>\DLC Files`; otherwise a `DLC Files` subfolder is
   created inside your pick.

`robocopy` copies each manifest entry from `archive\pc\ep1` and reports per-file success.

## Notes

- The manifest is hardcoded (`archive\pc\ep1\...`, including every `lang_*_text.archive`) —
  update it if CDPR adds or renames DLC archives.
- Requires `robocopy` (ships with Windows) and a Tk-enabled Python for the pickers.
- Nothing is deleted; the source install is only read.
- Close the game and any mod manager before copying.
