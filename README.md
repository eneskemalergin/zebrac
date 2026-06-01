<!-- markdownlint-disable MD033 MD036 MD041 -->
<p align="center">
  <img src="assets/zebrac-logo-v2.svg" alt="zebrac logo" width="280">
</p>

<p align="center">
  <em><strong>Z</strong>ig <strong>E</strong>xtended <strong>B</strong>enchmarking & <strong>R</strong>esource <strong>A</strong>nalysis (with memory <strong>C</strong>hecking)</em>
</p>

<p align="center">
  Linux performance benchmark that uses <code>perf_event_open</code> to compare multiple commands. Hardware counters, peak RSS, statistical significance, colorful terminal UI.
</p>

<p align="center">
  <a href="https://github.com/eneskemalergin/zebrac/actions/workflows/ci.yml">
    <img src="https://github.com/eneskemalergin/zebrac/actions/workflows/ci.yml/badge.svg?style=flat-square" alt="CI">
  </a>
  <img src="https://img.shields.io/badge/version-v0.5.3-8A2BE2?style=flat-square" alt="v0.5.3">
  <img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.16.0">
  <img src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT">
  <img src="https://img.shields.io/badge/linux-x86__64%20%7C%20aarch64%20%7C%20riscv64-1793D1?style=flat-square" alt="Linux">
</p>

<p align="center">
  <b>zebrac</b> is a fork of <a href="https://github.com/andrewrk/poop">poop</a> with hardware counters, statistical analysis, JSON output, warmup runs, configurable sampling, and CI features - what poop was missing.<br>
  <a href="CHANGELOG.md">CHANGELOG</a>
</p>

---

## Features

- **Hardware counters.** CPU cycles, instructions, cache references, cache misses, branch misses alongside wall time.
- **Peak RSS tracking.** Memory spikes per run.
- **Statistical rigor.** Mean, standard deviation, quartiles, outlier detection (Tukey's fences), Student's t-test for significance.
- **Color-coded deltas.** First command is the reference. Subsequent results show % difference with confidence intervals.
- **Warmup runs.** Run unmeasured iterations before sampling to warm caches and branch predictors.
- **Configurable sampling.** Set min/max samples and duration per command.
- **Machine-readable output.** `--json` writes structured results to a file for CI pipelines.
- **No shell overhead.** Commands spawn directly. No shell noise in measurements.
- **Shell-like quoting.** `'...'`, `"..."`, and `\ ` outside quotes (see [Quoting rules](#quoting-rules)).
- **Progress bar.** Spinner and animated bar with estimated completion.

## Usage

```text
Usage: zebrac [options] <command1> ... <commandN>

Compares the performance of the provided commands.

Sampling:
  -d, --duration <ms>    sampling duration per command (default: 5000)
  -i, --min-samples <n>  minimum samples per command (default: 5)
  -a, --max-samples <n>  maximum samples per command (default: 10000)
  -w, --warmup <n>       warmup runs before measurement (default: 3)

Output:
  --color <when>         color mode: auto, never, ansi (default: auto)
  -f, --allow-failures   benchmark despite non-zero exit codes
  --json [<path>]        write results as JSON (default: zebrac-results.json)
  -q, --quiet            suppress terminal output
```

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

Default `zig build` produces a stripped **ReleaseSmall** binary (~250 KB on x86_64). For debugging: `zig build -Doptimize=Debug`. Other modes: `-Doptimize=ReleaseSafe` or `ReleaseFast`.

Run unit tests: `zig build test` (includes pseudo-random stress tests for the lexer and stats). Match the GitHub Actions build job locally: `zig build ci` (tests + all four ReleaseSmall cross-compiles). Also run `zig fmt --check build.zig src/` before pushing. Optional LLVM fuzzing: `zig build test --fuzz` when your Zig toolchain supports it.

Cross-compile for aarch64, x86_64, x86, and riscv64 Linux:

```bash
zig build release
```

Median in the results table uses the upper middle value when the sample count is even (index `n/2` after sorting).

## Tooling Usage

The `--json` flag writes structured results to a file alongside the terminal output. Default path is `zebrac-results.json`. Custom path with `--json ./path/to/file.json`.

```bash
zebrac --json --duration 3000 './myapp'
# terminal output shows, then: results written to zebrac-results.json
jq '.results[0].wall_time.mean' zebrac-results.json
```

Parse in Python:

```python
import json
data = json.load(open('zebrac-results.json'))
mean = data['results'][0]['wall_time']['mean']
```

Each measurement includes `mean`, `std_dev`, `min`, `max`, `median`, `q1`, `q3`, `outlier_count`, `sample_count`, and `unit`.

## Comparison with Hyperfine

zebrac is new. [Hyperfine](https://github.com/sharkdp/hyperfine) has been around longer and has more configuration options.

zebrac reports peak memory usage and 5 hardware counters (cycles, instructions, cache refs/misses, branch misses). Hyperfine has none of those.

Commands run directly in zebrac - no shell spawning noise, but no shell syntax either. Hyperfine defaults to shell mode, with a flag to turn it off.

zebrac uses the first command as a reference and shows deltas. Hyperfine sorts by wall clock and lets you pick the reference.

Hyperfine is cross-platform. zebrac is Linux-only.

## References

- [andrewrk/poop](https://github.com/andrewrk/poop) - original upstream. zebrac adds hardware counters, statistical analysis, JSON export, warmup, configurable sampling, and CI integration.
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
