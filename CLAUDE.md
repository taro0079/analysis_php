# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A single-purpose numerical experiment: a 2D heat-conduction solver (explicit finite
difference) implemented four different ways in PHP, used to measure how PHP's array
idioms scale. It is a measurement rig, not an application — there is no framework,
no composer.json, no test suite, and no dependency management.

## Commands

```sh
# Run the benchmark. Writes benchmark.csv and temperature.csv, prints a table to stdout.
php compare_array_function.php

# Averaged log-log fit of t(N) = a*N^p per method -> benchmark_average_fit.png
# (also emits *_mean.dat intermediates and fit.log)
gnuplot average.gp

# Raw per-repeat scatter -> benchmark_time.png
gnuplot plot_time.gp

# Temperature field heatmap -> temperature.png
gnuplot heatmap.gp
```

There is no build, lint, or test step. The PHP script is the whole pipeline; the
gnuplot scripts consume its CSV output. Run the PHP script before any `.gp` script,
or the plots will reflect stale data.

A full run is slow by design — `simulationArrayMerge` is intentionally quadratic per
row and dominates wall time at large N. To iterate quickly, trim `$gridSizes` (top of
[compare_array_function.php](compare_array_function.php)) rather than waiting out the
default sweep up to N=1000.

## Architecture

**One PHP file, four solvers, one shared kernel.** `simulationFor`, `simulationForeach`,
`simulationArrayMap`, and `simulationArrayMerge` in
[compare_array_function.php](compare_array_function.php) all compute the *same* explicit
finite-difference update and must stay numerically identical — only the array traversal
idiom differs. The `center_temperature` column in benchmark.csv is the cross-check: if
one method's center value diverges from the others at the same N, that method's kernel
has drifted.

`simulationArrayMerge` is deliberately pessimal (re-merging a growing array per cell) to
provide an upper bound on the plot. Do not "fix" it — that is the finding.

**Two outputs from one run.** After the benchmark sweep the script re-runs
`simulationFor` at a fixed 200x200 / 1000 steps purely to produce the physical result
written to `temperature.csv`. Benchmark parameters (`$gridSizes`, `$steps`, `$repeat`)
and heatmap parameters (`$heatGridSize`, `$heatSteps`) are independent.

**Stability guard.** `$rx + $ry <= 0.5` is the explicit-scheme stability condition and is
enforced with a hard exit at startup. Changing `$dt`, `$dx`, `$dy`, or `$alpha` risks
tripping it and silently invalidating results if the guard is loosened.

### CSV contracts

The gnuplot scripts index benchmark.csv by *column number*, not by header name:

```
1 method  2 N  3 cells  4 steps  5 repeat  6 time_sec
7 time_per_step_ms  8 time_per_cell_ns  9 peak_memory_mb  10 center_temperature
```

Adding or reordering columns in `fputcsv` breaks every `.gp` file. Update the awk
extractions in [average.gp](average.gp) and the `using` specs in
[plot_time.gp](plot_time.gp) together with any schema change.

temperature.csv is `x,y,temperature` with a blank line after each y-row so gnuplot can
find the grid row boundaries. [heatmap.gp](heatmap.gp) additionally filters through awk
(`NF==3 && numeric`) to drop the header and blank lines before `with image`.

### Fitting approach (average.gp)

`average.gp` does not fit in linear space. Times span four decades, so a linear-residual
fit would be dominated by the largest N. It instead uses `smooth unique` via `set table`
to average repeats per N into `*_mean.dat`, then fits `log(t) = log(a) + p*log(N)` —
minimizing relative error so the line matches what the log-log plot shows. Keep this
transform if you touch the fit; reverting to a direct `a*N**p` fit will produce curves
that visibly miss the points.

The `array_merge` exponent is an effective scaling index over the measured range, not an
asymptotic one — its local slope grows with N (see the comment block in average.gp).

## Notes

- The script header says PHP 7.4 and the plot titles are labeled "PHP 7.4", but the
  installed CLI here is PHP 8.3. Results produced locally are 8.3 numbers; update the
  labels if that matters for the write-up.
- `*_mean.dat`, `fit.log`, the `.csv` files, and the `.png` files are all generated
  artifacts, currently untracked. Regenerate rather than hand-edit them.
- Comments and commit messages in this repo are written in Japanese; match that style.
