# rsg-lumberjack

A standalone lumberjack gameplay script for RSG-Core (RedM). No company/business
ownership, no company database - it's just the core loop: grow trees, chop
wood, carry logs, and load/unload/sell wagons at multiple locations. Tree
growth persists across restarts (see Database section below).

## Dependencies
- `rsg-core`
- `ox_lib`
- `rsg-target`
- `rsg-inventory`
- `oxmysql` (or `mysql-async`/`ghmattimysql`) - used only to persist planted
  tree growth. Ground logs, wood, and wagon loads remain in-memory only and
  reset on resource restart.

## Items needed for inventory
Add these to your `items.lua` / shared items table:

| Item | Type | Purpose |
|------|------|---------|
| `tree_seeds` | item | Plant a new tree |
| `fullbucket` | item | Water a planted tree |
| `log` | item (or prop-only) | Represents a chopped log while carried |
| `wood` | item | Processed wood picked up after chopping a log |
| `axe` | weapon/item | Required to chop trees and process logs |

## Gameplay loop
1. **Growing** - use `tree_seeds` anywhere to plant a tree. Water it
   (`fullbucket`) to advance it through its growth stages. Once fully grown
   it can be chopped for a log. Tree props only spawn client-side while a
   player is within `Config.Planting.RenderDistance` (perf-friendly), and
   the owner sees a live progress bar above any of their own actively-growing
   trees within `Config.Planting.ProgressBarDistance`.
2. **Chopping** - chop wild trees found around the map, or chop your own
   fully-grown planted trees, to get a log. Requires an axe
   (`Config.Chopping.RequireAxe`), which has a chance to break
   (`Config.Chopping.AxeBreakChance`).
3. **Carrying** - chopping (or picking up a dropped log) attaches it to your
   hands. Press E to drop it on the ground, where anyone can pick it up or
   process it into wood (`Config.Items.WoodAmountFromLog` per log).
4. **Wagon load/unload** - approach a log wagon (`Config.Wagon.Model`) while
   carrying a log to load it on (up to `Config.Wagon.MaxLogsOnWagon`). You can
   also pull a log back off into your hands.
5. **Sell wagon load** - drive a full wagon to any location in
   `Config.WagonSellLocations` and press E to sell the whole load for cash.
   Each location has its own `price` and `radius`, so you can add as many
   buyers as you want around the map.

## Configuration
See `shared/config.lua`:
- `Config.Chopping` - axe requirement/break chance, chop durations, cooldown.
- `Config.Planting` - seed/water items, growth durations, max trees per
  player, minimum distance between trees.
- `Config.Wagon` - wagon model, log capacity, attachment/stacking positions.
- `Config.WagonSellLocations` - array of `{ name, coords, radius, price, blip }`
  sell points. Add or remove entries freely.
- `Config.Trees` - the list of wild tree props that can be targeted/chopped.

## Database
Planted tree growth is persisted in a `rsg_lumberjack_trees` table - the schema
and growth-scheduling logic (`MaybeScheduleGrowth` / the periodic growth-tick
loop) are identical to the original script's `lumbercompany_trees` table,
just renamed since it's no longer tied to a company. The table is created
automatically on resource start (`server/db.lua` + `server/main.lua`);
`install/database.sql` is provided for reference/manual installation only.

Ground logs, wood pieces, and wagon loads are still in-memory only and reset
on resource restart - only tree growth needs to survive restarts.

## Notes
- All notifications use `ox_lib` (`lib.notify` / `ox_lib:notify`).
- All player-facing text lives in `locales/en.json`.
- Chopping/carrying/wagon actions are validated server-side (axe ownership,
  cooldowns, proximity, and elapsed time) before any reward is granted - the
  client cannot unilaterally decide it "successfully chopped" something.
- `server/versionchecker.lua` follows the standard Rexshack-RedM version
  checker pattern. It checks
  `https://raw.githubusercontent.com/Rexshack-RedM/rsg-versioncheckers/main/rsg-lumberjack/version.txt`
  - update `githubRawBase` in that file if you host `rsg-lumberjack` update
  checks somewhere else.

## Debug
Set `Config.Debug = true` to enable `/spawnlog`, `/clearlog`, and
`/spawnwagon` test commands, plus verbose server/client console logging.

Credit Mack
