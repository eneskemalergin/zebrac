<!-- markdownlint-disable MD033 MD036 MD038 MD041 -->
<p align="center">
  <img src="assets/zebrac-logo-v2.svg" alt="zebrac logo" width="280">
</p>

<p align="center">
  <em><strong>Z</strong>ig <strong>E</strong>xtended <strong>B</strong>enchmarking & <strong>R</strong>esource <strong>A</strong>nalysis (with memory <strong>C</strong>hecking)</em>
</p>

<p align="center">
  <a href="https://github.com/eneskemalergin/zebrac/actions/workflows/ci.yml">
    <img src="https://github.com/eneskemalergin/zebrac/actions/workflows/ci.yml/badge.svg?style=flat-square" alt="CI">
  </a>
  <img src="https://img.shields.io/badge/version-v0.5.6-8A2BE2?style=flat-square" alt="v0.5.6">
  <img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.16.0">
  <img src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT">
  <img src="https://img.shields.io/badge/linux-x86__64%20%7C%20aarch64%20%7C%20riscv64-1793D1?style=flat-square" alt="Linux">
</p>

<p align="center">
  <b>zebrac</b> is a fork of <a href="https://github.com/andrewrk/poop">poop</a>. Adds JSON output, warmup runs, configurable sample limits, shell-like quoting, cross-compilation, and tests.<br>
  <a href="CHANGELOG.md">CHANGELOG</a>
</p>

---

## Features

Inherited from poop:

- **Hardware counters.** CPU cycles, instructions, cache references, cache misses, branch misses via `perf_event_open`.
- **Peak RSS tracking.** Memory spikes per run via `getrusage`.
- **Page fault counts.** Minor and major faults per run from the same `getrusage` wait (no extra syscall).
- **Statistical analysis.** Mean, standard deviation, quartiles, outlier detection (Tukey's fences), Student's t-test.
- **Color-coded deltas.** First command is the reference. Subsequent results show % difference with confidence intervals.
- **No shell overhead.** Commands spawn directly. No shell noise in measurements.
- **Progress bar.** Spinner and animated bar with estimated completion.

Added by zebrac:

- **Warmup runs.** Run unmeasured iterations before sampling to warm caches and branch predictors.
- **Configurable sampling.** Set min/max samples and duration per command.
- **Machine-readable output.** `--json` writes structured results to a file for CI pipelines.
- **Shell-like quoting.** `'...'`, `"..."`, and `\ ` outside quotes (see [Quoting rules](#quoting-rules)).

## Usage

Linux only. Full reference: run `zebrac --help` after building (source of truth is `src/help.zig`).

```bash
./zig-out/bin/zebrac --help
./zig-out/bin/zebrac --version
```

**Commands:** one quoted string per program (no `/bin/sh`). Two or more commands: first is the baseline, rest show delta %.

**Measured each run:** `wall_time`, `peak_rss`, `minor_faults`, `major_faults` (table row hidden when `max` is 0; JSON always includes the field), and five perf hardware counters (`cpu_cycles`, `instructions`, `cache_references`, `cache_misses`, `branch_misses`).

**Sampling:** warmup runs first (unmeasured), then samples until both `--duration` and `--min-samples` are satisfied, or `--max-samples` (cap 10000) stops the run. Rejects `min < 1`, `max == 0`, or `min > max` before spawn. With `-f`, non-zero exit on a measured run does not stop the benchmark; see **Output semantics** and `zebrac --help` (Sampling).

```text
Sampling:
  -d, --duration <ms>      time budget per command [5000]
  -i, --min-samples <n>    minimum measured runs per command [5]
  -a, --max-samples <n>    maximum measured runs per command [10000]
  -w, --warmup <n>         unmeasured runs before sampling [3]

Output:
  --color <mode>           auto, never, or ansi [auto]
  -q, --quiet              no progress bar or results table
  --json [<path>]          write results JSON [zebrac-results.json]
  -f, --allow-failures     keep sampling on non-zero exit

Information:
  -h, --help               show full usage
  --version                show version
```

**Requirements:** Linux with `perf_event_open`. If counters fail, check `perf_event_paranoid` (see `--help`).

**Environment:** `NO_COLOR` and `CLICOLOR_FORCE` affect color in `auto` mode (see `--help`).

### Examples

Compare two builds:

```bash
zebrac ./app-old ./app-new
```

Path with spaces:

```bash
zebrac './build/my app' "./build/my app --release"
```

Quick 2-second benchmark:

```bash
zebrac --duration 2000 'curl https://example.com'
```

With warmup and custom sample count:

```bash
zebrac --warmup 10 --min-samples 20 './myapp'
```

With JSON output for CI (quiet, only JSON file):

```bash
zebrac --quiet --json ./ci-results.json --duration 5000 './myapp'
```

## Quoting rules

zebrac does not run `/bin/sh`. Each **command operand** you pass (every non-flag argument) is parsed again by a small lexer (`argv_parse.zig`) before spawn. Your shell still splits `zebrac`’s own argv first; quoting below applies to those command strings, not to `zebrac`’s flags.

| Syntax     | Behavior                                                                      |
| ---------- | ----------------------------------------------------------------------------- |
| `foo bar`  | Two arguments (whitespace: space, tab, newline, carriage return).             |
| `'...'`    | Literal; no escapes inside.                                                   |
| `"..."`    | Literal; no escapes inside.                                                   |
| `\x`       | Outside quotes only: x becomes part of the word (use `\\` for one backslash). |
| `echo'hi'` | Adjacent quoted and bare text glue into one word (`echohi`).                  |

Not supported: `$VAR`, `` `cmd` ``, globs, `|`, `>`, `&`. UTF-8 paths work as bytes; do not split inside a multibyte character.

## Build from Source

Tested with [Zig](https://ziglang.org/) 0.16.0 (bundled in this repo).

```bash
git clone https://github.com/eneskemalergin/zebrac
cd zebrac
zig build
./zig-out/bin/zebrac --help
```

Default `zig build` produces a stripped **ReleaseSmall** binary (~290 KB on x86_64; size varies by Zig version). For debugging: `zig build -Doptimize=Debug`. Other modes: `-Doptimize=ReleaseSafe` or `ReleaseFast`.

Match CI: the **check** job runs `zig fmt --check build.zig src/` and `zig build test`; the **build** job cross-compiles ReleaseSmall for x86, x86_64, aarch64, and riscv64 Linux. Locally, `zig build ci` runs tests plus those four cross-builds in one step. Optional LLVM fuzzing: `zig build test --fuzz` when your Zig toolchain supports it.

Cross-compile for aarch64, x86_64, x86, and riscv64 Linux:

```bash
zig build release
```

Median in the results table uses the upper middle value when the sample count is even (index `n/2` after sorting).

## Output semantics

CLI table and `--json` export answer different questions. Keep the roles separate:

| Concern                           | CLI table                                          | JSON v1 (`--json`)                           |
| --------------------------------- | -------------------------------------------------- | -------------------------------------------- |
| Compare deltas vs first command   | Yes (`delta` column)                               | No                                           |
| Significance / CI on delta        | Yes (`±` half-width)                               | No                                           |
| Per-run raw samples               | No                                                 | No                                           |
| Display scaling (ns/us/ms, KB/MB) | Yes                                                | No (raw base units)                          |
| Outliers                          | Count + % in table                                 | `outlier_count` only                         |
| Failed measured runs (`-f`)       | `(N runs, M failed)` when `M > 0`, else `(N runs)` | `failed_sample_count` always (`0` when none) |
| Baseline command                  | Implicit (first operand)                           | Not recorded                                 |

**σ column** is the per-command sample standard deviation (spread within one run set). **Delta ±** is a separate pooled two-sample compare interval (CLI only).

**Equal means:** compare delta shows bare `0%` with no `±` band when the difference is zero and compare is defined; too few samples or a ~zero baseline yields `n/a`.

JSON is a **summary archive** for CI and tooling (`mean`, `std_dev`, quartiles, etc.). Recompute compare semantics yourself or wait for schema v2 (planned). Full detail: `zebrac --help` (Comparison and Sampling sections).

## Tooling Usage

The `--json` flag writes structured results to a file alongside the terminal output. Default path is `zebrac-results.json`. Custom path with `--json ./path/to/file.json`.

The root object includes `schema_version`, `zebrac_version`, `config` (sampling flags used for the run), and `results`, an array of objects per command with `sample_count`, `failed_sample_count` (always present; non-zero when some measured runs exited non-zero under `-f`; warmup failures are not counted), and summarized metrics in **raw units** (nanoseconds, bytes, counts). The CLI table uses `(N runs)` or `(N runs, M failed)` in the benchmark header when `M > 0`. JSON has **no** compare deltas, significance, or baseline index; those appear only in the CLI table when you pass two or more commands (first command is the baseline there).

```bash
zebrac --json --duration 3000 './myapp'
# terminal output shows, then: results written to zebrac-results.json
jq '.results[0].wall_time.mean' zebrac-results.json
jq '.config.warmup' zebrac-results.json
```

Parse in Python:

```python
import json
data = json.load(open('zebrac-results.json'))
mean = data['results'][0]['wall_time']['mean']
warmup = data['config']['warmup']
```

Each measurement includes `mean`, `std_dev`, `min`, `max`, `median`, `q1`, `q3`, `outlier_count`, `sample_count`, and `unit`.

## Comparison with Hyperfine

zebrac is new. [Hyperfine](https://github.com/sharkdp/hyperfine) has been around longer and has more configuration options.

zebrac reports peak memory usage and 5 hardware counters (cycles, instructions, cache refs/misses, branch misses). Hyperfine has none of those.

Commands run directly in zebrac - no shell spawning noise, but no shell syntax either. Hyperfine defaults to shell mode, with a flag to turn it off.

zebrac uses the first command as a reference and shows deltas. Hyperfine sorts by wall clock and lets you pick the reference.

Hyperfine is cross-platform. zebrac is Linux-only.

## References

- [andrewrk/poop](https://github.com/andrewrk/poop) - original upstream. zebrac adds JSON export, warmup, configurable sampling, shell-like quoting, cross-compilation, and tests.
- [Hyperfine](https://github.com/sharkdp/hyperfine) - command-line benchmarking tool. Cross-platform, more features, no hardware counters.
- [perf](https://perf.wiki.kernel.org/) - Linux profiler. Low-level event monitoring. zebrac wraps a subset of its functionality.

## License

MIT. See [LICENSE](LICENSE).

---

<p align="center"><em>
Cold gates swing in time,<br>
Cache and branch laid bare to see;<br>
Truth in every tick.
</em></p>
