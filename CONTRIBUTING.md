# Contributing to IOU

Report reproducible bugs or propose a focused change through [GitHub issues](https://github.com/PhilForever/IOU/issues). Include the addon version, Forever client build, steps, and any Lua error text. Use synthetic player names and notes; public issues should not contain private ledger exports or account data.

## Set up and check a change

Use Python 3.12 and install the test dependency:

```sh
python -m pip install -r requirements-dev.txt
python tools/test_iou.py
python tools/test_curseforge.py
python tools/package_iou.py
```

The tests execute Lua 5.1 via Lupa. The package builder uses Python's standard library and validates all TOC/XML dependencies before creating `artifacts/IOU-<version>.zip` and its checksum. Generated artifacts and local environments are ignored by Git.

Keep Lua compatible with 5.1 and use APIs available on the targeted Forever client. Prefer small changes with regression coverage for bookkeeping, serialization, migration, or user interactions whose behavior can be tested meaningfully. Run the relevant [in-game checks](docs/manual-testing.md) for UI/API changes and report which checks were actually performed.

## Preserve people's records

Existing ledgers and exported backups must continue to load. Do not silently discard malformed data, rewrite payment amounts through an edit, or treat cancellation as repayment. Corrections should leave an understandable audit trail. Import must remain a validated, previewed, explicit replacement. Add migration and round-trip tests whenever a persisted field changes.

The runtime is deliberately self-contained. Keep real player data, machine paths, credentials, personal screenshots, and unrelated addon code out of commits and release assets.

## Open a pull request

Describe the user-facing problem and final behavior, state how you validated it, and identify any remaining live checks. Update the README or changelog when behavior changes. CI tests and packages the addon; it does not replace client testing.

For a release, update the TOC version and changelog, record which checks were performed, and push the corresponding `v<version>` tag. The release workflow refuses a mismatched version, reruns tests, and uploads the installable ZIP and checksum to GitHub and CurseForge. A push to `main` builds a CI artifact without publishing a release. See [Publishing](docs/publishing.md) for Actions configuration and backfilling an existing release.
