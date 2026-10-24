# LightPilot (working name)

An iPhone/iPad app plus a **MIDI AUv3 (type `aumi`)** for Loopy Pro that drives two iStrip Pro (ISP-…) WS2812B tubes over Bluetooth.

The main control is Loopy's XY pad: **X browses the 25 captured patterns, Y sets speed, and a fader sets brightness.** Patterns are discrete steps. When you release the pad, the last pattern and speed stay where they are.

## Build

1. `brew install xcodegen` (if you don't have it yet)
2. Open `project.yml` and set `DEVELOPMENT_TEAM` to your team ID.
3. `cd LightPilot && xcodegen generate && open LightPilot.xcodeproj`
4. Run the **LightPilot** scheme on the iPad. Automatic signing creates the App Group `group.com.mrbradsmusic.LightPilot` for both the app and the extension.
5. Launch the app once and allow Bluetooth. Then rescan plugins in Loopy, or reboot the iPad if it doesn't show up. It's listed as **Mr. Brad's Music: LightPilot** under MIDI processors.
6. ⌘U runs the unit tests on a simulator: AES fixtures, packet builders, palette, hysteresis, CC scaling and latest-state coalescing.

| Target | Bundle ID | Notes |
|---|---|---|
| LightPilot (app) | com.mrbradsmusic.LightPilot | `bluetooth-central` background mode |
| LightPilotAU (appex) | com.mrbradsmusic.LightPilot.AU | `aumi` / subtype `LtPl` / manufacturer `MrBd` |
| LightPilotTests | — | hosted by the app |

## How it's wired

```
Loopy XY / fader ──► AU parameters (Pattern, Speed, Brightness…)  ┐
Loopy MIDI CCs ────► render block ─► lock-free ring (C, no alloc) ┘─► PerformanceCore (own queue)
                                                                           │ latest state only
                                       ┌───────────── Direct ──────────────┤
                                       ▼                                   ▼ Bridge (fallback)
                         BLELightEngine inside the plugin        App Group file + Darwin ping
                                                                  ──► LightPilot app ─► BLELightEngine
```

- **Render thread:** the render block only copies MIDI bytes and parameter events into atomics. It does no Bluetooth, AES, dispatching, locking or allocation.
- **Coalescing:** every *Send tick* (default 50 ms) each light gets only what changed compared with the last thing it received. Order is TURN, then the pattern command, then the palette (MULT only). There is no queue, so a fast gesture can't build up a backlog.
- **One Bluetooth owner:** all plugin instances in Loopy share a single engine per process. When the plugin starts in Direct mode it tells the app to let go of the lights.
- **Bluetooth path** (Settings): *Direct* is the default and is the one to prove first. *Via app bridge* keeps the same Loopy control, but the LightPilot app holds the connection. In that mode, keep the app visible next to Loopy (Stage Manager or Split View), because iOS can suspend it when it's fully in the background. This build does not play silent audio to stay alive.

## Parameters (for Loopy widget binding)

| Addr | Name | Range | Notes |
|---|---|---|---|
| 0 | Power | Off/On | |
| 1 | Pattern | 0–24 (continuous) | Quantized with hysteresis. Shows the pattern name |
| 2 | Speed | 0–100 | Use *Invert speed* if higher turns out to be slower |
| 3 | Brightness | 0–100 | Scales SGLS colors and the MULT palette |
| 4 / 5 | Color A / B Hue | 0–360° | SGLS modes |
| 6 | Saturation | 0–100 | |
| 7 | Palette | 8 presets + Custom | MULT modes |
| 8 | Favorite | — / 1–8 | Recalls a saved favorite |

No CCs are assigned by default. Use **Settings → MIDI → Learn**, or skip CCs and bind widgets directly to the parameters. Mappings and channel (Omni/1–16) are saved per instance in the Loopy project. Favorites are shared by the app and every instance.

**Loopy tip:** turn off "return to center" (spring) on the XY widget. Otherwise releasing the pad will jump the pattern back.

## What protocol it sends

Only what's in the captures. There are 10 SGLS + 15 MULT IDs, TURN, and the palette. No unknown IDs are sent and there's no direction control. One extra finding from decrypting all 27 fixtures: **byte 0 is the number of meaningful bytes that follow** (TURN 5, MULT 9, SGLS 14, palette 0x16). That would explain why SGLS byte 15 and MULT bytes 10–15 vary: they're filler. The default filler is random, like the vendor app. *Zero* is a setting you can test.

Palette writes use the 23 meaningful bytes plus a **zero tail** to 100 bytes. The source app's stale memory tail is never copied. A 23-byte option is in Settings.

## Real-device checklist

Do these in order on the iPad. Run steps 1–6 in the app, with *Lights → Connect from this app (testing)* on.

1. **Self-test:** Diagnostics → Step 4 shows 29/29 passed.
2. **Find and connect:** Lights → Scan → Add both ISP lights. Both show *Ready*, and the Diagnostics characteristics list includes …9600 (write), …9601 (notify) and …960A/…960B.
3. **Known-good:** Step 1 OFF/ON works on both lights, and the log shows an ack (←) for each.
4. **Palette UUID:** Replay a MULT pattern with **+ Palette**. If the colors don't come out right, choose *Use for palette* on …960B and try again. Note which one worked.
5. **SGLS replay:** Replay a few Mono modes. Then try *TURN OFF/ON (zero filler)* to check sanitized filler.
6. **Generated:** On the Perform tab, step through all 25 patterns. Check that every mode responds, that Speed and Brightness act independently, and whether Speed needs *Invert*.
7. **Loopy, Direct:** Turn off *Connect from this app*. Add LightPilot as a MIDI processor in Loopy. The status chips should go to *Ready*. **This is the key test:** if they stay at *Searching* or *Connecting*, Bluetooth from inside the extension is blocked or unreliable on your setup.
8. **XY:** Bind an XY pad (X → Pattern, Y → Speed) and a fader (→ Brightness). Sweep fast, stop, and release. The last pattern should keep animating, with no catch-up burst of stale commands afterward.
9. **Both lights:** Disable one light under Lights, then re-enable it. Confirm both follow and reconnect after a power-cycle.
10. **Restore:** Save the Loopy project, reload it, and check that pattern, speed, brightness and MIDI mappings come back.
11. **Audio:** Loopy audio stays clean with no dropouts while you sweep.
12. **Fallback only if step 7 fails:** In Settings, set Bluetooth path to *Via app bridge*. Keep the app open beside Loopy and repeat steps 8–11.

If commands get dropped with two lights connected, raise *Send tick* (Settings → Protocol) from 50 ms to 80–100 ms.

## Not done yet (on purpose)

- Direction/reverse, until its field is captured.
- Real pattern names, which stay neutral (Mono 01–10, Color 01–15) until you've seen them on the lights.
- Phase sync between the two tubes. They receive the same commands but may not animate in lockstep.
- MIDI 2.0 event lists. The AU uses classic MIDI 1.0 events, which Loopy sends to MIDI processors.
