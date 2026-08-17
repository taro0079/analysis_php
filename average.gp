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
# 【重要】
# gnuplot の fit は既定で線形空間の残差
#
#     sum ( y - f(x) )^2
#
# を最小化する。
# y が 0.01 秒 〜 159 秒 と4桁以上にわたる本データでは
# 大きい N の点だけで重みが決まってしまい、
# log-log プロット上では「合っていない」線になる。
#
# そこで両対数をとった線形回帰
#
#     log(t) = log(a) + p * log(N)
#
# を行い、相対誤差を最小化する。
# これが log-log プロット上で見た目と一致するフィットになる。
# ============================================================


# ------------------------------------------------------------
# for
# ------------------------------------------------------------

g_for(lx) = la_for + p_for * lx

la_for = log(1.0e-5)
p_for  = 2.0

fit \
    g_for(x) \
    "for_mean.dat" \
    using (log($1)):(log($2)) \
    via la_for,p_for

a_for = exp(la_for)

f_for(x) = a_for * x**p_for


# ------------------------------------------------------------
# foreach
# ------------------------------------------------------------

g_foreach(lx) = la_foreach + p_foreach * lx

la_foreach = log(1.0e-5)
p_foreach  = 2.0

fit \
    g_foreach(x) \
    "foreach_mean.dat" \
    using (log($1)):(log($2)) \
    via la_foreach,p_foreach

a_foreach = exp(la_foreach)

f_foreach(x) = a_foreach * x**p_foreach


# ------------------------------------------------------------
# array_map
# ------------------------------------------------------------

g_map(lx) = la_map + p_map * lx

la_map = log(1.0e-5)
p_map  = 2.0

fit \
    g_map(x) \
    "array_map_mean.dat" \
    using (log($1)):(log($2)) \
    via la_map,p_map

a_map = exp(la_map)

f_map(x) = a_map * x**p_map


# ------------------------------------------------------------
# array_merge
#
# array_merge は単一のべき乗則ではない。
# 局所指数は
#
#     N=20-40   : p ~ 1.97
#     N=80-120  : p ~ 2.41
#     N=200-500 : p ~ 2.53
#
# と N とともに増大する。
# さらに N=600, 800 は測定ノイズが大きい。
#
# したがって以下の p は
# 「測定範囲全体をならした実効スケーリング指数」
# であって、漸近的な理論指数ではない。
# ------------------------------------------------------------

g_merge(lx) = la_merge + p_merge * lx

la_merge = log(1.0e-5)
p_merge  = 2.5

fit \
    g_merge(x) \
    "array_merge_mean.dat" \
    using (log($1)):(log($2)) \
    via la_merge,p_merge

a_merge = exp(la_merge)

f_merge(x) = a_merge * x**p_merge


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