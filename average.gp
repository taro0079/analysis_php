# ============================================================
# average.gp
#
# PHP 7.4 - 2D Heat Conduction Benchmark
#
# benchmark.csv の repeat 測定結果を N ごとに平均し、
#
#     t(N) = a * N^p
#
# でフィッティングする。
#
# 入力:
#   benchmark.csv
#
# 出力:
#   benchmark_average_fit.png
#
# 一時ファイル:
#   for_mean.dat
#   foreach_mean.dat
#   array_map_mean.dat
#   array_merge_mean.dat
# ============================================================


# ------------------------------------------------------------
# Output settings
# ------------------------------------------------------------

set terminal pngcairo size 1400,900 enhanced font "Arial,14"

set output "benchmark_average_fit.png"

set title "PHP 7.4 - 2D Heat Conduction Benchmark"

set xlabel "Grid size N"
set ylabel "Mean execution time [sec]"


# ------------------------------------------------------------
# Log scale
# ------------------------------------------------------------

set logscale x
set logscale y


# ------------------------------------------------------------
# Grid / legend
# ------------------------------------------------------------

set grid

set key left top


# ------------------------------------------------------------
# Plot styles
#
# 点とフィッティング曲線で同じ linestyle を使うことで
# 色を統一する。
# ------------------------------------------------------------

# for
set style line 1 \
    lc rgb "#8A2BE2" \
    pt 7 \
    ps 1.5 \
    lw 2.5

# foreach
set style line 2 \
    lc rgb "#56B4E9" \
    pt 5 \
    ps 1.5 \
    lw 2.5

# array_map
set style line 3 \
    lc rgb "#E6B800" \
    pt 9 \
    ps 1.5 \
    lw 2.5

# array_merge
set style line 4 \
    lc rgb "#E41A1C" \
    pt 11 \
    ps 1.5 \
    lw 2.5


# ============================================================
# benchmark.csv
#
# columns:
#
# 1  method
# 2  N
# 3  cells
# 4  steps
# 5  repeat
# 6  time_sec
# 7  time_per_step_ms
# 8  time_per_cell_ns
# 9  peak_memory_mb
# 10 center_temperature
#
# awk で
#
#     N time_sec
#
# の2列だけ取り出す。
#
# smooth unique により同じ N の値を平均化する。
# ============================================================


# ------------------------------------------------------------
# for
# ------------------------------------------------------------

set table "for_mean.dat"

plot \
    "< awk -F, 'NR>1 && $1==\"for\" {print $2,$6}' benchmark.csv" \
    using 1:2 \
    smooth unique

unset table


# ------------------------------------------------------------
# foreach
# ------------------------------------------------------------

set table "foreach_mean.dat"

plot \
    "< awk -F, 'NR>1 && $1==\"foreach\" {print $2,$6}' benchmark.csv" \
    using 1:2 \
    smooth unique

unset table


# ------------------------------------------------------------
# array_map
# ------------------------------------------------------------

set table "array_map_mean.dat"

plot \
    "< awk -F, 'NR>1 && $1==\"array_map\" {print $2,$6}' benchmark.csv" \
    using 1:2 \
    smooth unique

unset table


# ------------------------------------------------------------
# array_merge
# ------------------------------------------------------------

set table "array_merge_mean.dat"

plot \
    "< awk -F, 'NR>1 && $1==\"array_merge\" {print $2,$6}' benchmark.csv" \
    using 1:2 \
    smooth unique

unset table


# ============================================================
# Fitting
#
#     t(N) = a * N^p
#
# p がスケーリング指数。
#
# 通常の2D計算:
#     p ~ 2
#
# array_merge をループ内で繰り返す場合:
#     p > 2
#
# となることが期待される。
# ============================================================


# ------------------------------------------------------------
# for
# ------------------------------------------------------------

f_for(x) = a_for * x**p_for

a_for = 1.0e-5
p_for = 2.0

fit \
    f_for(x) \
    "for_mean.dat" \
    using 1:2 \
    via a_for,p_for


# ------------------------------------------------------------
# foreach
# ------------------------------------------------------------

f_foreach(x) = a_foreach * x**p_foreach

a_foreach = 1.0e-5
p_foreach = 2.0

fit \
    f_foreach(x) \
    "foreach_mean.dat" \
    using 1:2 \
    via a_foreach,p_foreach


# ------------------------------------------------------------
# array_map
# ------------------------------------------------------------

f_map(x) = a_map * x**p_map

a_map = 1.0e-5
p_map = 2.0

fit \
    f_map(x) \
    "array_map_mean.dat" \
    using 1:2 \
    via a_map,p_map


# ------------------------------------------------------------
# array_merge
# ------------------------------------------------------------

f_merge(x) = a_merge * x**p_merge

a_merge = 1.0e-5
p_merge = 3.0

fit \
    f_merge(x) \
    "array_merge_mean.dat" \
    using 1:2 \
    via a_merge,p_merge


# ============================================================
# Plot
#
# 同じ method の
#
#   測定点
#   fit曲線
#
# に同じ linestyle を使用。
# ============================================================

plot \
    \
    "for_mean.dat" \
        using 1:2 \
        with points ls 1 \
        title "for mean", \
    \
    f_for(x) \
        with lines ls 1 \
        title sprintf("for fit: p = %.3f", p_for), \
    \
    "foreach_mean.dat" \
        using 1:2 \
        with points ls 2 \
        title "foreach mean", \
    \
    f_foreach(x) \
        with lines ls 2 \
        title sprintf("foreach fit: p = %.3f", p_foreach), \
    \
    "array_map_mean.dat" \
        using 1:2 \
        with points ls 3 \
        title "array_map mean", \
    \
    f_map(x) \
        with lines ls 3 \
        title sprintf("array_map fit: p = %.3f", p_map), \
    \
    "array_merge_mean.dat" \
        using 1:2 \
        with points ls 4 \
        title "array_merge mean", \
    \
    f_merge(x) \
        with lines ls 4 \
        title sprintf("array_merge fit: p = %.3f", p_merge)


# ============================================================
# Console output
# ============================================================

print ""
print "============================================"
print "PHP 7.4 - 2D Heat Conduction Benchmark"
print "Scaling fit:"
print ""
print "    t(N) = a * N^p"
print "============================================"

print ""

print sprintf("for         : a = %.8e, p = %.6f",a_for,p_for)

print sprintf("foreach     : a = %.8e, p = %.6f",a_foreach,p_foreach)

print sprintf("array_map   : a = %.8e, p = %.6f",a_map,p_map)

print sprintf("array_merge : a = %.8e, p = %.6f",a_merge,p_merge)

print ""
print "============================================"

print sprintf("Output: benchmark_average_fit.png")

print ""