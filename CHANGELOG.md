<!-- markdownlint-disable MD024 -->
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

zebrac is a fork of [poop](https://github.com/andrewrk/poop). This changelog covers the poop lineage starting at v0.3.0 and tracks zebrac-specific changes after [0.5.0] section.

## [0.6.0] - Unreleased

## [0.5.5] - 2026-06-24

### Added

- Progress bar layout tests in `src/progress.zig` (property checks, render smoke); CI runs them via a dedicated `build.zig` test target
- Results table alignment test for color mode (`escape_codes`)
- Page fault metrics: `minor_faults` and `major_faults` from child `rusage` (table, JSON, help)

### Changed

- Progress bar writes to **stderr**; results table stays on **stdout** (piped stdout is clean JSON/table only)
- Unit formatting uses one plain-text path; color applied via `Io.Terminal.setColor` only (no embedded ANSI in measured widths)
- Perf counter fds: one `perf_event_open` group per command (after warmup), not per sample, should reduce syscalls on fast benchmarks
- Child stderr: `.ignore` on measured runs by default; pipe and capture only with `--allow-failures`
- Compare deltas: show `n/a` when baseline mean is ~0 or sample counts are too low for a CI (no `nan`/`inf` in table)

### Fixed

- Progress bar usize underflow at 100% fill (ReleaseSmall could hang or corrupt the row)
- Progress bar erase in `--color never`: use EL (`\x1b[2K\r`) so the benchmark header is not left with stale bar characters
- Final progress frame renders at 100% before the bar is cleared
- Colored results table misalignment: `σ` / min / max columns drifted because ANSI bytes were counted as column width

## [0.5.4] - 2026-06-23

### Added

- `--version` flag; help text moved to `src/help.zig`
- JSON output: `schema_version`, `zebrac_version`, and `config` (sampling flags) alongside `results`

### Changed

- `--help` rewritten: metrics, sampling, quoting, poop credit, shorter missing-arg errors
- Sample limit validation: reject `min > max` and `max == 0` before run; clamp note on stderr
- Results tables print after all commands finish measuring (notes stay off stdout)
- Results table column alignment (`±`, `…` anchors; outliers/delta left-aligned under headers)
- Wall-clock display units: use `m`/`h` for long durations; drop `ks` suffix (hard to interpret)
- README Usage section aligned with `--help`

## [0.5.3] - 2026-06-01

### Added

- Unit tests and CI format check (`zig fmt --check`, `zig build test`)
- Actionable `perf_event_open` error messages
- Shell-like argv parsing: single quotes, double quotes, and backslash escapes outside quotes (`src/argv_parse.zig`)
- Fuzz tests for argv roundtrip and measurement invariants (`zig build test --fuzz`)
- `Measurement.StatsError` for empty samples or short scratch buffers

### Changed

- Default build uses **ReleaseSmall** with strip enabled; use `-Doptimize=Debug` for development
- `zig build release` and CI cross-builds use ReleaseSmall
- Tests compile in Debug for clearer failures
- Measurement stats API: `summarizeAll` / `summarizeField` with caller-owned scratch (removed `compute` wrapper)
- Sample stats reuse one arena scratch buffer per command (seven fewer alloc/free pairs)
- Heap-backed sample list and stderr capture (1 MiB cap) instead of large stack buffers

### Fixed

- Progress bar buffer deinit on exit
- Perf event fds closed on every sample iteration via `defer`
- Mean calculation uses `f64` accumulation so huge counter values cannot overflow `u64` in debug builds
- `getStatScore95(0)` no longer indexes before the t-table

## [0.5.2] - 2026-05-23

### Fixed

- Student's t-table values for df=28 and df=29 were swapped (2.045↔2.048)
- `printNum3SigFigs` printed exact integer values without decimals, losing a significant figure (e.g., 5.0 rendered as "5" instead of "5.00")
- Column alignment in measurement table was off by 2 to 47 characters due to stale magic constants; headers now properly align with data columns
- ANSI escape code overhead was double-counted in column width calculations, misaligning output regardless of color mode
- `NO_COLOR` and `CLICOLOR_FORCE` env vars with empty values were ignored; now any presence disables or forces color per spec
- Removed dead `prog_name` allocation (50 bytes per command, never used)
- Progress bar estimate guarded against division by zero on extremely fast commands

## [0.5.1] - 2026-05-08

### Added

- `--json [<path>]` output flag - writes structured results to a JSON file for CI and tooling
- `-i, --min-samples <n>` flag - set minimum samples per command (default: 5)
- `-a, --max-samples <n>` flag - set maximum samples per command (default: 10000)
- `-w, --warmup <n>` flag - run unmeasured iterations before sampling (default: 3)
- `-f, --allow-failures` flag - benchmark despite non-zero exit codes
- Better error messages when a command cannot be executed

### Changed

- Renamed from **poop** to **zebrac** (Zig Extended Benchmarking & Resource Analysis with memory Checking)
- Updated to Zig 0.16.0 (tracked master through 0.12.0, 0.15.0, 0.16.0)
- CI now cross-compiles for x86-linux, x86_64-linux, aarch64-linux, and riscv64-linux
- `build.zig` supports `-Dstrip` and `zig build release` for multi-target upstream binary releases
- Updated `.gitignore`
- README overhaul

### Fixed

- `--color` argument parsing regression

## [0.5.0] - 2024-09-06

### Added

- Show command stderr on failure

### Changed

- Updated to Zig 0.11.0
- Updated for latest Zig standard library
- Updated for latest breaking Zig changes (std.os -> std.posix)

## [0.4.0] - 2023-06-21

### Added

- Fancy progress bar - animated bar with spinner and estimated completion
- Metric prefix formatting - auto-scaling (ns/us/ms/s, bytes/KB/MB/GB, K/M/G/T for counts), limited to 3 significant figures
- `--color auto|never|ansi` flag to control color mode
- `-d, --duration <ms>` shorthand for sampling duration
- Print usage text on no or unrecognized arguments
- Show command stderr on failure (reverted after release)
- Improved CLI argument error messages
- `build.zig` release step for easy binary distribution

### Changed

- Use stdout instead of stderr for TTY detection
- Updated to Zig 0.11.0-dev.3771

## [0.3.0] - 2023-06-16

### Added

- **Hardware counters** - CPU cycles, instructions, cache references, cache misses, branch misses via `perf_event_open`
- **Wall time** measurement with nanosecond precision
- **Peak RSS** tracking per run via `getrusage`
- **Statistical analysis** - mean, standard deviation, min, max, median, Q1, Q3, outlier count (Tukey's fences)
- **95% confidence interval** with Student's t-test for significance between commands
- **Color-coded deltas** - first command is the reference; subsequent results show % difference with confidence interval
- **Multi-command comparison** - run N commands, compare all against the first
- **Configurable sampling duration** via `--duration <ms>` (default: 5000)
- **Outlier detection and reporting** with count and percentage
- **Progress indicator** - shows current run count
- **CI pipeline** via GitHub Actions
- **MIT license**
- `--help` flag with grouped Sampling and Output sections
