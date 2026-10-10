# Clawd Heartbeat — project context for Claude

A physical Claude Code status indicator: M5Atom Lite firmware (PlatformIO/C++) + a hook script. The LED shows session state through a 3D-printed figure's heart window.

## Helping the user

- First-time device setup → use the `setup` skill (interactive: WiFi, flash, hooks)
- Color/brightness tuning for their filament/case → use the `led-tuning` skill
- "Why is it red/white/off?" questions → read `docs/LIFECYCLE.md` first; most "bugs" are documented behaviors (approval/interrupt are invisible to hooks)

## Project map

- `src/main.cpp` — firmware: per-session state, priority aggregation (`wait > err > done > tool > idle`), all colors/timings
- `led.sh` — hook script (copy lives at `~/.claude/led.sh`): session_id extraction, AskUserQuestion→wait, dialog-wait marker (subagent overwrite protection), send timestamp, transcript watcher that catches denials/interrupts (which fire no hook event)
- `led-test.sh` — manual testing (`status` / `states` / `rgb` / `ramp` / `coupon`); device URL from `ATOM` env or gitignored `.atom-ip`
- `led-demo.sh` — non-interactive animation playback for filming/verification (`states` / `story` / `wait-full`, `--solo` to stop other sessions overriding it)
- `docs/NOTES.md` — design decisions + empirically measured hook behavior (Japanese)
- `docs/LIFECYCLE.md` — event→LED mapping and hook blind spots (Japanese)

## Hard constraints (do not change casually)

- `platform = espressif32@6.9.0` is pinned — newer platforms break with Arduino core 3.x. If resolution fails, tell the user; do not bump
- `fastled/FastLED@3.7.8` is pinned — `^3.6.0` resolved to FastLED 3.10.6, which builds fine on this platform but the LED stops updating while the web server keeps answering, so `led-test.sh status` looks healthy. If you change it, confirm by eye that `led-test.sh rgb` changes the color
- No `delay()` in `loop()` — animations are `millis()`-based; delay stalls the web server
- WiFi credentials live only in `include/secrets.h` (gitignored). Never commit real credentials, device IPs, or MAC addresses — personal values go in gitignored `docs/LOCAL.md` / `.atom-ip`
- If both `led.sh` here and `~/.claude/led.sh` exist, keep them in sync when editing

## Flashing & verification

```bash
pio run -t upload                 # auto-detects port; hold the Atom's button while plugging USB if download mode fails
./led-test.sh status              # aggregated + per-session state from the device
./led-test.sh states              # replay all 5 states visually
```

`pio device monitor` needs a TTY (fails in background shells) — read serial with pyserial setting `dtr=False`/`rts=False` before open (recipe in docs/NOTES.md).
