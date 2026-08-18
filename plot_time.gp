# ============================================================
# plot_time.gp
#
# 平均を取らない生の測定点をそのまま散布図にする。
# repeat ごとのばらつきを見るためのもの。
#
# 入力:
#   benchmark.csv
#
# 出力:
#   benchmark_time_<series>.png
#
# 使い方:
#   gnuplot plot_time.gp                      (CSV の先頭系列)
#   gnuplot -e "series='7.4'" plot_time.gp
# ============================================================

if (!exists("series")) {
    series = system("awk -F, 'NR>1{print $11; exit}' benchmark.csv")
}

set datafile separator ","

set terminal pngcairo size 1200,800

set output sprintf("benchmark_time_%s.png", series)

set title sprintf("PHP %s - 2D Heat Conduction Benchmark", series)

set xlabel "Grid size N"
set ylabel "Execution time [sec]"

set grid
set key left top noenhanced

# 11列目 (php_series) が対象系列の行だけを残す。
# 条件に合わない点は 1/0 (未定義) にして描画から外す。
#
# gnuplot の @マクロ展開は文字列"変数"にしか使えないため、
# using 式の中で series 変数を直接参照している。

plot \
    "benchmark.csv" \
        using (strcol(1) eq "for" && strcol(11) eq series ? $2 : 1/0):6 \
        with points pointtype 7 lc rgb "#8A2BE2" title "for", \
    "benchmark.csv" \
        using (strcol(1) eq "foreach" && strcol(11) eq series ? $2 : 1/0):6 \
        with points pointtype 5 lc rgb "#56B4E9" title "foreach", \
    "benchmark.csv" \
        using (strcol(1) eq "array_map" && strcol(11) eq series ? $2 : 1/0):6 \
        with points pointtype 9 lc rgb "#E6B800" title "array_map", \
    "benchmark.csv" \
        using (strcol(1) eq "array_merge" && strcol(11) eq series ? $2 : 1/0):6 \
        with points pointtype 11 lc rgb "#E41A1C" title "array_merge"
