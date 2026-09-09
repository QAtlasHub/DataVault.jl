# CLAUDE.md — DataVault.jl

**Layer 2 of the infra HPC stack** (ParamIO → DataVault → SweepRunner):
maps a `DataKey` to file storage and tracks what's done. project-agnostic. See
[`../CLAUDE.md`](../CLAUDE.md) for how the three layers fit together.

## Role / public API

- `Vault(config; run="default", outdir=…)` — attach to one `(study, run)`;
  writes the `log.toml` discovery anchor + a config snapshot.
- `save!(vault, key, dict)` / `load(vault, key)` — atomic (NFS-safe) JLD2 IO.
- `keys(vault; status=:all/:done/:pending)`, `is_done`/`mark_done!`/`mark_running!`.
- `build_ledger(vault)` → `ledger.csv`; `record_figure`.
- `attach`/`open_all`/`load_ledger` — read data back later **without knowing the
  config path** (discovery via `.datavault/`).

## Where to look for usage

- `examples/` — a ParamIO + DataVault demo (VanDerPol, manual loop).
- `README.md` — the most thorough doc in `infra/`: study/run hierarchy, the
  `log.toml` contract, the query API.
- Full stack incl. the runtime that drives `save!`/`mark_done!` for you:
  [`../SweepRunner.jl/examples/`](../SweepRunner.jl/examples/).

## Invariants when changing this package

- **The discovery contract is FROZEN**: `{outdir}/.datavault/{project}/{run}.log.toml`
  naming, and `[meta].log_toml_version`. **Never delete an old `log.toml`
  reader** — forward-compat means a current DataVault must read any version ever
  written. Add a new reader to the registry instead. See `src/util/log_toml.jl`
  and `test/vault/fixtures/`.
- `outdir` precedence: kwarg > `ENV["DATAVAULT_OUTDIR"]` > config `[study] outdir`.

Run the test suite locally before pushing.
