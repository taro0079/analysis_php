# 2D 熱伝導ベンチマーク (PHP 7.4 / 8.x / JIT)

同一の 2 次元熱伝導計算 (陽解法) を 4 通りの配列操作で実装し、
PHP のバージョン・opcache・JIT で実行時間がどう変わるかを測るための計測台です。

アプリケーションではありません。フレームワークも composer.json もテストもありません。

| 実装 | 内容 |
| --- | --- |
| `for` | 素の二重 for |
| `foreach` | `foreach` で走査 |
| `array_map` | 入れ子の `array_map` |
| `array_merge` | **意図的に非効率**。1セルごとに配列を再 merge する (上限値を示すため) |

4 つとも計算結果は同一です。CSV の `center_temperature` 列が一致しなくなったら、
どれかのカーネルがずれています。

---

## 1. 必要なもの

| | 用途 | 無いとどうなるか |
| --- | --- | --- |
| Docker (または Podman) | 複数の PHP バージョンを同一条件で回す | `--runner native` でローカルの php 1 バージョンのみ計測できる |
| gnuplot | グラフ生成 (`*.gp`) | CSV は取れるが作図できない |
| php | `--runner native` のときだけ | — |

Docker イメージは公式の `php:<version>-cli` を使います。事前の `docker pull` は不要です
(初回は自動で取得するので時間がかかります)。

```sh
docker --version
gnuplot --version
```

---

## 2. まず動かす

いきなり全掃引すると数十分かかります。まず `--quick` で通してください。

```sh
./run_benchmark.sh --quick
```

- 格子 N = 20,40,80,120,160,200 / 20 ステップ / 2 回繰り返し
- PHP 7.4 と 8.5 を Docker で順に実行
- `benchmark_7.4.csv` `benchmark_8.5.csv` と、それらを結合した `benchmark.csv` ができる

問題なければ本番の掃引を回します (N = 1000 まで。`array_merge` が支配的で長時間かかります)。

```sh
./run_benchmark.sh
```

---

## 3. JIT を比較する

PHP 8 系の JIT を比べるときは **`--opcache` も一緒に付けてください**。
JIT は opcache の上でしか動かないため、`8.5` と `8.5+jit` だけを比べると
opcache 単体の効果まで JIT の成果として数えてしまいます。

```sh
# opcache のみ / トレーシング JIT / 関数 JIT をすべて計測する
./run_benchmark.sh --quick --jit --opcache --jit-mode tracing,function
```

これで次の 5 系列が `benchmark.csv` に入ります。

| 系列名 (CSV 11列目) | 状態 |
| --- | --- |
| `7.4` | opcache / JIT なし |
| `8.5` | opcache / JIT なし |
| `8.5+opcache` | opcache のみ有効 |
| `8.5+jit` | opcache + トレーシング JIT |
| `8.5+jit-function` | opcache + 関数 JIT |

比較の読み方:

| 見たいもの | 比べる系列 |
| --- | --- |
| バージョンの効果 | `7.4` → `8.5` |
| opcache の効果 | `8.5` → `8.5+opcache` |
| **JIT だけの効果** | `8.5+opcache` → `8.5+jit` |
| opcache 込みの JIT の効果 | `8.5` → `8.5+jit` |
| JIT モードの違い | `8.5+jit` と `8.5+jit-function` をそれぞれ `8.5+opcache` と比較 |

実行が終わると、その回に使える gnuplot コマンドが最後に表示されます。

### JIT が本当に効いていたかの確認

`opcache.jit=tracing` を渡していても `opcache.jit_buffer_size` が 0 なら JIT は動きません。
そして「JIT なしで回った `8.5+jit` 系列」は、数値を見ても本物と区別できません。

そこで各系列は期待する状態 (`plain` / `opcache` / `jit`) を宣言して実行され、
PHP 側が `opcache_get_status()` の実際の状態と突き合わせます。食い違えば
**終了コード 1 で停止**するので、気付かないまま誤ったグラフを作ることはありません。

```
ERROR: JIT が有効になっていません (opcache=on jit=off)
```

実行時の実状態は CSV の 13 列目 (`opcache`) と 14 列目 (`jit`) にも記録されます。
あとから `benchmark.csv` を見て確認できます。

```sh
awk -F, 'NR>1 {print $11, $13, $14}' benchmark.csv | sort -u
```

### 空回し (warm-up) について

トレーシング JIT は最初にホットループを踏んだ実行でトレースをコンパイルするため、
その 1 回だけ極端に遅くなります (実測で最小格子の 1 回目が 2 回目の約 10 倍)。
空回しをしないと、このコンパイル時間が最小格子の測定値に丸ごと乗り、
JIT 系列が不当に遅く見えます。

`run_benchmark.sh` は既定で `BENCH_WARMUP=1` を**全系列に同じ値で**渡します
(片側だけ暖めると比較になりません)。変更する場合のみ明示してください。

```sh
BENCH_WARMUP=3 ./run_benchmark.sh --quick --jit --opcache
```

---

## 4. グラフを作る

`.gp` はすべて `benchmark.csv` を読みます。**先に `run_benchmark.sh` を回してください**。
古い CSV のままだとグラフだけが更新されずに食い違います。

```sh
# バージョン比較 (上段: 実行時間 / 下段: 高速化率)。既定は 7.4 vs 8.5
gnuplot compare_versions.gp

# JIT だけの効果
gnuplot -e "old='8.5+opcache'; new='8.5+jit'" compare_versions.gp

# 関数 JIT
gnuplot -e "old='8.5+opcache'; new='8.5+jit-function'" compare_versions.gp

# 単一系列を t(N) = a * N^p でフィット
gnuplot -e "series='8.5+jit'" average.gp

# 平均を取らない生の測定点 (repeat のばらつきを見る)
gnuplot -e "series='8.5+jit'" plot_time.gp
```

`old` / `new` / `series` に渡すのは CSV 11 列目の系列名です。`compare_versions.gp` は
指定した系列が `benchmark.csv` に無ければ、空のグラフを出さずにエラーで止まります。

`compare_versions.gp` は各実装の平均高速化率 (幾何平均) を標準出力にも表示します。

---

## 5. 温度場のヒートマップ

こちらは物理計算の結果で、ベンチマークとは独立です。どの PHP バージョンでも同じ絵になるため、
既定では計算しません。`BENCH_HEATMAP=1` のときだけ `temperature.csv` を出力します。

```sh
BENCH_HEATMAP=1 ./run_benchmark.sh --versions 8.5 --quick
gnuplot heatmap.gp
```

---

## 6. オプションと環境変数

```sh
./run_benchmark.sh --help
```

| オプション | 内容 |
| --- | --- |
| `--quick` | 短い掃引 (N ≤ 200 / 20 ステップ / 2 回) |
| `--jit` | JIT 有効系列を追加 (既定はトレーシング) |
| `--opcache` | opcache のみ有効な系列を追加 |
| `--jit-mode tracing,function` | JIT のモードを指定。複数可。指定すると `--jit` も有効になる |
| `--versions 7.4,8.3,8.5` | 計測するバージョン集合 |
| `--runner native` | Docker を使わずローカルの `php` で回す (バージョンは 1 つ) |

| 環境変数 | 既定 | 内容 |
| --- | --- | --- |
| `BENCH_GRIDS` | `20,...,1000` | 格子サイズ |
| `BENCH_STEPS` | `100` | 時間ステップ数 |
| `BENCH_REPEAT` | `3` | 繰り返し回数 |
| `BENCH_WARMUP` | `1` | 計測前の空回し回数 (`php compare_array_function.php` を直接叩いたときのみ `0`) |
| `BENCH_METHODS` | 4 実装すべて | 計測対象 |
| `BENCH_MEMORY_LIMIT` | `512M` | php の `memory_limit` |
| `BENCH_JIT_BUFFER` | `64M` | `opcache.jit_buffer_size` |
| `BENCH_PLATFORM` | ホストのアーキテクチャ | docker の `--platform` |
| `BENCH_HEATMAP` | `0` | `1` で `temperature.csv` も出力 |
| `CONTAINER_ENGINE` | 自動検出 | `docker` / `podman` |

反復しながら試すときは絞ると速くなります。

```sh
BENCH_METHODS=for,foreach BENCH_GRIDS=100,200 ./run_benchmark.sh --jit --opcache
```

---

## 7. 出力ファイル

| ファイル | 内容 |
| --- | --- |
| `benchmark_<series>.csv` | 系列ごとの生データ |
| `benchmark.csv` | 上記を結合したもの (ヘッダは 1 行)。`.gp` はこれを読む |
| `mean_<method>_<series>.dat` | N ごとに平均した中間ファイル (gnuplot が生成) |
| `benchmark_compare_<old>_vs_<new>.png` | バージョン / JIT 比較 |
| `benchmark_average_fit_<series>.png` | べき乗フィット |
| `benchmark_time_<series>.png` | 生の測定点 |
| `temperature.csv` / `temperature.png` | 温度場 |

`benchmark.csv` の列 (`.gp` は列番号で参照しています):

```
1 method  2 N  3 cells  4 steps  5 repeat  6 time_sec
7 time_per_step_ms  8 time_per_cell_ns  9 peak_memory_mb  10 center_temperature
11 php_series  12 php_version  13 opcache  14 jit  15 warmup
```

13-15 列が追加される前に作った CSV は 12 列しかありません。`.gp` は 1-11 列しか読まないので
描画はできますが、古い行と新しい行を混ぜず、掃引をやり直してください。

---

## 8. 公平な比較のために固定していること

`run_benchmark.sh` の主な役割はこれらを固定することです。崩すと比較が静かに無意味になります。

- **同じアーキテクチャ** — `--platform` を `uname -m` から固定。片方だけ QEMU エミュレーションで
  動くと、PHP と無関係な理由で壊滅的に遅くなります。
- **同じ `memory_limit`** — 公式イメージの既定は `128M`。揃えないと GC の圧力差が時間に混ざります。
- **同じ opcache 状態** — 基準系列は `-d opcache.enable_cli=0` を明示。ローカルの php.ini が
  `opcache.enable_cli=1` でも、`--runner native` の基準が Docker と同じになります。
- **同じ空回し回数** — 全系列に同じ `BENCH_WARMUP` を渡します。
- **状態を仮定せず検証する** — 上記のとおり実際の `opcache_get_status()` と突き合わせます。

---

## 9. 困ったとき

**`ERROR: docker が起動していません`**
Docker Desktop / Docker Engine を起動してください。入れられない場合は
`./run_benchmark.sh --runner native` でローカルの php 1 バージョンだけ計測できます。

**`ERROR: JIT が有効になっていません`**
その系列は JIT なしで回っていました。`opcache.jit_buffer_size` が 0 でないか、
PHP が 8.0 以降かを確認してください。7.x を `--jit` と一緒に指定した場合は
スキップされるだけでエラーにはなりません。

**`ERROR: series '8.5+jit' not found in benchmark.csv`**
その系列を含む掃引をまだ回していません。`--jit` を付けて `run_benchmark.sh` を実行してください。

**掃引が終わらない**
`array_merge` は 1 行あたり意図的に O(n²) で、大きい N では実行時間の大半を占めます。
これは仕様であって不具合ではありません。`--quick` か `BENCH_GRIDS` / `BENCH_METHODS` で絞ってください。

**PHP スクリプトを編集した**
`compare_array_function.php` は**すべてのバージョンでそのまま実行される**ので、
PHP 7.4 互換の構文を保つ必要があります (union 型 / `match` / 名前付き引数 / コンストラクタ昇格 /
`readonly` は不可)。7.4 での構文チェックが本当の確認です。

```sh
docker run --rm -v "$PWD":/app -w /app php:7.4-cli php -l compare_array_function.php
```
