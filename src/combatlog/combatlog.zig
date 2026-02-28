//! Combat log freshness module.
//!
//! Appends a timestamp to the combat log filename so each client session
//! gets a fresh log file (e.g. WoWCombatLog_20260227_123456.txt).
//!
//! TODO: Find and hook the combat log open/create function.

const con = @import("../console.zig");

pub fn installHooks() void {
    con.print("[combatlog] Module loaded (stub)\n");
}

pub fn removeHooks() void {}
