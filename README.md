# ScreenBuffer

An always-on macOS menu-bar app that continuously records the **last few minutes** of
your main display into a rolling buffer (10 minutes by default, adjustable from 1 minute
to 3 hours). When you hit a bug, click the menu-bar icon → **Save last 10 min**, and it
stitches the buffer into a single timestamped clip in `~/dev/screenbuffer/recordings/`.
Recording never stops while you save.

Video only (no audio, no microphone permission), main display only, HEVC encoded.

## How it works

- ScreenCaptureKit captures the main display at 30 fps.
- Frames are written to short 15-second `.mov` segments in `recordings/.buffer/`.
- Only the segments inside the buffer window are kept; older ones are deleted.
- **Save** finalizes the current segment and passthrough-stitches the window into one
  `.mov` (no re-encode — fast), leaving the buffer intact.

## Build & run (foreground, for testing)

```sh
cd ~/dev/screenbuffer
make run
```

First launch: macOS will prompt for **Screen Recording**. Grant it under
**System Settings → Privacy & Security → Screen Recording** (the menu shows a
shortcut), then use the menu's **Try again** / relaunch. The `⚠︎` icon means the
permission isn't granted yet.

## Install as an always-on login agent

```sh
make install
```

This copies `ScreenBuffer.app` to `/Applications`, installs a LaunchAgent
(`~/Library/LaunchAgents/com.bdavey.screenbuffer.plist`) with `RunAtLoad` +
`KeepAlive`, and loads it — so it starts at login and relaunches if it exits.
Grant Screen Recording to the copy in `/Applications` if prompted.

Remove everything:

```sh
make uninstall
```

## Menu

- **Save last 10 min** — dump the buffer to a clip and reveal it in Finder.
- **Pause / Resume recording**.
- **Buffer length** — slider from 1 min to 3 hr, snapping to 1/2/3/5/10/15/20/30/45 min
  and 1/1.5/2/3 hr. The label shows the rough disk cost (~1 MB/s, so 3 hr ≈ 10.8 GB).
  Shortening it trims the buffer immediately; lengthening it fills up over time. The
  choice is saved and restored on next launch.
- **Capture at 2× (Retina)** — capture at twice the display's point size. On a genuinely
  Retina display this is already the native scale, so the toggle is a no-op; on a 1×
  panel it supersamples, which costs ~4× the bits without adding detail (the window
  server only composites a 1× screen at 1×). Toggling restarts capture and clears the
  buffer, since the frame size changes.
- **Open recordings folder**.
- **Quit**.

## Tuning

Buffer length and capture scale are set from the menu. For the rest — segment size, fps,
encoder quality, output paths — edit `Sources/ScreenBuffer/Config.swift` and rebuild with
`make bundle`.

The encoder ceiling is derived from the frame size (`bitsPerPixelPerFrame`, ~8 Mbps at
3440×1440@30) rather than fixed, so quality-per-pixel holds steady when 2× capture
quadruples the pixel count. It's a ceiling, not a floor — a mostly-static screen encodes
at a fraction of it (measured ~2.3 Mbps at 3440×1440).

## Notes

- Dumped clips accumulate in `recordings/` — prune them yourself.
- Ad-hoc code signing means a rebuild may re-prompt for Screen Recording. Fine for
  personal use.
- Logs (when installed): `/tmp/screenbuffer.out.log`, `/tmp/screenbuffer.err.log`.
