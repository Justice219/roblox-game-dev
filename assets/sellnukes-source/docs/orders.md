# Order Window — RETIRED (owner R128, 0.8.1, 2026-11-01)

Owner R128: "bro honestly just remove the orders system entirely" (`docs/owner-requests.md` R128; it superseded R124–R126).
The R90 Order Window (customers, carried nukes, trays, tips, Customer Fame, the `Carry` action, 5 remotes, the `order` daily mission) was removed from code; old saves drop `profile.orders` on load and a still-open `order` mission is swapped for a live one (`QuestConfig.RetiredStats`, no reroll used).
Kept on purpose: the `orders` analytics family definitions + its append-only unique-surface bit (old days still render), the `Order_*` MeshAssets entries and `tools/blender/models/orders.py`, and `TipJar.addCoins` (now without a caller).
The full design lives in git history (`docs/orders.md` before 0.8.1) and `docs/superpowers/specs/2026-10-31-r90-hands-on-design.md` §1.
