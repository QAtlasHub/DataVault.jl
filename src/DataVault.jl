"""
DataVault — config 駆動のパス解決・データ I/O・ledger 管理

ファイル構成:

```text
src/
├── DataVault.jl         このファイル（モジュールエントリ）
├── core/
│   ├── vault.jl         Vault struct と constructor (path_formatter 含む)
│   └── paths.jl         data/bin/status のディレクトリ・ファイルパス解決
├── io/
│   ├── atomic.jl        NFS-safe 原子的書き込み + git_hash
│   ├── data.jl          load / save! / load_bin / save_bin!
│   └── status.jl        is_done / mark_done! / mark_running!
├── reporting/
│   ├── ledger.jl        build_ledger
│   └── figure.jl        record_figure (meta.toml)
└── util/
    ├── enumerate.jl     keys() — DataKey の列挙
    ├── snapshot.jl      config_snapshot.toml の保存と差分検知
    └── cleanup.jl       cleanup_stale
```
"""
module DataVault

using JLD2, TOML, Dates, Printf
using SHA
using JSON3
using ParamIO

import Base: keys

export Vault
export DataKey                          # re-export from ParamIO
export is_done, mark_done!, mark_running!, touch_running!, running_heartbeat
export clear_running!, is_running
export acquire_running!, refresh_running!, running_age_secs
export build_ledger, record_figure, cleanup_stale
export archive_figure!, list_figure_history, restore_figure!
export build_experiment_report, build_experiments_index, gather_code_versions
export read_schema_record, check_schema_compat
export new_experiment, build_narrative_index, experiment_template
export read_log_toml, find_log_tomls    # log.toml discovery API
export attach, open_all, load_ledger, build_master_ledger, AttachedStudy

# ── 依存順序 ─────────────────────────────────────────────────────────────────
# paths.jl は vault.jl の Vault に依存
# io/data.jl, io/status.jl は paths.jl + io/atomic.jl に依存
# util/snapshot.jl は core/vault.jl の constructor から呼ばれる
# util/enumerate.jl は io/status.jl の is_done に依存
# reporting/* は paths.jl と io/* に依存

include("core/vault.jl")
include("core/paths.jl")        # _run_*_dir 等を log_toml.jl から使う

include("io/atomic.jl")
include("io/data.jl")
include("io/status.jl")

include("util/log_toml.jl")    # vault.jl の constructor から呼ばれる
include("util/snapshot.jl")    # vault.jl の constructor から呼ばれる
include("util/enumerate.jl")
include("util/cleanup.jl")
include("util/query.jl")       # attach / open_all / load_ledger / build_master_ledger

include("reporting/ledger.jl")
include("reporting/figure.jl")
include("reporting/report.jl")
include("experiment/workflow.jl")

end # module DataVault
