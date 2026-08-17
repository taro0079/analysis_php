set datafile separator ","

set terminal pngcairo size 1200,800
set output "benchmark_time.png"

set title "PHP 7.4 - 2D Heat Conduction Benchmark"

set xlabel "Grid size N"
set ylabel "Execution time [sec]"

set grid
set key left top

plot \
    "benchmark.csv" using (strcol(1) eq "for" ? $2 : 1/0):6 \
        with points pointtype 7 title "for", \
    "benchmark.csv" using (strcol(1) eq "foreach" ? $2 : 1/0):6 \
        with points pointtype 5 title "foreach", \
    "benchmark.csv" using (strcol(1) eq "array_map" ? $2 : 1/0):6 \
        with points pointtype 9 title "array_map", \
    "benchmark.csv" using (strcol(1) eq "array_merge" ? $2 : 1/0):6 \
        with points pointtype 11 title "array_merge"