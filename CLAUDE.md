# CLAUDE.md — DataVault.jl

**Layer 2 of the infra HPC stack** (ParamIO → DataVault → SweepRunner):
maps a `DataKey` to file storage and tracks what's done. project-agnostic. See
[`../CLAUDE.md`](../CLAUDE.md) for how the three layers fit together.

## Role / public API

- `Vault(config; run="default", outdir=…)` — attach to one `(study, run)`;
  writes the `log.toml` discovery anchor + a config snapshot.
- `save!(vault, key, dict) -> (; file, sha256)` / `load(vault, key)` — atomic (NFS-safe) JLD2 IO.
  `sha256` is taken from the temporary file before the rename: pass it on as
  `mark_done!(vault, key; result=save!(…))` so the `.done` marker names the bytes written.
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
- **`observe_sources(vault) -> token` keeps two claims apart.** The SNAPSHOT (`sources/src1-<hex>/`,
  id = SHA-256 of its `files.tsv`) is content only — no HEAD, no host — so equal trees get equal
  ids. The OBSERVATION (`observations/<token>.toml`) holds when/where/HEAD/dirty and the
  **binding**: `loaded-matches-disk` only when packages loaded from the config's repo were
  checked against the snapshot via their precompile cache headers (size + CRC32c, an internal
  API — anything unreadable is `unknown`, never a match). Nothing under `.datavault/` may be
  named `*.log.toml`: discovery walks the tree for that suffix.
- **`.done` is `key=value` lines, `done_version=2`.** Readers take the keys they know and ignore
  the rest; keys are only ever added. Every v2 field is written on every call (`unknown` rather
  than absent). `git_commit_observed` is the working tree at completion (`git_observed_at`), an
  observation — never a claim about the code a process had loaded.

Run the test suite locally before pushing.
