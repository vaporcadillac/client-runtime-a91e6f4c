# Test log

Use one entry per controlled run. Record observed facts, not assumptions. Do
not change multiple variables in the same comparison run.

## Entry template

### YYYY-MM-DD — Short test name

- **Purpose:**
- **Account / environment:**
- **Code versions:** engine commit/build; ledger commit/build; Worker version;
  router revision
- **Start / end (local time):**
- **Runtime:**
- **Configuration:** interval, adaptive settings, telemetry cadence, ledger
  sample interval, relevant external features enabled/disabled
- **Baseline / comparison:**
- **Attempts / confirmations / failures:**
- **Placements per minute:**
- **Inventory and ledger deltas:** Pinatas consumed; tracked loot by item;
  gem movement; any reset or rollback
- **Health:** FPS range, ping range, restarts, disconnects, errors, telemetry
  age
- **Observations:**
- **Conclusion:** supported / not supported / inconclusive
- **Next action:**

## Recorded history

### 2026-08-11 — Telemetry end-to-end check

- **Purpose:** Confirm engine publisher through Worker, D1, and Discord.
- **Accounts / environment:** Three active Mini Pinata accounts.
- **Observed result:** Fleet reporting showed approximately 9.2–9.5 placements
  per minute with 100% confirmation in recorded snapshots.
- **Conclusion:** End-to-end telemetry was working at that time.
- **Caveat:** Exact runtime duration, router revision, and per-account raw logs
  were not preserved in this repository.

### 2026-08-12 — Ledger discrepancy investigation

- **Purpose:** Compare retained daily loot telemetry with manually observed
  inventory.
- **Observed result:** Cocktails were absent and Charm Stone cumulative totals
  showed backward movement across snapshots.
- **Conclusion:** Current main's alias, persistence, and session-continuity
  weaknesses are credible causes. PR #6 contains proposed fixes but has not
  been deployed.
