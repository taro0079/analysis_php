# ============================================================
# compare_versions.gp
#
# PHP バージョン間比較
#
#   上段: 平均実行時間 t(N)  (log-log, 両バージョン重ね描き)
#   下段: 高速化率 t_old(N) / t_new(N)
#
# 入力:
#   benchmark.csv   (run_benchmark.sh が生成した結合済みCSV)
#
# 出力:
#   benchmark_compare_<old>_vs_<new>.png
#
# 使い方:
#   gnuplot compare_versions.gp
#   gnuplot -e "old='7.4'; new='8.5'" compare_versions.gp
#   gnuplot -e "new='8.5+jit'" compare_versions.gp
#
# 一時ファイル:
#   mean_<method>_<series>.dat
# ============================================================


# ------------------------------------------------------------
# 比較対象の系列
#
# benchmark.csv の 11列目 (php_series) の値を指定する。
# ------------------------------------------------------------

if (!exists("old")) { old = "7.4" }
if (!exists("new")) { new = "8.5" }


# ------------------------------------------------------------
# 入力チェック
#
# 系列が入っていない CSV に対して黙って空のグラフを出すと
# 事故に気付けないので、ここで止める。
# ------------------------------------------------------------

count_rows(s) = \
    real(system(sprintf( \
        "awk -F, 'NR>1 && $11==\"%s\" {n++} END{print n+0}' benchmark.csv", s)))

if (count_rows(old) == 0) {
    print sprintf("ERROR: series '%s' not found in benchmark.csv", old)
    print "       ./run_benchmark.sh を実行してください。"
    exit
}

if (count_rows(new) == 0) {
    print sprintf("ERROR: series '%s' not found in benchmark.csv", new)
    print "       ./run_benchmark.sh を実行してください。"
    exit
}


# ============================================================
# N ごとの平均を取る
#
# benchmark.csv columns:
#
#  1 method   2 N       3 cells     4 steps    5 repeat  6 time_sec
#  7 time_per_step_ms   8 time_per_cell_ns     9 peak_memory_mb
# 10 center_temperature 11 php_series          12 php_version
#
# awk で (N, time_sec) の2列に落とし、
# smooth unique で同じ N の repeat を平均する。
# ============================================================

methods = "for foreach array_map array_merge"

meanfile(m, s) = sprintf("mean_%s_%s.dat", m, s)

extract(m, s) = sprintf( \
    "< awk -F, 'NR>1 && $1==\"%s\" && $11==\"%s\" {print $2,$6}' benchmark.csv", \
    m, s)

set table
do for [m in methods] {
    do for [s in old.' '.new] {
        set table meanfile(m, s)
        plot extract(m, s) using 1:2 smooth unique
    }
}
unset table


# ------------------------------------------------------------
# 高速化率
#
#   speedup(N) = t_old(N) / t_new(N)
#
# 2つの mean ファイルを awk で N をキーに突き合わせる。
# paste ではなく awk にしているのは、
# set table 出力の先頭コメント行数に依存しないようにするため。
# ------------------------------------------------------------

ratio(m) = sprintf( \
    "< awk 'NR==FNR{if(NF>=2 && $1+0==$1) a[$1]=$2; next} \
     NF>=2 && $1+0==$1 && ($1 in a){print $1, a[$1]/$2}' %s %s", \
    meanfile(m, old), meanfile(m, new))


# ============================================================
# 描画設定
# ============================================================

set terminal pngcairo size 1400,1100 enhanced font "Arial,13"

set output sprintf("benchmark_compare_%s_vs_%s.png", old, new)


# ------------------------------------------------------------
# 色は method ごと、線種は version ごと。
#
#   old : 破線 + 白抜き点
#   new : 実線 + 塗り点
# ------------------------------------------------------------

c_for     = "#8A2BE2"
c_foreach = "#56B4E9"
c_map     = "#E6B800"
c_merge   = "#E41A1C"

color(m) = \
    m eq "for"       ? c_for : \
    m eq "foreach"   ? c_foreach : \
    m eq "array_map" ? c_map : c_merge

# 白抜き / 塗りつぶしの対になる点種
pt_open(m) = \
    m eq "for"       ? 6 : \
    m eq "foreach"   ? 4 : \
    m eq "array_map" ? 8 : 10

pt_fill(m) = pt_open(m) + 1


set grid

# 凡例の "array_map" などの _ が下付き文字に化けるのを防ぐ。
set key noenhanced


# ============================================================
# Multiplot
# ============================================================

set multiplot layout 2,1 \
    title sprintf("2D Heat Conduction Benchmark - PHP %s vs %s", old, new) \
    font "Arial,17"


# ------------------------------------------------------------
# 上段: 実行時間
# ------------------------------------------------------------

set tmargin 2
set bmargin 3
set lmargin 12
set rmargin 18

set logscale x
set logscale y

set xlabel "Grid size N"
set ylabel "Mean execution time [sec]"

set key outside right top samplen 2 spacing 1.1 font "Arial,11"

plot \
    for [m in methods] meanfile(m, old) using 1:2 \
        with linespoints lc rgb color(m) pt pt_open(m) ps 1.4 lw 2 dt 2 \
        title sprintf("%s (%s)", m, old), \
    for [m in methods] meanfile(m, new) using 1:2 \
        with linespoints lc rgb color(m) pt pt_fill(m) ps 1.4 lw 2 dt 1 \
        title sprintf("%s (%s)", m, new)


# ------------------------------------------------------------
# 下段: 高速化率
#
# 1.0 の水平線より上なら new のほうが速い。
# ------------------------------------------------------------

unset logscale y

set ylabel sprintf("Speedup  t(%s) / t(%s)", old, new)
set xlabel "Grid size N"

# 比は 1.0 前後に集まるので 0 起点にはせず自動スケールにする。
# 基準の 1.0 は下の水平線で示す。
set autoscale y

set key outside right top samplen 2 spacing 1.1 font "Arial,11"

set arrow 1 from graph 0, first 1.0 to graph 1, first 1.0 \
    nohead lc rgb "#888888" lw 2 dt 3 front

set label 1 "equal speed" at graph 0.01, first 1.0 offset 0,0.7 \
    tc rgb "#888888" font "Arial,10" front

plot \
    for [m in methods] ratio(m) using 1:2 \
        with linespoints lc rgb color(m) pt pt_fill(m) ps 1.4 lw 2.5 \
        title m

unset multiplot

unset output


# ============================================================
# Console output
#
# 各 method の平均高速化率 (幾何平均) を表示する。
# 幾何平均を使うのは比の平均だから。
# ============================================================

geomean(m) = \
    real(system(sprintf( \
        "awk 'NR==FNR{if(NF>=2 && $1+0==$1) a[$1]=$2; next} \
         NF>=2 && $1+0==$1 && ($1 in a){s+=log(a[$1]/$2); n++} \
         END{if(n) printf \"%%.6f\", exp(s/n); else print 0}' %s %s", \
        meanfile(m, old), meanfile(m, new))))

print ""
print "============================================"
print sprintf("PHP %s -> %s  speedup (geometric mean)", old, new)
print "============================================"
print ""

do for [m in methods] {
    print sprintf("  %-12s : %.2fx", m, geomean(m))
}

print ""
print sprintf("Output: benchmark_compare_%s_vs_%s.png", old, new)
print ""
