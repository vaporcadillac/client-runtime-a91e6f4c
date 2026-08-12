# Repository guide

This repository contains the runtime Mini Pinata engine and its client-side
profit ledger. Read `docs/PROJECT_STATE.md` and `docs/TEST_LOG.md` before any
substantial change.

- Treat `main` as the live baseline; do not describe an open PR as deployed.
- Keep runtime-only endpoints, write keys, and webhook URLs out of Git.
- Preserve the separation between the placement engine, ledger, and external
  telemetry Worker.
- Validate changed Lua structurally and record a real test in `docs/TEST_LOG.md`.
