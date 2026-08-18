<?php

/**
 * 2D Heat Conduction Benchmark
 *
 * PHP 7.4 と 8.5 を同一条件で比較するためのベンチマーク。
 * 構文は PHP 7.4 互換に保つこと。
 *
 * Explicit finite difference method.
 *
 * 実行:
 *   php compare_array_function.php
 *   ./run_benchmark.sh            (7.4 / 8.5 を Docker で連続実行)
 *
 * 環境変数:
 *   BENCH_OUT       出力CSVパス          (既定: benchmark_<series>.csv)
 *   BENCH_GRIDS     格子サイズのカンマ区切り (既定: 20,40,80,120,160,200,500,600,800,1000)
 *   BENCH_STEPS     時間ステップ数        (既定: 100)
 *   BENCH_REPEAT    繰り返し回数          (既定: 3)
 *   BENCH_METHODS   計測対象のカンマ区切り (既定: for,foreach,array_map,array_merge)
 *   BENCH_HEATMAP   1 なら temperature.csv も出力 (既定: 0)
 *   BENCH_SERIES    CSV/凡例に使う系列名   (既定: 7.4 / 8.5 などのMAJOR.MINOR)
 *   BENCH_LABEL     CSV に記録する実行ラベル (既定: PHP_VERSION)
 *
 * 出力:
 *   benchmark_<series>.csv
 *   temperature.csv  (BENCH_HEATMAP=1 のときのみ)
 */

/*
 * --------------------------------------------------
 * 環境変数ヘルパ
 * --------------------------------------------------
 */
function envString(string $name, string $default): string
{
    $value = getenv($name);

    if ($value === false || $value === '') {
        return $default;
    }

    return $value;
}

function envInt(string $name, int $default): int
{
    $value = getenv($name);

    if ($value === false || $value === '') {
        return $default;
    }

    return (int)$value;
}

function envIntList(string $name, array $default): array
{
    $value = getenv($name);

    if ($value === false || $value === '') {
        return $default;
    }

    $list = [];

    foreach (explode(',', $value) as $item) {

        $item = trim($item);

        if ($item === '') {
            continue;
        }

        $list[] = (int)$item;
    }

    return $list === [] ? $default : $list;
}

function envStringList(string $name, array $default): array
{
    $value = getenv($name);

    if ($value === false || $value === '') {
        return $default;
    }

    $list = [];

    foreach (explode(',', $value) as $item) {

        $item = trim($item);

        if ($item === '') {
            continue;
        }

        $list[] = $item;
    }

    return $list === [] ? $default : $list;
}

/*
 * fputcsv のラッパ。
 *
 * PHP 8.4 以降は $escape 既定値の使用が deprecated になり
 * 実行時に Deprecated 通知が出る。
 * 空文字は PHP 7.4 以降で受け付けられるため、
 * 明示的に "" を渡して 7.4 / 8.5 双方で無警告にする。
 */
function csvRow($handle, array $row): void
{
    fputcsv($handle, $row, ',', '"', '');
}


/*
 * --------------------------------------------------
 * 実行中の PHP を識別する値
 * --------------------------------------------------
 *
 * series は "7.4" / "8.5" のようなマイナーまでの系列。
 * gnuplot 側のフィルタキーとして使う。
 */
$phpSeries = envString(
    'BENCH_SERIES',
    PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION
);

$phpVersion = envString('BENCH_LABEL', PHP_VERSION);


/*
 * --------------------------------------------------
 * 物理パラメータ
 * --------------------------------------------------
 */
$alpha = 1.0;
$dx = 1.0;
$dy = 1.0;
$dt = 0.1;

$rx = $alpha * $dt / ($dx * $dx);
$ry = $alpha * $dt / ($dy * $dy);

/*
 * 2次元陽解法の安定条件
 *
 * rx + ry <= 1/2
 */
if (($rx + $ry) > 0.5) {
    die("ERROR: unstable condition\n");
}

/*
 * NxN 格子
 *
 * array_merge は非常に遅くなるので、
 * 短時間で回したいときは BENCH_GRIDS で絞る。
 */
$gridSizes = envIntList(
    'BENCH_GRIDS',
    [
        20,
        40,
        80,
        120,
        160,
        200,
        500,
        600,
        800,
        1000
    ]
);

$steps = envInt('BENCH_STEPS', 100);

$repeat = envInt('BENCH_REPEAT', 3);


/*
 * --------------------------------------------------
 * 初期温度
 * --------------------------------------------------
 *
 * 上端 = 100℃
 * その他の境界 = 0℃
 * 内部 = 0℃
 */
function createTemperature(int $n): array
{
    $temperature = [];

    for ($y = 0; $y < $n; $y++) {

        $row = array_fill(0, $n, 0.0);

        if ($y === 0) {
            $row = array_fill(0, $n, 100.0);
        }

        $temperature[] = $row;
    }

    return $temperature;
}


/*
 * --------------------------------------------------
 * 方法1
 * 普通の二重 for
 * --------------------------------------------------
 */
function simulationFor(
    array $temperature,
    int $steps,
    float $rx,
    float $ry
): array {

    $n = count($temperature);

    for ($step = 0; $step < $steps; $step++) {

        $next = $temperature;

        for ($y = 1; $y < $n - 1; $y++) {

            for ($x = 1; $x < $n - 1; $x++) {

                $center = $temperature[$y][$x];

                $next[$y][$x] =
                    $center
                    + $rx * (
                        $temperature[$y][$x + 1]
                        - 2.0 * $center
                        + $temperature[$y][$x - 1]
                    )
                    + $ry * (
                        $temperature[$y + 1][$x]
                        - 2.0 * $center
                        + $temperature[$y - 1][$x]
                    );
            }
        }

        $temperature = $next;
    }

    return $temperature;
}


/*
 * --------------------------------------------------
 * 方法2
 * foreach
 * --------------------------------------------------
 */
function simulationForeach(
    array $temperature,
    int $steps,
    float $rx,
    float $ry
): array {

    $n = count($temperature);

    for ($step = 0; $step < $steps; $step++) {

        $next = $temperature;

        foreach ($temperature as $y => $row) {

            if ($y === 0 || $y === $n - 1) {
                continue;
            }

            foreach ($row as $x => $center) {

                if ($x === 0 || $x === $n - 1) {
                    continue;
                }

                $next[$y][$x] =
                    $center
                    + $rx * (
                        $temperature[$y][$x + 1]
                        - 2.0 * $center
                        + $temperature[$y][$x - 1]
                    )
                    + $ry * (
                        $temperature[$y + 1][$x]
                        - 2.0 * $center
                        + $temperature[$y - 1][$x]
                    );
            }
        }

        $temperature = $next;
    }

    return $temperature;
}


/*
 * --------------------------------------------------
 * 方法3
 * array_map
 * --------------------------------------------------
 */
function simulationArrayMap(
    array $temperature,
    int $steps,
    float $rx,
    float $ry
): array {

    $n = count($temperature);

    for ($step = 0; $step < $steps; $step++) {

        $old = $temperature;

        $temperature = array_map(
            function ($row, $y) use ($old, $n, $rx, $ry) {

                if ($y === 0 || $y === $n - 1) {
                    return $row;
                }

                $indexes = range(0, $n - 1);

                return array_map(
                    function ($center, $x) use (
                        $old,
                        $y,
                        $n,
                        $rx,
                        $ry
                    ) {

                        if ($x === 0 || $x === $n - 1) {
                            return $center;
                        }

                        return
                            $center
                            + $rx * (
                                $old[$y][$x + 1]
                                - 2.0 * $center
                                + $old[$y][$x - 1]
                            )
                            + $ry * (
                                $old[$y + 1][$x]
                                - 2.0 * $center
                                + $old[$y - 1][$x]
                            );

                    },
                    $row,
                    $indexes
                );

            },
            $temperature,
            range(0, $n - 1)
        );
    }

    return $temperature;
}


/*
 * --------------------------------------------------
 * 方法4
 *
 * array_merge を意図的に悪く使う
 * --------------------------------------------------
 */
function simulationArrayMerge(
    array $temperature,
    int $steps,
    float $rx,
    float $ry
): array {

    $n = count($temperature);

    for ($step = 0; $step < $steps; $step++) {

        $next = [];

        for ($y = 0; $y < $n; $y++) {

            $newRow = [];

            for ($x = 0; $x < $n; $x++) {

                /*
                 * 境界
                 */
                if (
                    $y === 0 ||
                    $y === $n - 1 ||
                    $x === 0 ||
                    $x === $n - 1
                ) {

                    $value = $temperature[$y][$x];

                } else {

                    $center = $temperature[$y][$x];

                    $value =
                        $center
                        + $rx * (
                            $temperature[$y][$x + 1]
                            - 2.0 * $center
                            + $temperature[$y][$x - 1]
                        )
                        + $ry * (
                            $temperature[$y + 1][$x]
                            - 2.0 * $center
                            + $temperature[$y - 1][$x]
                        );
                }

                /*
                 * わざと非効率。
                 *
                 * 1セル追加するたびに
                 * 配列をmergeする。
                 */
                $newRow = array_merge(
                    $newRow,
                    [$value]
                );
            }

            $next = array_merge(
                $next,
                [$newRow]
            );
        }

        $temperature = $next;
    }

    return $temperature;
}


/*
 * --------------------------------------------------
 * ベンチマーク
 * --------------------------------------------------
 */
function benchmark(
    callable $function,
    int $gridSize,
    int $steps,
    float $rx,
    float $ry
): array {

    gc_collect_cycles();

    $temperature = createTemperature($gridSize);

    $memoryBefore = memory_get_usage(true);

    $start = microtime(true);

    $result = $function(
        $temperature,
        $steps,
        $rx,
        $ry
    );

    $elapsed = microtime(true) - $start;

    $memoryAfter = memory_get_usage(true);

    $center =
        $result[
            (int)($gridSize / 2)
        ][
            (int)($gridSize / 2)
        ];

    return [
        'time' => $elapsed,

        /*
         * 単純差分なので参考値。
         * peak memoryは別途記録する。
         */
        'memory_delta' =>
            $memoryAfter - $memoryBefore,

        'peak_memory' =>
            memory_get_peak_usage(true),

        'center' => $center,
    ];
}


/*
 * --------------------------------------------------
 * 測定対象
 * --------------------------------------------------
 */
$allMethods = [

    'for' => 'simulationFor',

    'foreach' => 'simulationForeach',

    'array_map' => 'simulationArrayMap',

    'array_merge' => 'simulationArrayMerge',
];

$selected = envStringList(
    'BENCH_METHODS',
    array_keys($allMethods)
);

$methods = [];

foreach ($selected as $name) {

    if (!isset($allMethods[$name])) {
        die("ERROR: unknown method '{$name}'\n");
    }

    $methods[$name] = $allMethods[$name];
}


/*
 * --------------------------------------------------
 * CSV
 * --------------------------------------------------
 *
 * 既定の出力先はバージョン系列ごとに分ける。
 * こうしないと 7.4 の結果を 8.5 が上書きしてしまう。
 */
$csvPath = envString(
    'BENCH_OUT',
    __DIR__ . '/benchmark_' . $phpSeries . '.csv'
);

$csv = fopen($csvPath, 'w');

if ($csv === false) {
    die("Cannot open {$csvPath}\n");
}


/*
 * CSV Header
 *
 * 【重要】
 * gnuplot 側は列番号で参照している。
 * 列の追加・並べ替えをしたら
 * average.gp / compare_versions.gp / plot_time.gp を
 * 必ず同時に更新すること。
 */
csvRow(
    $csv,
    [
        'method',
        'N',
        'cells',
        'steps',
        'repeat',
        'time_sec',
        'time_per_step_ms',
        'time_per_cell_ns',
        'peak_memory_mb',
        'center_temperature',
        'php_series',
        'php_version',
    ]
);


/*
 * --------------------------------------------------
 * 実行
 * --------------------------------------------------
 */

echo "PHP Version: " . PHP_VERSION . " (series {$phpSeries})" . PHP_EOL;

echo "Label: " . $phpVersion . PHP_EOL;

echo sprintf(
    "rx = %.4f, ry = %.4f\n",
    $rx,
    $ry
);

echo sprintf(
    "grids = %s\n",
    implode(',', $gridSizes)
);

echo sprintf(
    "methods = %s\n",
    implode(',', array_keys($methods))
);

echo sprintf(
    "steps = %d, repeat = %d\n\n",
    $steps,
    $repeat
);

printf(
    "%-14s %7s %12s %12s %12s\n",
    'method',
    'N',
    'cells',
    'time(sec)',
    'center'
);

echo str_repeat('-', 65) . PHP_EOL;


foreach ($gridSizes as $n) {

    foreach ($methods as $methodName => $functionName) {

        for ($r = 1; $r <= $repeat; $r++) {

            $result = benchmark(
                $functionName,
                $n,
                $steps,
                $rx,
                $ry
            );

            $cells = $n * $n;

            $timePerStepMs =
                $result['time']
                / $steps
                * 1000.0;

            /*
             * 実際に更新する内部セル数
             */
            $updatedCells =
                ($n - 2)
                * ($n - 2)
                * $steps;

            $timePerCellNs =
                $result['time']
                / $updatedCells
                * 1.0e9;

            $peakMemoryMb =
                $result['peak_memory']
                / 1024.0
                / 1024.0;

            printf(
                "%-14s %7d %12d %12.6f %12.6f\n",
                $methodName,
                $n,
                $cells,
                $result['time'],
                $result['center']
            );

            csvRow(
                $csv,
                [
                    $methodName,
                    $n,
                    $cells,
                    $steps,
                    $r,
                    $result['time'],
                    $timePerStepMs,
                    $timePerCellNs,
                    $peakMemoryMb,
                    $result['center'],
                    $phpSeries,
                    $phpVersion,
                ]
            );
        }
    }

    echo PHP_EOL;
}

fclose($csv);

echo PHP_EOL;
echo basename($csvPath) . " written." . PHP_EOL;


/*
 * ============================================================
 * Heat conduction result
 *
 * 最終温度場を gnuplot 用 CSV に出力。
 *
 * これは物理計算であってベンチマークではなく、
 * どのバージョンで計算しても同じ結果になる。
 * 7.4 / 8.5 を続けて回すときに二重計算しないよう、
 * 既定では無効。BENCH_HEATMAP=1 で有効化する。
 * ============================================================
 */

if (envInt('BENCH_HEATMAP', 0) !== 1) {

    echo "Skipping temperature field (set BENCH_HEATMAP=1 to enable)." . PHP_EOL;

    exit(0);
}

$heatGridSize = envInt('BENCH_HEATMAP_N', 200);
$heatSteps = envInt('BENCH_HEATMAP_STEPS', 1000);

echo PHP_EOL;
echo "Calculating temperature field..." . PHP_EOL;
echo "Grid: {$heatGridSize} x {$heatGridSize}" . PHP_EOL;
echo "Steps: {$heatSteps}" . PHP_EOL;

$initialTemperature = createTemperature($heatGridSize);

$temperatureResult = simulationFor(
    $initialTemperature,
    $heatSteps,
    $rx,
    $ry
);


/*
 * gnuplot 用CSV
 *
 * x,y,temperature
 *
 * 各y行の最後に空行を入れる。
 * pm3d / image で扱いやすくなる。
 */
$temperatureCsv = fopen(
    __DIR__ . '/temperature.csv',
    'w'
);

if ($temperatureCsv === false) {
    die("Cannot open temperature.csv\n");
}

csvRow(
    $temperatureCsv,
    [
        'x',
        'y',
        'temperature'
    ]
);

for ($y = 0; $y < $heatGridSize; $y++) {

    for ($x = 0; $x < $heatGridSize; $x++) {

        csvRow(
            $temperatureCsv,
            [
                $x,
                $y,
                $temperatureResult[$y][$x]
            ]
        );
    }

    /*
     * gnuplot が格子の行境界を認識できるように
     * 空行を挿入
     */
    fwrite(
        $temperatureCsv,
        PHP_EOL
    );
}

fclose($temperatureCsv);

echo "temperature.csv written." . PHP_EOL;
