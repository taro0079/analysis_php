# ============================================================
# temperature.gp
#
# 2D Heat Conduction Temperature Distribution
# ============================================================

set datafile separator ","

set terminal pngcairo size 1000,900 enhanced font "Arial,14"

set output "temperature.png"

set title "2D Heat Conduction - Temperature Distribution"

set xlabel "x"
set ylabel "y"

# 正方形として表示
set size ratio -1

# y軸方向を画像的な座標系にする場合
set yrange [] reverse

# カラーバー
set cblabel "Temperature"

# 温度レンジ
set cbrange [0:100]

# カラーパレット
set palette defined ( \
    0.0 "#000090", \
    0.25 "#000fff", \
    0.50 "#90ff70", \
    0.75 "#fff000", \
    1.0 "#ff0000" \
)

set view map

unset key

plot \
    "< awk -F, 'NF==3 && $1+0==$1 && $2+0==$2 && $3+0==$3 {print}' temperature.csv" \
    using 1:2:3 \
    with image