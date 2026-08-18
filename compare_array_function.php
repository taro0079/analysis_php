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
 *   ./run_benchmark.sh --jit      (8.x の JIT 有効版も計測)
 *
 * 環境変数:
 *   BENCH_OUT       出力CSVパス          (既定: benchmark_<series>.csv)
 *   BENCH_GRIDS     格子サイズのカンマ区切り (既定: 20,40,80,120,160,200,500,600,800,1000)
 *   BENCH_STEPS     時間ステップ数        (既定: 100)
 *   BENCH_REPEAT    繰り返し回数          (既定: 3)
 *   BENCH_WARMUP    計測前の空回し回数      (既定: 0 / JIT 比較時は 1 以上を推奨)
 *   BENCH_METHODS   計測対象のカンマ区切り (既定: for,foreach,array_map,array_merge)
 *   BENCH_HEATMAP   1 なら temperature.csv も出力 (既定: 0)
 *   BENCH_SERIES    CSV/凡例に使う系列名   (既定: 7.4 / 8.5 などのMAJOR.MINOR)
 *   BENCH_LABEL     CSV に記録する実行ラベル (既定: PHP_VERSION)
 *   BENCH_EXPECT    plain / opcache / jit  期待する高速化状態の検証 (既定: 検証しない)
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
 * 実行中のアクセラレータ状態を調べる
 * --------------------------------------------------
 *
 * opcache は 'on' / 'off'。
 * jit は 'off' か opcache.jit の値そのもの ('tracing' / 'function' / '1254' など)。
 *
 * PHP 7.4 の公式イメージには opcache が入っていないため
 * opcache_get_status() の存在確認から始める。
 * JIT は 8.0 以降にしかないので 'jit' キーの有無も見る。
 *
 * ここで測るのは ini の設定値ではなく実際に有効になったかどうか。
 * jit_buffer_size が 0 のままだと opcache.jit=tracing を渡しても
 * JIT は動かず、設定だけ見ていると気付けない。
 */
function accelStatus(): array
{
    $status = [
        'opcache' => 'off',
        'jit' => 'off',
    ];

    if (!function_exists('opcache_get_status')) {
        return $status;
    }

    $info = @opcache_get_status(false);

    if (!is_array($info)) {
        return $status;
    }

    if (!empty($info['opcache_enabled'])) {
        $status['opcache'] = 'on';
    }

    if (isset($info['jit']) && !empty($info['jit']['on'])) {

        $mode = trim((string)ini_get('opcache.jit'));

        $status['jit'] = $mode === '' ? 'on' : $mode;
    }

    return $status;
}


/*
 * 期待した状態で動いているかを確認する。
 *
 * BENCH_EXPECT:
 *   plain    opcache も JIT も無効であること
 *   opcache  opcache は有効・JIT は無効であること
 *   jit      JIT が有効であること
 *   (未設定) 何も確認しない
 *
 * 系列名が "8.5+jit" なのに実際は JIT が動いていない、
 * という取り違えは数値を見ても分からないのでここで止める。
 */
function assertAccel(string $expect, array $status): void
{
    if ($expect === '') {
        return;
    }

    $actual = sprintf(
        'opcache=%s jit=%s',
        $status['opcache'],
        $status['jit']
    );

    $message = '';

    if ($expect === 'plain') {

        if ($status['opcache'] !== 'off' || $status['jit'] !== 'off') {
            $message = "opcache/JIT なしで計測するはずが有効になっています ({$actual})";
        }

    } elseif ($expect === 'opcache') {

        if ($status['opcache'] !== 'on') {
            $message = "opcache が有効になっていません ({$actual})";
        } elseif ($status['jit'] !== 'off') {
            $message = "opcache のみで計測するはずが JIT も有効です ({$actual})";
        }

    } elseif ($expect === 'jit') {

        if ($status['jit'] === 'off') {
            $message =
                "JIT が有効になっていません ({$actual})\n"
                . "       opcache.enable_cli=1 / opcache.jit / "
                . "opcache.jit_buffer_size を確認してください。\n"
                . "       jit_buffer_size が 0 だと opcache.jit=tracing でも JIT は動きません。\n"
                . "       PHP 8.0 未満には JIT がありません。";
        }

    } else {
        $message = "unknown BENCH_EXPECT '{$expect}'";
    }

    if ($message === '') {
        return;
    }

    /*
     * die() は終了コード 0 で抜けるため、
     * 呼び出し側の set -e が反応せず計測が続いてしまう。
     * ここは必ず 1 で落とす。
     */
    fwrite(STDERR, "ERROR: " . $message . "\n");

    exit(1);
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
 * opcache / JIT の実際の状態。
 * CSV に残しておかないと、あとから
 * その系列が本当に JIT 有効だったのか確認できない。
 */
$accel = accelStatus();

assertAccel(envString('BENCH_EXPECT', ''), $accel);


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
 * 計測前の空回し回数。
 *
 * JIT を比べるときだけ効いてくる。
 * トレーシング JIT は最初にホットループを踏んだ実行で
 * トレースをコンパイルするので、その1回だけ極端に遅くなる。
 * 実測では N=20 の repeat=1 が repeat=2 の約10倍かかっていた。
 * 空回ししておかないと、この JIT のコンパイル時間が
 * 一番小さい格子の測定値に丸ごと乗って
 * 「JIT のほうが遅い」という誤った結論になる。
 *
 * 空回しは全 method について最初にまとめて行う。
 * 掃引が格子サイズ外側・method 内側で回るため、
 * 各 method の最初の測定より前に済ませる必要がある。
 */
$warmup = envInt('BENCH_WARMUP', 0);

/*
 * 空回しの格子とステップ数。
 * トレーシング JIT の opcache.jit_hot_loop は既定 64 なので、
 * 20x20 を数ステップ回せばホットループとして十分に踏まれる。
 * 本測定より十分小さくしておかないと空回し自体が高くつく。
 */
$warmupGrid = 20;
$warmupSteps = 5;


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
        'opcache',
        'jit',
        'warmup',
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
    "opcache: %s, jit: %s\n",
    $accel['opcache'],
    $accel['jit']
);

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
    "steps = %d, repeat = %d, warmup = %d\n\n",
    $steps,
    $repeat,
    $warmup
);

if ($warmup > 0) {

    echo sprintf(
        "Warming up (%dx%d, %d steps, %d time(s) per method)...\n",
        $warmupGrid,
        $warmupGrid,
        $warmupSteps,
        $warmup
    );

    foreach ($methods as $warmupFunction) {

        for ($w = 0; $w < $warmup; $w++) {

            $warmupFunction(
                createTemperature($warmupGrid),
                $warmupSteps,
                $rx,
                $ry
            );
        }
    }

    echo PHP_EOL;
}

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
                    $accel['opcache'],
                    $accel['jit'],
                    $warmup,
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
