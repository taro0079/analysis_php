#!/usr/bin/env bash
#
# PHP 7.4 / 8.5 ベンチマークランナー
#
# 同一のコンテナイメージ系列・同一のアーキテクチャ・同一の php.ini 設定で
# 両バージョンを走らせ、結果を1つの benchmark.csv にまとめる。
#
# 使い方:
#   ./run_benchmark.sh                 既定の全掃引 (時間がかかる)
#   ./run_benchmark.sh --quick         短い掃引で動作確認
#   ./run_benchmark.sh --jit           8.x の JIT 有効版も追加で計測 (系列 "8.5+jit")
#   ./run_benchmark.sh --opcache       opcache のみ有効な版も計測 (系列 "8.5+opcache")
#   ./run_benchmark.sh --jit --opcache JIT の効果を opcache の効果と分離して見る
#   ./run_benchmark.sh --jit --jit-mode tracing,function
#   ./run_benchmark.sh --versions 7.4,8.4,8.5
#   ./run_benchmark.sh --runner native ローカルの php をそのまま使う (バージョンは1つ)
#
# 環境変数での上書き:
#   BENCH_GRIDS BENCH_STEPS BENCH_REPEAT BENCH_METHODS  (compare_array_function.php 参照)
#   BENCH_MEMORY_LIMIT   php の memory_limit  (既定: 512M)
#   BENCH_WARMUP         計測前の空回し回数    (既定: 1)
#   BENCH_JIT_BUFFER     opcache.jit_buffer_size (既定: 64M)
#   BENCH_PLATFORM       docker --platform    (既定: ホストのアーキテクチャ)
#   CONTAINER_ENGINE     docker / podman      (既定: 自動検出)
#
# 系列名 (CSV 11列目 php_series / gnuplot 側のフィルタキー):
#   8.5              opcache も JIT も無効
#   8.5+opcache      opcache のみ有効
#   8.5+jit          opcache + トレーシング JIT
#   8.5+jit-function opcache + 関数 JIT

set -eu

# ------------------------------------------------------------------
# このスクリプトの位置を基準にする。
# どのディレクトリから呼ばれても動くようにするため。
# ------------------------------------------------------------------
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"

versions="7.4 8.5"
runner="docker"
with_jit=0
with_opcache=0
jit_modes="tracing"
quick=0

while [ $# -gt 0 ]; do
    case "$1" in
        --quick)    quick=1 ;;
        --jit)      with_jit=1 ;;
        --opcache)  with_opcache=1 ;;
        --jit-mode) shift; jit_modes=$(printf '%s' "$1" | tr ',' ' '); with_jit=1 ;;
        --versions) shift; versions=$(printf '%s' "$1" | tr ',' ' ') ;;
        --runner)   shift; runner="$1" ;;
        -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$quick" -eq 1 ]; then
    : "${BENCH_GRIDS:=20,40,80,120,160,200}"
    : "${BENCH_STEPS:=20}"
    : "${BENCH_REPEAT:=2}"
    export BENCH_GRIDS BENCH_STEPS BENCH_REPEAT
fi

memory_limit="${BENCH_MEMORY_LIMIT:-512M}"

# JIT が実際に有効になるかはこの値に依存する。
# 0 のままだと opcache.jit=tracing を渡しても JIT は動かない。
jit_buffer="${BENCH_JIT_BUFFER:-64M}"

# 計測前の空回し。
#
# トレーシング JIT は最初にホットループを踏んだ実行でトレースを
# コンパイルするため、その1回だけ極端に遅くなる。空回しがないと
# そのコンパイル時間が一番小さい格子の測定値に乗ってしまい、
# JIT 系列だけが不当に遅く見える。
#
# 全系列に同じ値を渡す。片方だけ空回しすると比較にならない。
: "${BENCH_WARMUP:=1}"
export BENCH_WARMUP

# 明示的に環境変数として渡すもの。未設定のものはコンテナに渡さない。
passthrough="BENCH_GRIDS BENCH_STEPS BENCH_REPEAT BENCH_WARMUP BENCH_METHODS BENCH_HEATMAP BENCH_HEATMAP_N BENCH_HEATMAP_STEPS"

# ------------------------------------------------------------------
# コンテナエンジンの検出
# ------------------------------------------------------------------
engine=""
if [ "$runner" = "docker" ]; then
    if [ -n "${CONTAINER_ENGINE:-}" ]; then
        engine="$CONTAINER_ENGINE"
    elif command -v docker >/dev/null 2>&1; then
        engine="docker"
    elif command -v podman >/dev/null 2>&1; then
        engine="podman"
    else
        cat >&2 <<'MSG'
ERROR: docker も podman も見つかりません。

  - Docker Desktop / Docker Engine / Podman のいずれかを入れてください。
  - あるいは ./run_benchmark.sh --runner native でローカルの php を使ってください
    (その場合はインストール済みの1バージョンしか計測できません)。
MSG
        exit 1
    fi

    if ! "$engine" info >/dev/null 2>&1; then
        echo "ERROR: $engine が起動していません。デーモンを起動してから再実行してください。" >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------
# プラットフォーム
#
# 7.4 と 8.5 が別アーキテクチャで動くと (片方だけ QEMU エミュレーション)
# 比較が無意味になるため、明示的に固定する。
# ------------------------------------------------------------------
detect_platform() {
    case "$(uname -m)" in
        arm64|aarch64) echo "linux/arm64" ;;
        x86_64|amd64)  echo "linux/amd64" ;;
        *)             echo "" ;;
    esac
}
platform="${BENCH_PLATFORM:-$(detect_platform)}"

# ------------------------------------------------------------------
# 1系列を実行する
#
#   run_series <系列名> <イメージ or native> <期待する状態> <追加のphp -d ...>
#
# 期待する状態 (BENCH_EXPECT) は plain / opcache / jit のいずれか。
# PHP 側が実際の opcache_get_status() と突き合わせ、
# 食い違っていたらそこで止まる。
# "8.5+jit" という名前の系列が実は JIT なしで回っていた、
# という取り違えは数値を見ても分からないため。
# ------------------------------------------------------------------
run_series() {
    series="$1"
    image="$2"
    expect="$3"
    shift 3

    out="benchmark_${series}.csv"

    echo ""
    echo "=================================================="
    echo " PHP ${series}  (expect: ${expect})  ->  ${out}"
    echo "=================================================="

    if [ "$runner" = "native" ]; then
        env BENCH_SERIES="$series" BENCH_OUT="$script_dir/$out" BENCH_EXPECT="$expect" \
            php -d memory_limit="$memory_limit" "$@" compare_array_function.php
        return
    fi

    set -- -d memory_limit="$memory_limit" "$@"

    env_args=""
    for name in $passthrough; do
        eval "value=\${$name:-}"
        if [ -n "$value" ]; then
            env_args="$env_args -e $name=$value"
        fi
    done

    platform_args=""
    if [ -n "$platform" ]; then
        platform_args="--platform $platform"
    fi

    # Linux では docker が root でファイルを作ってしまうため uid/gid を合わせる。
    # macOS / Windows の Docker Desktop では無害。
    user_args=""
    if [ "$(uname -s)" = "Linux" ]; then
        user_args="--user $(id -u):$(id -g)"
    fi

    # shellcheck disable=SC2086
    "$engine" run --rm \
        $platform_args $user_args $env_args \
        -e BENCH_SERIES="$series" \
        -e BENCH_OUT="/app/$out" \
        -e BENCH_EXPECT="$expect" \
        -v "$script_dir:/app" \
        -w /app \
        "$image" \
        php "$@" compare_array_function.php
}

# ------------------------------------------------------------------
# 1バージョンについて、要求された系列をすべて回す
#
#   run_version <バージョン> <イメージ or native>
#
# 基準系列は opcache を明示的に切る。
# ローカルの php.ini が opcache.enable_cli=1 になっている環境でも
# Docker の php:8.5-cli (既定で 0) と同じ条件になるようにするため。
#
# opcache 系列を挟むのは JIT の効果を分離するため。
# JIT は opcache の上でしか動かないので、
# "8.5" と "8.5+jit" だけを比べると opcache の効果まで JIT の手柄になる。
# ------------------------------------------------------------------
run_version() {
    v="$1"
    image="$2"

    run_series "$v" "$image" plain \
        -d opcache.enable_cli=0
    produced="$produced benchmark_${v}.csv"

    # JIT / opcache は PHP 8.0 以降 (かつ 7.4 の公式イメージには opcache がない)。
    case "$v" in
        [0-7].*)
            if [ "$with_opcache" -eq 1 ] || [ "$with_jit" -eq 1 ]; then
                echo "PHP $v には JIT がない (公式イメージには opcache も入っていない) ためスキップします。"
            fi
            return
            ;;
    esac

    if [ "$with_opcache" -eq 1 ]; then
        run_series "${v}+opcache" "$image" opcache \
            -d opcache.enable_cli=1 \
            -d opcache.jit=off \
            -d opcache.jit_buffer_size=0
        produced="$produced benchmark_${v}+opcache.csv"
    fi

    if [ "$with_jit" -eq 1 ]; then
        for mode in $jit_modes; do

            # tracing は既定なので従来どおり "+jit"。
            # それ以外は "+jit-function" のようにモード名を付ける。
            if [ "$mode" = "tracing" ]; then
                suffix="+jit"
            else
                suffix="+jit-${mode}"
            fi

            run_series "${v}${suffix}" "$image" jit \
                -d opcache.enable_cli=1 \
                -d opcache.jit="$mode" \
                -d opcache.jit_buffer_size="$jit_buffer"
            produced="$produced benchmark_${v}${suffix}.csv"

            hints="${hints}  gnuplot -e \"old='${v}'; new='${v}${suffix}'\" compare_versions.gp
"
            if [ "$with_opcache" -eq 1 ]; then
                hints="${hints}  gnuplot -e \"old='${v}+opcache'; new='${v}${suffix}'\" compare_versions.gp
"
            fi
        done
    fi
}

# ------------------------------------------------------------------
# 実行
# ------------------------------------------------------------------
produced=""

# 実行後に案内する gnuplot コマンド。
# 実際に回した系列だけを並べる。
hints=""

if [ "$runner" = "native" ]; then
    command -v php >/dev/null 2>&1 || { echo "ERROR: php が見つかりません。" >&2; exit 1; }
    series=$(php -r 'echo PHP_MAJOR_VERSION,".",PHP_MINOR_VERSION;')
    run_version "$series" native
else
    for v in $versions; do
        run_version "$v" "php:${v}-cli"
    done
fi

# ------------------------------------------------------------------
# 結合
#
# ヘッダは先頭ファイルの1行だけ残す。
# gnuplot 側はこの benchmark.csv を読む。
# ------------------------------------------------------------------
first=1
: > benchmark.csv
for f in $produced; do
    [ -f "$f" ] || continue
    if [ "$first" -eq 1 ]; then
        cat "$f" >> benchmark.csv
        first=0
    else
        tail -n +2 "$f" >> benchmark.csv
    fi
done

echo ""
echo "=================================================="
echo " benchmark.csv written ($(awk 'END{print NR-1}' benchmark.csv) rows)"
echo " series: $(awk -F, 'NR>1{print $11}' benchmark.csv | sort -u | tr '\n' ' ')"
echo "=================================================="
echo ""
echo "次のコマンドでグラフを作成します:"
echo "  gnuplot compare_versions.gp"
if [ -n "$hints" ]; then
    echo ""
    echo "JIT の比較はこちら (old / new は 11列目の系列名):"
    printf '%s' "$hints"
fi
