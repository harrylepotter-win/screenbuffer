# ScreenBuffer

An always-on macOS menu-bar app that continuously records the **last 10 minutes** of
your main display into a rolling buffer. When you hit a bug, click the menu-bar icon →
**Save last 10 minutes**, and it stitches the buffer into a single timestamped clip in
`~/dev/screenbuffer/recordings/`. Recording never stops while you save.

Video only (no audio, no microphone permission), main display only, HEVC encoded.

## How it works

- ScreenCaptureKit captures the main display at 30 fps.
- Frames are written to short 15-second `.mov` segments in `recordings/.buffer/`.
- Only the most recent ~10 minutes of segments are kept; older ones are deleted.
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

- **Save last 10 minutes** — dump the buffer to a clip and reveal it in Finder.
- **Pause / Resume recording**.
- **Open recordings folder**.
- **Quit**.

## Tuning

Edit `Sources/ScreenBuffer/Config.swift`: buffer length, segment size, fps, bitrate,
output paths. Rebuild with `make bundle`.

## Notes

- Dumped clips accumulate in `recordings/` — prune them yourself.
- Ad-hoc code signing means a rebuild may re-prompt for Screen Recording. Fine for
  personal use.
- Logs (when installed): `/tmp/screenbuffer.out.log`, `/tmp/screenbuffer.err.log`.
