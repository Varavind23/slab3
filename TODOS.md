# TODOS

## Offline scan queue (deferred 3A, approved D11 — 2026-08-21)

**What:** Full offline scanning with pending-op queue + bidirectional sync.

**Why:** Sourcers scan at card shows/warehouses with dead zones; v1 is
online-required with durable retry (D9), so a true dead zone means scanning stops.

**Pros:** Restores the scan-anywhere guarantee; strongest field UX.
**Cons:** Sync/conflict complexity (multi-device semantics, server-wins rules).

**Context:** v1 ships online-required with a durable retry queue for failed
requests. This TODO is the upgrade path if buyer feedback shows connectivity pain
in the field. Start from `ios/` LocalStore retry queue — extend it into a full
pending-op queue with sync on reconnect.

**Blocked by:** v1 local store shape shipping first.
