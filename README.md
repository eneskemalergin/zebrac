# zebrac: Zig Extended Benchmarking & Resource Analysis (with memory Checking)

Stop flushing your performance down the drain.

Linux performance benchmark that uses `perf_event_open` to compare multiple commands. Colorful terminal UI.

![screenshot](https://github.com/andrewrk/poop/assets/106511/6fc9d22b-f95b-46ce-8dc5-d5cecc77c226)

## Features

- **Hardware counters.** CPU cycles, instructions, cache references, cache misses, branch misses alongside wall time.
- **Peak RSS tracking.** Memory spikes per run.
- **Statistical rigor.** Mean, standard deviation, quartiles, outlier detection (Tukey's fences), Student's t-test for significance.
- **Color-coded deltas.** First command is the reference. Subsequent results show % difference with confidence intervals.
- **Warmup runs.** Run unmeasured iterations before sampling to warm caches and branch predictors.
- **Configurable sampling.** Set min/max samples and duration per command.
- **Machine-readable output.** `--json` writes structured results to a file for CI pipelines.
- **No shell overhead.** Commands spawn directly. No shell noise in measurements.
- **Progress bar.** Spinner and animated bar with estimated completion.

## Usage

```bash
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

## Build from Source

Tested with [Zig](https://ziglang.org/) 0.16.0 (bundled in this repo).

```bash
git clone https://github.com/eneskemalergin/zebrac
cd zebrac
zig build -Doptimize=ReleaseSmall
./zig-out/bin/zebrac --help
```

Cross-compile for aarch64, x86_64, x86, and riscv64 Linux:

```bash
zig build release
```

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

Zebrac is brand new. [Hyperfine](https://github.com/sharkdp/hyperfine) is a mature project with more configuration options.

Zebrac reports peak memory usage and 5 hardware counters (cycles, instructions, cache refs/misses, branch misses). Hyperfine does not report hardware counters.

Zebrac does not use a shell. Commands run directly. This avoids shell spawning noise but means no shell syntax in commands. Hyperfine runs commands in a shell by default, with a flag to disable it.

Zebrac treats the first command as a reference. Subsequent results are relative to it. Hyperfine prints the wall-clock-fastest command first, with a flag to select a different reference.

Hyperfine is cross-platform. Zebrac is Linux-only.

## References

- [andrewrk/poop](https://github.com/andrewrk/poop) - original upstream. Zebrac is a fork by [eneskemalergin](https://github.com/eneskemalergin/zebrac).
- [Hyperfine](https://github.com/sharkdp/hyperfine) - command-line benchmarking tool. Cross-platform, more features, no hardware counters.
- [perf](https://perf.wiki.kernel.org/) - Linux profiler. Low-level event monitoring. Zebrac wraps a subset of its functionality.

## License

MIT
