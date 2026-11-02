# R138: Happy Hour chip on phones (Studio solo playtest, 2026-11-01)

Forced `HappyHourService.force("sprinkle", 600)`, then captured with `capture_device_matrix`. In
Studio that override uses the `_Studio` store and topic, so live servers were not touched.

| File | Device | Spot | Chip | Share of screen width |
|---|---|---|---|---|
| `before-after-iphone.jpg` | the owner's iPhone vs iphone_14 | leftOfTop | | about a third → 13.2 % |
| `phone-iphone14.jpg` | iphone_14 | leftOfTop | 99 x 45 pt | 13.2 % |
| `phone-iphone7.jpg` | iphone_7 | underTopRight | 99 x 45 pt | 14.8 % |
| `phone-iphone16promax.jpg` | iphone_16_pro_max | rightOfTop | 99 x 45 pt | 11.9 % |
| `phone-galaxy-a06.jpg` | samsung_galaxy_a06 | underTopRight | 99 x 45 pt | 14.0 % |
| `tablet-ipad.jpg` | ipad_10th_generation | topLeft (unchanged) | full line | 21.2 % |
| `console-xbox.jpg` | xbox | topLeft (unchanged) | full line | 21.2 % |

Look at: the chip is off the character and clear of every button. All four phones meet the 44 pt tap
target.

`rejected-first-try-above-character.jpg` is the first version of the fix: a small chip, but 177 px wide,
so it fit neither side gap and fell back to the spot above the character's head. The tests had
passed because their phone layout was wider than a real phone. They now use the zones measured on
this iPhone 14 preset.

Not visible in captures: the Roblox top bar (CoreGui). Top-bar clearance comes from
`GuiService.TopbarInset`, which `place` treats as an obstacle. The console read `spot=none` for a few
seconds right after switching presets, then settled on `topLeft`; it is not a bug.
