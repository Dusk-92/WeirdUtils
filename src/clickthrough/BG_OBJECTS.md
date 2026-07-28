# Battleground Interactable Game Objects

Research from TortoisWoW server source (`the TortoisWoW server source`).

## Warsong Gulch (Map 489)

### Flags
| Entry | GO Type | Description |
|-------|---------|-------------|
| 179830 | 24 FLAGSTAND | Silverwing Flag (Alliance at base) |
| 179831 | 24 FLAGSTAND | Warsong Flag (Horde at base) |
| 179785 | 26 FLAGDROP | Silverwing Flag (dropped) |
| 179786 | 26 FLAGDROP | Warsong Flag (dropped) |

### Buffs (proximity-triggered, type 6 TRAP)
179871 (Speed), 179904 (Food/Regen), 179905 (Berserk)

### Doors (type 0, auto-open, not player-interactable)
179916–179921

## Arathi Basin (Map 529)

### Neutral Node Banners (type 10 GOOBER)
180087 (Stables), 180088 (Blacksmith), 180089 (Farm), 180090 (Lumber Mill), 180091 (Mine)

### Faction Banners (type 1 BUTTON)
180058 (Alliance occupied), 180059 (Alliance contested), 180060 (Horde occupied), 180061 (Horde contested)

### Doors (type 0)
180255 (Alliance), 180256 (Horde)

### Aura GOs (type 6, visual only)
180100, 180101, 180102

## Alterac Valley (Map 30)

### GY/Tower Banners (type 1 BUTTON)
178364, 178365, 178388, 178389, 178925, 178929, 178936, 178940, 178943,
179286, 179287, 180418, 180419, 180420

### Tower Banners BIG (type 1 BUTTON)
178927, 178932, 178947, 178948, 178955, 178956, 178957, 178958,
179436, 179440, 179442, 179444, 179446, 179450, 179454, 179458

### Mine Supplies (type 3 CHEST)
178784, 178785, 178786, 178787, 178788, 178789

### Faction Banners (type 3 CHEST)
179024, 179025

### Steamsaws (type 3 CHEST)
178664, 178665

### Snowdrift (type 3 CHEST)
180654

### Special (type 10 GOOBER)
178584 (Ryson's All Seeing Eye)

### Landmines (type 6 TRAP)
179324, 179325

## Sunnyglade Valley (Custom BG)

Reuses AB entries (180087, 180058–180061) plus:
- 179311 (type 3 CHEST)
- 2000381 (type 5 GENERIC, flag stand visual, not interactable)

## Source Files
- `src/game/Battlegrounds/BattleGroundWS.h`
- `src/game/Battlegrounds/BattleGroundAB.h`
- `src/game/Battlegrounds/BattleGroundAV.h`
- `src/game/Battlegrounds/BattleGroundSV.h`
