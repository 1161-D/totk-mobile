# Controls and settings

**English** | [简体中文](controls.zh-CN.md)

## Mac keyboard

| Action | Key |
| --- | --- |
| Move / camera | W A S D / I J K L |
| A / B / X / Y | X / Z / R / F (X confirms, Z goes back) |
| D-pad | Arrow keys |
| L / R, ZL / ZR | Q / E, Shift / Space |
| Inventory (+) / map (−) | Return / Tab |
| Left / right stick click | C / V |
| Control panel / performance overlay | ⌘, / ⌘P |
| Full screen | ⌃⌘F |

## Xbox controller

Xbox controllers connect automatically over Bluetooth or USB while the game window is in front. Menu (≡) is +, View is −. When the stick is deflected it takes priority over held keyboard keys. Rumble uses a curve calibrated for Xbox controllers.

## Control panel

Open it with ⌘, or **View → Controls**. Settings are saved to `work/settings.json` (override the path with `ZELDA_SETTINGS`).

| Setting | Values | Notes |
| --- | --- | --- |
| Frame rate | 30 / 60 / 90 FPS | Default 60. A target is not a guarantee; pre-rendered movies still play at 30 |
| Resolution | Original / 1080 / 720 / 640 | **Original** keeps the game's own dynamic resolution. Fixed modes render the scene at 1920×1080, 1280×720 or 1136×640 |
| MetalFX | Off / On | Upscales only the final output |
| Fullscreen, Sound, Performance | Off / On | Performance shows the overlay |
| Rumble | Off / On | Off stops rumble immediately; turning it back on does not replay old pulses. **Test** only checks the host output |

Older settings files are migrated automatically: `896p`/`balanced` become Original, `performance` becomes 720, the removed `480p` becomes 640, and old rumble strengths read as On. Unknown fields are kept.

## Performance overlay

The overlay (⌘P) shows FPS and target, render size, CPU, GPU time and memory. Its top-right corner shows the shader warm-up state: `Checking shaders`, `Shaders N%`, `Pipelines N%`, `Warming up` while the total is not yet known, and `Compiling shaders` when a new library or pipeline is created during play. The percentage refers to the current stage only.

## iPad

Without a hardware controller, the system touch controller is shown; + and − at the top open the matching menus. The overlay shows FPS and target, render size, app CPU, GPU time and physical memory; tap its top edge to collapse it. Auto-lock is suspended while the game is in front. Settings live in the app's `Documents/work/settings.json`, separate from the Mac; there is no full settings panel on iOS yet.
