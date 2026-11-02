# Monetization (live catalogue)

GENERATED table by `tools/monetization/publish.py` (do not edit the table by hand). Source of
truth for WHAT is sold: `src/shared/Config/MonetizationConfig.luau`; ids:
`src/shared/Config/PublishedProductIds.luau` (0 = not created yet -> the game shows COMING SOON).
Universe `10773845696` (place 132667741281890), owner user 1586034782. Icons: `assets/icons/`.

| Key | Kind | Name | Price (R$) | Id | Icon |
|-----|------|------|-----------:|----|------|
| VIP | Game pass | VIP | 122 | 2062649466 | `VIP` |
| DoubleCash | Game pass | 2x Cash | 195 | 2058433191 | `x2Cash` |
| AutoClicker | Game pass | Auto Clicker | 73 | 2063279399 | `AutoClicker` |
| FastWalk | Game pass | Fast Walk | 24 | 2061923824 | `FastWalk` |
| Teleporter | Game pass | Teleporter | 48 | 2061497904 | `Teleporter` |
| LuckyEggs | Game pass | Lucky Eggs | 97 | 2060658474 | `LuckyEggs` |
| PetSlots | Game pass | +2 Pet Slots | 73 | 2058229188 | `PetSlots` |
| TripleHatch | Game pass | Triple Hatch | 73 | 2061353920 | `TripleHatch` |
| AutoHatch | Game pass | Auto Hatch | 122 | 2062643469 | `AutoHatch` |
| OfflineMax | Game pass | Offline Max | 97 | 2058463264 | `OfflineMax` |
| MegaLauncher | Game pass | Mega Launcher | 73 | 2061437855 | `MegaLauncher` |
| AcornsSmall | Product (Acorns) | Acorn Basket | 39 | 3724190807 | `Acorn` |
| Barrage | Product (Barrage) | Nuke Barrage | 79 | 3724190831 | `Barrage` |
| BonesSmall | Product (WorldCash) | Pile of Bones | 23 | 3724510192 | `BonesPackSmall` |
| CashSmall | Product (Cash) | Stack of Cash | 23 | 3724190991 | `CashPack` |
| CrateSupply | Product (Crate) | Supply Crate | 39 | 3724191091 | `Crate` |
| DoubleOffline | Product (DoubleOffline) | Double It! | 31 | 3724191121 | `DoubleOffline` |
| GemsSmall | Product (Gems) | Pile of Gems | 39 | 3724191246 | `GemPack` |
| MoonRocksSmall | Product (WorldCash) | Bag of Moon Rocks | 23 | 3724649324 | `MoonRocksPackSmall` |
| NukePassPremium | Product (PassPremium) | Nuke Pass Premium | 159 | 3725022864 | `NukePass` |
| Spins2 | Product (Spins) | x2 Lucky Spins | 39 | 3724191510 | `Spins` |
| StarterPack | Product (StarterPack) | Starter Pack | 79 | 3724191589 | `StarterPack` |
| AcornsLarge | Product (Acorns) | Acorn Wagon | 119 | 3724190798 | `Acorn` |
| BonesMedium | Product (WorldCash) | Sack of Bones | 63 | 3724510147 | `BonesPack` |
| CashMedium | Product (Cash) | Bag of Cash | 63 | 3724190966 | `CashPack` |
| CrateMega | Product (Crate) | Mega Crate | 119 | 3724191056 | `Crate` |
| GemsMedium | Product (Gems) | Bag of Gems | 119 | 3724191199 | `GemPack` |
| MoonRocksMedium | Product (WorldCash) | Sack of Moon Rocks | 63 | 3724649274 | `MoonRocksPack` |
| SecretPack | Product (SecretPack) | Secret Pack | 399 | 3724191289 | `SecretPack` |
| ServerCash2x | Product (ServerBoost) | Server 2x Cash | 159 | 3724191337 | `ServerBoost` |
| Shield1h | Product (Shield) | Shield (1 h) | 39 | 3724191393 | `Shield` |
| Spins5 | Product (Spins) | x5 Lucky Spins | 79 | 3724191555 | `Spins` |
| BonesLarge | Product (WorldCash) | Crate of Bones | 159 | 3724510119 | `BonesPackLarge` |
| Cash2x30 | Product (Boost) | 2x Cash (30 min) | 79 | 3724190860 | `x2Cash` |
| CashLarge | Product (Cash) | Crate of Cash | 159 | 3724190921 | `CashPack` |
| CrateGolden | Product (Crate) | Golden Crate | 319 | 3724191016 | `Crate` |
| GemsLarge | Product (Gems) | Chest of Gems | 319 | 3724191167 | `GemPack` |
| MoonRocksLarge | Product (WorldCash) | Crate of Moon Rocks | 159 | 3724649223 | `MoonRocksPackLarge` |
| RevengeNuke | Product (RevengeNuke) | Golden Revenge Nuke | 31 | 3725620060 | `MegaLauncher` |
| Spins10 | Product (Spins) | x10 Lucky Spins | 143 | 3724191484 | `Spins` |
| TurkeyLure | Product (TurkeyLure) | Golden Turkey Lure | 63 | 3724191635 | `TurkeyLure` |
| AstronautPack | Product (WorldStarter) | Astronaut Pack | 79 | 3724649081 | `AstronautPack` |
| CashHuge | Product (Cash) | Vault of Cash | 359 | 3724190895 | `CashPack` |
| SkipPad | Product (SkipPad) | Skip Pad | 20 | 3724191461 | `SkipPad` |
| TimeTravelerPack | Product (WorldStarter) | Time Traveler Pack | 79 | 3724510226 | `TimeTravelerPack` |
| PocketRocket | Product (PocketRocket) | Pocket Rocket | 15 | 3725469699 | `PocketRocket` |

## Runbook

```bash
python3 tools/monetization/publish.py probe        # read-only: which local key can read passes / products
python3 tools/monetization/publish.py plan         # dry run
python3 tools/monetization/publish.py publish      # create missing, patch changed, write ids + this doc
python3 tools/monetization/publish.py status       # catalogue vs recorded ids (offline)
lune run tests/validate.luau && lune run tests/profile-logic.luau
```

- **Idempotent:** items match by recorded id, else by exact name, so nothing is created twice;
  existing items get a PATCH of only the changed fields (name, description, price, for-sale,
  icon when its PNG changed). Prices / names change in MonetizationConfig, then rerun `publish`.
- **Journal:** `tools/monetization/state.json` records each create intent before the POST and the
  id after. An interrupted create is adopted by name on the next run; if it is still missing,
  `--retry-creating` is required (no blind duplicate).
- **Key + scopes:** an Open Cloud key with `game-pass:read`, `game-pass:write`,
  `developer-product:read`, `developer-product:write`, with experience 10773845696 added, in
  `~/.config/robeasts/open-cloud.env` (`ROBLOX_OPEN_CLOUD_KEY=`, chmod 600) or
  `~/.config/robloxstudio-mcp/open-cloud-key`. Never printed; `probe` shows only source labels.
- Icons follow `IconAssets.get` resolution (product key, its alias, then the config `icon` name).
- **Live prices (managed pricing):** every item uses Roblox managed pricing, so the Price column
  is only the configured FALLBACK. The client shows what Roblox will charge through
  `src/client/UI/PriceBook.luau` (GetProductInfoAsync; 8 in flight, <= 60 calls / min, 5 attempts
  with jittered backoff, refresh every ~10 min; `...` until known; tunables `PriceBookConfig`;
  test `tests/price-book.luau`). UI hooks: `StudUI.robuxTag(price, size, key)`,
  `StudUI.button({ productKey = key })` / `setProductKey`, `StudUI.starburst({ productKey = key })`.
