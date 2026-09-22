# DataVault.jl

[![docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://qatlashub.github.io/DataVault.jl/stable/)
[![docs: dev](https://img.shields.io/badge/docs-dev-purple.svg)](https://qatlashub.github.io/DataVault.jl/dev/)
[![Julia](https://img.shields.io/badge/julia-v1.12+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![Build Status](https://github.com/QAtlasHub/DataVault.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/QAtlasHub/DataVault.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

config 駆動でパス解決・データ I/O・ledger 管理を提供する量子多体数値計算用のデータ管理基盤。
project-agnostic に設計されており、任意の Julia プロジェクトから使用できる。

---

## 何が嬉しいか

| 問題 | DataVault の答え |
| --- | --- |
| 「あの図のデータ、どのパラメータでどこに保存したっけ?」 | `path_keys` から決定的に path 生成 |
| 「DataVault のバージョンを上げたら過去データが読めなくなった」 | `log.toml` schema 凍結 + reader registry で永続的に互換 |
| 「同じ研究テーマで複数フェーズの計算を並行で走らせたい」 | `run` 階層で 1 study 多 phase をネイティブサポート |
| 「HPC で計算した結果を local で解析したい」 | `outdir` を ENV 変数で切り替え可能、log.toml が自己記述 |
| 「figure スクリプトから過去のデータを横断的に load したい」 | `attach` / `open_all` の query API |
| 「複数の SLURM ジョブが同じ run に書き込んでも壊れないか」 | atomic write + idempotent log.toml upsert |

---

## クイックスタート

### 計算側

```julia
using DataVault, ParamIO

vault = Vault("configs/linear_response.toml";
              run    = "phase1",
              outdir = "out")

for key in DataVault.keys(vault; status=:pending)
    data = compute(key)                       # ユーザー定義
    DataVault.save!(vault, key, data)
    mark_done!(vault, key; tag_value=norm(data))
end

DataVault.build_ledger(vault)                 # ledger.csv を生成
```

実行後、`out/` 配下は次の構造になる:

```text
out/
├── .datavault/                                ← 凍結 discovery anchor
│   ├── README.md                              ← 削除禁止の警告
│   └── linear_response/
│       └── phase1.log.toml                    ← マニフェスト
├── data/linear_response/phase1/
│   ├── config_snapshot.toml
│   ├── ledger.csv
│   └── N24_chi40_g0.50_h0.00/
│       └── data_sample001.jld2
├── status/linear_response/phase1/
│   └── N24_chi40_g0.50_h0.00/
│       └── sample_001.done
└── bin/   (チェックポイント置き場、HPC 用)
```

### 解析側

```julia
using DataVault

# log.toml を発見して全 study に attach
for study in DataVault.open_all("out")
    study.info.project_name == "linear_response" || continue

    for key in DataVault.keys(study.vault; status=:done)
        d = DataVault.load(study.vault, key)
        # plot(d["energy"], ...)
    end
end
```

`open_all` は `outdir/.datavault/` 配下の `*.log.toml` を walk して、各 (study, run) を attach した結果を返す。**config ファイルへのパスを知らなくても** 過去データに到達できる。

---

## コアコンセプト

### Study と Run の階層

```text
Study (= project_name in config)
└── Run  (= named phase / campaign)
    └── DataKey  (= 1 つのパラメータ点 + sample 番号)
        └── data_sampleNNN.jld2
```

- **Study** は研究テーマ。`linear_response`, `dynamical_susceptibility` 等。config TOML の `[study].project_name` で指定。
- **Run** は study の中のフェーズ。`phase1`, `phase2_refined`, `production`, `seed42` 等、自由に命名可能。`Vault(...; run="phase1")` で指定。デフォルトは `"default"`。
- **DataKey** はパラメータ点を表す `NamedTuple` 風の値。`ParamIO` で config からの展開を行う。

run 単位でディレクトリ・ledger・config_snapshot が分離されるので、フェーズの途中で path_keys を変えたり、別の config を使ったりしても干渉しない。

### log.toml: 凍結された discovery contract

DataVault のすべてのバージョンが守る契約:

1. `{outdir}/.datavault/` ディレクトリが存在する
2. その配下に `*.log.toml` がある（v1 では `{project_name}/{run_name}.log.toml`）
3. 各 `*.log.toml` には `[meta].log_toml_version`（整数）がある

`log.toml` の中身は **データへのマニフェスト** で、データの隣ではなく `.datavault/` に置かれる。これにより、未来の DataVault がレイアウトを変えても古いデータの discovery が壊れない。

```toml
# 凍結 envelope
[meta]
log_toml_version   = 1
datavault_version  = "0.4.0"
datavault_git_hash = "abc1234"
created_at         = "2026-04-10T13:50:00"

# v1 body
[study]
project_name = "linear_response"
config       = "configs/linear_response.toml"

[run]
name = "phase1"

[layout]
data_dir        = "data/linear_response/phase1"
status_dir      = "status/linear_response/phase1"
bin_dir         = "bin/linear_response/phase1"
ledger          = "data/linear_response/phase1/ledger.csv"
config_snapshot = "data/linear_response/phase1/config_snapshot.toml"

[path]
scheme    = "default"
formatter = "ParamIO.format_path"
keys      = ["system.N", "model.g"]

[provenance]
julia_version = "1.12.2"
hostname      = "ohtaka"
```

### Forward compatibility model

新しいスキーマを追加するときの手順:

1. `LogTomlV2` struct を定義
2. `_read_log_toml_v2(parsed, path)` reader を実装
3. `LOG_TOML_READERS[2] = _read_log_toml_v2` に追加
4. **過去バージョンの reader は絶対に消さない**
5. `test/vault/fixtures/log_v2.toml` を write-once として追加

これにより、過去どのバージョンで書かれた `log.toml` でも現役の DataVault が読み戻せる。CI は write-once な fixture で過去 reader の挙動を担保する（[test/vault/fixtures/README.md](test/vault/fixtures/README.md)）。

最終アンカーとして、`[meta].datavault_version` と `datavault_git_hash` も記録されているので、reader が朽ちた最悪の場合でも `git checkout v0.X.Y` で過去の DataVault を復元できる。

---

## API 概要

### Writer 側（計算）

| 関数 | 用途 |
| --- | --- |
| `Vault(config; run="default", outdir, path_formatter)` | (study, run) に attach。log.toml + config_snapshot を upsert |
| `DataVault.save!(vault, key, data)` | atomic write（NFS-safe） |
| `DataVault.load(vault, key)` | JLD2 dict を返す。ファイルが無ければ raise |
| `DataVault.tryload(vault, key)` | 同じものを返すが、ファイルが無ければ `nothing` |
| `DataVault.save_bin!` / `load_bin` | チェックポイント（HPC 用） |
| `DataVault.keys(vault; status=:all/:done/:pending)` | DataKey 列挙 |
| `is_done(vault, key)` / `mark_done!` / `mark_running!` | ステータス管理 |
| `acquire_running!(vault, key[, owner])` | POSIX `link()` による排他取得。`owner` を渡すと `.running` に刻む |
| `refresh_running!(vault, key[, owner])` / `clear_running!(vault, key[, owner])` | `owner` 付きは所有者が一致しない限り書かない・消さない |
| `new_owner_token()` / `running_owner(vault, key)` | 取得を識別するトークンの生成と読み出し |
| `build_ledger(vault)` | `.done` を集約して `ledger.csv` を生成 |
| `record_figure(vault; study, scripts)` | figure provenance の `meta.toml` を出力 |
| `cleanup_stale(vault)` | 残存した `.running` を一掃 |

### Reader 側（解析）

| 関数 | 用途 |
| --- | --- |
| `attach(log_path)` | log.toml から writable な Vault を復元 |
| `attach(outdir; project, run="default")` | discovery contract 経由で attach |
| `open_all(outdir)` | 全 (study, run) を発見して attach。`Vector{AttachedStudy}` を返す |
| `Vault(config; …, readonly=true)` / `attach(…; readonly=true)` / `open_all(…; readonly=true)` | log.toml を検証するが書かない。write verb は throw する |
| `load_ledger(vault)` | ledger.csv を `Vector{Dict{String,String}}` で読む |
| `build_master_ledger(outdir)` | 全 ledger を集約 + メタ列付与。source が食い違うと `@warn` |
| `master_ledger_report(outdir)` | 同じ行に加えて `(; ok, columns, sources, collisions)` |
| `read_log_toml(path)` | log.toml を struct に変換（reader registry 経由） |
| `find_log_tomls(outdir)` | `.datavault/*.log.toml` のパス列挙 |

attach は通常の writable Vault を返すので、attach 後に新しい key を計算して `mark_done!` するような **計算再開** もシームレスに動作する。

#### `readonly=true` — 読むだけの consumer が run を凍結しないために

`Vault` の構築は log.toml を upsert する。これは discovery anchor であり、同時に run の
`path_keys` を **凍結** する。よって「残りの key 数を数えるだけ」のスクリプトが、まだ 1 key も
実行していない run に対して schema を commit してしまう。集計・進捗カウンタ・プロット側は
`readonly=true` を使う:

```julia
v = Vault("config.toml"; run="phase1", outdir="out", readonly=true)
count(k -> !is_done(v, k), DataVault.keys(v))
```

既存の log.toml があれば **検証はする**（`path_keys` が食い違えば従来どおり refuse）。無ければ
refuse しない。`save!` / `save_bin!` / `mark_done!` / `mark_running!` / `acquire_running!` /
`touch_running!` / `refresh_running!` / `clear_running!` / `build_ledger` / `record_figure` /
`cleanup_stale` は
throw するので、フラグはラベルではなく検査になっている。

### 並列ジョブ

複数の SLURM ジョブが **同じ (study, run)** に対して `Vault(...)` を呼び出しても安全:

- log.toml の write は per-task 一意な tmp + atomic rename で衝突しない
- 同じ内容の upsert なので last-write-wins で問題なし
- 各ジョブが別の DataKey を担当している限り、データファイルは衝突しない

---

#### `.running` の所有者スタンプ

`acquire_running!(vault, key)` はロックを **無所有** で作る。この形だと、stale 判定で sibling が
reclaim したあと、元の保持者は自分が負けたことを知れない:

| | owner 無し | `owner` 付き |
|---|---|---|
| 負けた側の `refresh_running!` | `true`（reclaim 側の heartbeat を上書きする） | `false`（何も書かない） |
| 負けた側の `clear_running!` | reclaim 側のロックを **消す** | 何もしない |

```julia
tok = DataVault.new_owner_token()
acq = DataVault.acquire_running!(vault, key, tok; stale_after=600.0)
acq === :busy && return
...
DataVault.refresh_running!(vault, key, tok) || return   # 負けたら止まる
DataVault.clear_running!(vault, key, tok)               # 自分のものだけ消す
```

2引数の形は従来どおり残してある。owner 検査は read-then-write なので、その隙間での reclaim までは
閉じない。閉じるのは「reclaim が **すでに起きている**」場合、つまりキーの残り時間ずっと続く方。

### 中間成果物 (artifact) — セル間で共有し、一度だけ作る

セルの高価な前処理が軸の**一部**にしか依存しないとき（駆動周波数に依らない基底状態など）、
config で依存する軸を宣言し（ParamIO の `[artifacts.<name>]`）、`work_fn` の中で `artifact!` を呼ぶ:

```toml
[artifacts.ground_state]
depends_on = ["U", "D", "cutoff"]   # 読むパラメタを全部書く
version    = 1                      # 作るコードを変えたら上げる
```

```julia
work_fn = key -> begin
    gs = DataVault.artifact!(vault, :ground_state, key) do akey   # 無いときだけ走る
        prepare_ground_state(param(akey, "run.U"), param(akey, "run.D"))
    end
    Dict("chi" => respond(gs, param(key, "run.omega1")))
end
```

- **識別**は `depends_on` に射影したキー + `version`。どれかが変われば別物になり、古いものは使われない。
- **保存先**は run の外: `{outdir}/artifacts/{project}/{name}/{sha256 先頭16桁}/` に
  `artifact.jld2`（中身 + 完全な識別文字列）と `inputs.toml`（人が読む入力の記録）。
  同じ `outdir` の別ジョブ・別 run からも再利用される。
- **`akey` は射影後のキー**なので、宣言していないパラメタを builder が読むとそこで失敗する
  （宣言漏れで別の値のセル同士が同じ artifact を共有してしまうのを防ぐ）。
- **並行**: 同時に要求した worker は `.running` と同じ `link()` ロックで直列化され、1 人だけが作る。
  `wait=true`（既定）なら他は完成を待って読む、`wait=false` なら `ArtifactBusy` を投げる。
  builder が例外を投げたら何も残さずロックを外す。
- **ハートビート**はビルド中、小さな `sh` 子プロセスが親の生存（`kill -0`）を見ながら更新する。
  Julia 内のタスクでは、譲らない計算の間は一度も回らない（`julia -t 1,1` でも 3 秒で 0 tick、実測）ため。
  親が強制終了されると更新が止まり、`stale_after` 後に次のジョブがロックを回収する — ビルド時間に依らない。
- 待機中は 10 分ごとに `@info` で「何を待っているか」を出す（黙って止まらない）。
- `readonly=true` の Vault は読むだけで、無ければ例外。
- `has_artifact` / `load_artifact` / `tryload_artifact` / `DataVault.artifact_dir`。

## カスタマイズ

### Path scheme のカスタマイズ

```julia
my_format = (key, _) -> begin
    n = key.params["system.N"]
    g = key.params["model.g"]
    "custom_N$(n)_g$(g)"
end

vault = Vault(config; path_formatter=my_format)
```

ただし custom formatter を使うと **log.toml だけからは path scheme が復元できない**ので構築時に warning が出る。再現性を取りたければ formatter を含むコードも一緒にバージョン管理すること。

### outdir の解決順序

1. `Vault(...; outdir=...)` の引数
2. `ENV["DATAVAULT_OUTDIR"]`
3. config TOML の `[study].outdir`

HPC 計算では 2 を使って scratch に書き、ローカルで 3 を使って解析する、という典型パターンを想定している。

---

## ディレクトリ構成

```text
src/
├── DataVault.jl          # モジュールエントリ
├── core/
│   ├── vault.jl          # Vault struct + constructor
│   └── paths.jl          # data/status/bin/figure の path 解決
├── io/
│   ├── atomic.jl         # NFS-safe な atomic write
│   ├── data.jl           # save! / load
│   └── status.jl         # is_done / mark_done! / mark_running!
├── util/
│   ├── log_toml.jl       # 凍結 discovery contract と reader registry
│   ├── snapshot.jl       # config_snapshot.toml
│   ├── enumerate.jl      # keys()
│   ├── cleanup.jl        # cleanup_stale
│   └── query.jl          # attach / open_all / load_ledger / build_master_ledger
└── reporting/
    ├── ledger.jl         # build_ledger
    └── figure.jl         # record_figure (meta.toml)

test/vault/
├── test_vault.jl         # 既存の writer API
├── test_log_toml.jl      # 凍結 contract と forward compat
├── test_query.jl         # attach / open_all / load_ledger / build_master_ledger
└── fixtures/             # write-once な log.toml サンプル
    ├── README.md
    ├── study.toml
    ├── log_v1.toml
    ├── log_v99_unknown.toml
    └── log_v1_missing_meta.toml
```

---

## バージョン履歴

| version | 主な変更 |
| --- | --- |
| **0.4.0** | `attach` / `open_all` / `load_ledger` / `build_master_ledger` の query API。log.toml だけからの復元・横断検索が可能に |
| **0.3.0** | `log.toml` discovery contract の導入。`run` 階層を first-class に。path に `{project}/{run}/` を挟む破壊的変更 |
| **0.2.x** | path_formatter のカスタム拡張、role-based モジュール構成へのリファクタ |
| **0.1.x** | 初期 API（Vault, save!, load, ledger, figure provenance） |

詳細は git tag と各 PR を参照。
