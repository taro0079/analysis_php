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
#   ./run_benchmark.sh --jit           8.5 の JIT 有効版も追加で計測
#   ./run_benchmark.sh --versions 7.4,8.4,8.5
#   ./run_benchmark.sh --runner native ローカルの php をそのまま使う (1系列のみ)
#
# 環境変数での上書き:
#   BENCH_GRIDS BENCH_STEPS BENCH_REPEAT BENCH_METHODS  (compare_array_function.php 参照)
#   BENCH_MEMORY_LIMIT   php の memory_limit  (既定: 512M)
#   BENCH_PLATFORM       docker --platform    (既定: ホストのアーキテクチャ)
#   CONTAINER_ENGINE     docker / podman      (既定: 自動検出)

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
quick=0

while [ $# -gt 0 ]; do
    case "$1" in
        --quick)    quick=1 ;;
        --jit)      with_jit=1 ;;
        --versions) shift; versions=$(printf '%s' "$1" | tr ',' ' ') ;;
        --runner)   shift; runner="$1" ;;
        -h|--help)  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# 明示的に環境変数として渡すもの。未設定のものはコンテナに渡さない。
passthrough="BENCH_GRIDS BENCH_STEPS BENCH_REPEAT BENCH_METHODS BENCH_HEATMAP BENCH_HEATMAP_N BENCH_HEATMAP_STEPS"

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
#   run_series <系列名> <イメージ or native> <追加のphp -d ...>
# ------------------------------------------------------------------
run_series() {
    series="$1"
    image="$2"
    shift 2

    out="benchmark_${series}.csv"

    echo ""
    echo "=================================================="
    echo " PHP ${series}  ->  ${out}"
    echo "=================================================="

    if [ "$runner" = "native" ]; then
        env BENCH_SERIES="$series" BENCH_OUT="$script_dir/$out" \
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
        -v "$script_dir:/app" \
        -w /app \
        "$image" \
        php "$@" compare_array_function.php
}

# ------------------------------------------------------------------
# 実行
# ------------------------------------------------------------------
produced=""

if [ "$runner" = "native" ]; then
    command -v php >/dev/null 2>&1 || { echo "ERROR: php が見つかりません。" >&2; exit 1; }
    series=$(php -r 'echo PHP_MAJOR_VERSION,".",PHP_MINOR_VERSION;')
    run_series "$series" native
    produced="benchmark_${series}.csv"
else
    for v in $versions; do
        run_series "$v" "php:${v}-cli"
        produced="$produced benchmark_${v}.csv"
    done

    if [ "$with_jit" -eq 1 ]; then
        for v in $versions; do
            # JIT は PHP 8.0 以降。7.x には存在しないので飛ばす。
            case "$v" in
                7.*) echo "PHP $v には JIT がないためスキップします。" ; continue ;;
            esac
            run_series "${v}+jit" "php:${v}-cli" \
                -d opcache.enable_cli=1 \
                -d opcache.jit=tracing \
                -d opcache.jit_buffer_size=64M
            produced="$produced benchmark_${v}+jit.csv"
        done
    fi
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
