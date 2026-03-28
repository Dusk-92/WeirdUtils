//! portal_filter -- click filtering for summoned ritual and portal GOs.
//!
//! Filters ritual (type 18) and spellcaster/portal (type 22) game objects
//! whose creator is not in the player's party or raid. The client reports
//! these as "interactable" (same faction) but the server rejects the click
//! if you're not grouped with the summoner.

const hook = @import("zhook");
const wow = @import("../wow.zig");

const DESC_CREATED_BY_LO: usize = 0x06 * 4;
const DESC_CREATED_BY_HI: usize = 0x07 * 4;

/// Returns true if this summoned GO should be filtered (player creator not in group).
/// NPC-created GOs are never filtered.
pub fn shouldFilter(desc: u32) bool {
    const creator_lo = hook.readMem(u32, desc + DESC_CREATED_BY_LO);
    const creator_hi = hook.readMem(u32, desc + DESC_CREATED_BY_HI);
    const creator_guid = @as(u64, creator_hi) << 32 | creator_lo;
    if (creator_guid == 0) return false;
    // High type 0x0000 = player GUID. Non-player creators are always allowed.
    const high_type: u16 = @truncate(creator_guid >> 48);
    if (high_type != 0x0000) return false;
    return !wow.isInGroup(creator_guid);
}
