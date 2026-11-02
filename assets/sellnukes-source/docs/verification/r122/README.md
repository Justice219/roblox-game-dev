# R122 "Algorithm pack" (0.8.0) — Studio verification (2026-11-01, lead, solo playtests)

| Script | Result |
|---|---|
| `tools/qa/opening_check.py` | PASS — New Player Mode buys Tool Wall → Glow Lamp → Uncle Atom (pad 4); the Workbench then runs by itself (+$8.8/s). `docs/verification/opening/` |
| `tools/qa/ftue_check.py` | PASS — loading → reveal → Welcome Back → coach card order; step-1 / step-2 hints per device; boot 8.85 s in Studio. `docs/verification/r78-ftue/after-*.jpg` |
| `tools/qa/r122_check.py` | PASS 11/11 — boot telemetry (BootStep Loaded 0.33 / Client 0.33 / Profile 1.94 / World 4.36 / Assets 6.34 / Plot 9.83 s, BootEnd `budget`); HUD INVITE + invite moment (phone / tablet / console captures here); console Shop opens focused on a section heading, not BUY; return notification test queued, claimed and sent as `dry`. |
| `tools/qa/lucky_buttons.py` | R122 checks PASS — a paid walk-in opens NO prompt (prompted +0) and shows the DEAL card (dealShown +1; `docs/verification/lucky-buttons/paid-deal-card.jpg`). Pre-existing: "natural spawn within 45 s" fails because the R78/R89 activity rule does not arm buttons for a character standing still after the script's teleport (spawn code untouched by R122). |

Studio note: Studio starts the server with the client, so `Plot` / `World` step times include server
boot; read the live `cp:<Class>:bootStep*` rows ("Client boot steps by device") for real players.
Cosmetic, admin-only: the NEW PLAYER MODE chip overlaps the coach strip's third tile on phone.
