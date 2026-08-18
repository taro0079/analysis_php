# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A single-purpose numerical experiment: a 2D heat-conduction solver (explicit finite
difference) implemented four different ways in PHP, used to measure how PHP's array
idioms scale — and how that scaling differs between PHP versions (7.4 vs 8.5). It is a
measurement rig, not an application: no framework, no composer.json, no test suite.

## Commands

```sh
# 全体を回す。7.4 と 8.5 を Docker で順に実行し、benchmark.csv にまとめる。
./run_benchmark.sh

# 動作確認用の短い掃引 (N<=200, steps=20, repeat=2)
./run_benchmark.sh --quick

# 8.5 の JIT 有効版を "8.5+jit" 系列として追加計測
./run_benchmark.sh --jit

# 任意のバージョン集合
./run_benchmark.sh --versions 7.4,8.3,8.5

# Docker を使わずローカルの php で 1 系列だけ
./run_benchmark.sh --runner native

# --- 作図 (すべて benchmark.csv を読む) ---
gnuplot compare_versions.gp                     # バージョン比較 (既定 7.4 vs 8.5)
gnuplot -e "old='7.4'; new='8.5+jit'" compare_versions.gp
gnuplot -e "series='8.5'" average.gp            # 単一系列の t(N)=a*N^p フィット
gnuplot -e "series='8.5'" plot_time.gp          # 生の測定点の散布図

# 温度場ヒートマップ (物理結果。ベンチマークとは独立)
BENCH_HEATMAP=1 ./run_benchmark.sh --versions 8.5 --quick
gnuplot heatmap.gp
```

There is no build, lint, or test step. Run `run_benchmark.sh` before any `.gp` script,
or the plots reflect stale data.

A full sweep is slow by design — `simulationArrayMerge` is intentionally quadratic per
row and dominates wall time at large N, and the whole thing runs twice (once per
version). Use `--quick`, or narrow with `BENCH_GRIDS` / `BENCH_METHODS`, while iterating.

## Architecture

**One PHP file, four solvers, one shared kernel.** `simulationFor`, `simulationForeach`,
`simulationArrayMap`, and `simulationArrayMerge` in
[compare_array_function.php](compare_array_function.php) all compute the *same* explicit
finite-difference update and must stay numerically identical — only the array traversal
idiom differs. The `center_temperature` column in benchmark.csv is the cross-check: if
one method's center value diverges from the others at the same N, that method's kernel
has drifted.

`simulationArrayMerge` is deliberately pessimal (re-merging a growing array per cell) to
provide an upper bound on the plot. Do not "fix" it — that is the finding.

**The PHP script must stay PHP 7.4-compatible.** It is executed unchanged by every
version under test. No union types, no `match`, no named arguments, no constructor
promotion, no `readonly`. `php -l` under `php:7.4-cli` is the real check:

```sh
docker run --rm -v "$PWD":/app -w /app php:7.4-cli php -l compare_array_function.php
```

`csvRow()` wraps `fputcsv` with an explicit empty `$escape` — PHP 8.4+ deprecates the
default value, and `""` is accepted from 7.4 onward. Writing `fputcsv` directly would
emit Deprecated notices on 8.5 but not 7.4. Use `csvRow()`.

**Everything is driven by environment variables**, so one script serves every version and
`run_benchmark.sh` only has to set env: `BENCH_OUT`, `BENCH_GRIDS`, `BENCH_STEPS`,
`BENCH_REPEAT`, `BENCH_METHODS`, `BENCH_SERIES`, `BENCH_LABEL`, `BENCH_HEATMAP`. Defaults
live at the top of the PHP file.

**The heatmap is opt-in.** `temperature.csv` is a physics result, identical on every PHP
version, so regenerating it once per version would be pure waste. It is skipped unless
`BENCH_HEATMAP=1`.

### Fair-comparison invariants

`run_benchmark.sh` exists mainly to hold these fixed; breaking any of them silently
invalidates the comparison:

- **Same architecture.** `--platform` is pinned from `uname -m`. If one version fell back
  to a QEMU-emulated image and the other ran native, the emulated one would look
  catastrophically slow for reasons unrelated to PHP.
- **Same `memory_limit`** (`512M` default) — the official images ship `128M`, and GC
  pressure differences would otherwise leak into the timings.
- **Same opcache state.** `php:7.4-cli` has no opcache built in; `php:8.5-cli` has it
  compiled in but with `opcache.enable_cli=0`. The default run is therefore opcache-off
  on both. JIT is opt-in via `--jit`, recorded as a *separate* series (`8.5+jit`) rather
  than mixed into the `8.5` numbers.

`--platform`, uid/gid mapping (Linux only, so container-written files aren't root-owned),
and podman fallback are all there for portability across machines.

### CSV contracts

The gnuplot scripts index benchmark.csv by *column number*, not by header name:

```
1 method  2 N  3 cells  4 steps  5 repeat  6 time_sec
7 time_per_step_ms  8 time_per_cell_ns  9 peak_memory_mb  10 center_temperature
11 php_series  12 php_version
```

Column 11 (`php_series`, e.g. `7.4`, `8.5`, `8.5+jit`) is the key every plot filters on —
`benchmark.csv` holds all versions concatenated. Adding or reordering columns in
`csvRow()` breaks every `.gp` file; update
[average.gp](average.gp), [compare_versions.gp](compare_versions.gp), and
[plot_time.gp](plot_time.gp) together with any schema change.

`run_benchmark.sh` also leaves per-version `benchmark_<series>.csv` files; `benchmark.csv`
is their concatenation with one header.

temperature.csv is `x,y,temperature` with a blank line after each y-row so gnuplot can
find grid row boundaries. [heatmap.gp](heatmap.gp) additionally filters through awk
(`NF==3 && numeric`) to drop the header and blank lines before `with image`.

### Fitting approach (average.gp)

`average.gp` does not fit in linear space. Times span four decades, so a linear-residual
fit would be dominated by the largest N. It instead uses `smooth unique` via `set table`
to average repeats per N into `mean_<method>_<series>.dat`, then fits
`log(t) = log(a) + p*log(N)` — minimizing relative error so the line matches what the
log-log plot shows. Keep this transform; reverting to a direct `a*N**p` fit produces
curves that visibly miss the points.

The `array_merge` exponent is an effective scaling index over the measured range, not an
asymptotic one — its local slope grows with N (see the comment block in average.gp).

`compare_versions.gp` reuses the same mean files and derives speedup by joining the two
series' `.dat` files with awk on N. awk (not `paste`) because the join must not depend on
how many comment lines `set table` emits, and not on bash process substitution — gnuplot's
`<` popen goes through `/bin/sh`, which is dash on many Linux distros.

### gnuplot gotchas hit here

- The `@` macro expands **string variables only**, not function calls. Reference the
  `series` variable directly inside a `using` expression instead.
- `pngcairo enhanced` renders `_` as a subscript, so `array_map` became `array<sub>m</sub>ap`
  in legends. All three scripts set `set key noenhanced`.

## Notes

- Comments and commit messages in this repo are written in Japanese; match that style.
- Generated artifacts (`benchmark*.csv`, `mean_*.dat`, `temperature.csv`, `fit.log`,
  `*.png`) are untracked. Regenerate rather than hand-edit them.
- Measured result so far: on this array-bound workload 8.5 is only ~1.0-1.06x faster than
  7.4, even though a scalar-loop microbenchmark in the same containers shows ~1.3x. The
  benchmark is dominated by 2D array element access and copy-on-write separation, where
  7.4 -> 8.x gains are small. Don't assume a harness bug if the speedup looks flat.
