# Clickthrough GO Allowlist Research

Objects that should be valid click-through targets (click through players/units to reach these).

Source: TortoisWoW server at `the TortoisWoW server source`

## Allowed by GO Type

### Type 19 — MAILBOX (all entries)
| Entry | Name |
|-------|------|
| 142102 | Dwarven Mailbox |
| 142109 | Ornamental Mailbox |
| 143983 | Carved Mailbox |
| 144112 | Mechanical Mailbox |
| 144131 | Alliance Mailbox |
| 173221 | Horde Mailbox |
| 177044 | Damaged Mailbox |
| 179895 | Primitive Mailbox |
| 1000391 | Creaking Mailbox |
| 2011101 | Highborne Mailbox |
| 2011102 | Illidari Mailbox |
| 2011103 | Warden Mailbox |
| 3000208 | Thalassian Mailbox |

### Type 18 — SUMMONING_RITUAL (all entries)
| Entry | Name |
|-------|------|
| 1000084 | Refreshment Table (mage conjured table) |
| 36727 | Summoning Portal (warlock Ritual of Summoning) |
| 179944 | Meeting Stone Summoning Portal |
| 1000089 | Soulwell (healthstone dispenser) |

### Type 2 — QUESTGIVER (all entries)
| Entry | Name |
|-------|------|
| 1000333 | Goblin Brainwashing Device |

## Allowed by Entry (type 1 BUTTON — ambiguous, also used for BG banners)
| Entry | Name |
|-------|------|
| 1000083 | Refreshment Portal (ritual click target) |
| 1000087 | Soulwell Portal (ritual click target) |

## Allowed by Entry (type 10 GOOBER — also used for AB neutral banners)
| Entry | Name |
|-------|------|
| 181575 | Naxxramas Portal — Arachnid wing end |
| 181576 | Naxxramas Portal — Construct wing end |
| 181577 | Naxxramas Portal — Plague wing end |
| 181578 | Naxxramas Portal — Military wing end |

All four cast spell 28444, teleporting to central hub (3005.8, -3434.3, 294).
Controlled by instance script `SetTeleporterState` — `GO_FLAG_NO_INTERACT` removed on wing boss DONE.

## Naxx Wing-End Visual Effects (type 0 DOOR, NOT interactable)
Hub ramps: 181210, 181211, 181212, 181213
Boss rooms: 181230, 181231, 181232, 181233
Hub-to-Frostwyrm portal: 181229 (visual only, teleport via area trigger 4156)

## NOT Allowed (type 1 BUTTON examples — BG capture/assault)
AB: 180058, 180059, 180060, 180061
AV: 178364, 178365, 178388, 178389, 178925, 178929, 178936, 178940, 178943,
    179286, 179287, 180418, 180419, 180420, plus tower BIG banners

## Decorative / Non-interactable (type 5 GENERIC, excluded)
2000241, 2000259, 2004928, 2005008, 2005009, 2008883, 181810
