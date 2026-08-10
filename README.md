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
  <img src="https://img.shields.io/badge/version-v0.6.2-8A2BE2?style=flat-square" alt="v0.6.2">
  <img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.16.0">
  <img src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT">
  <img src="https://img.shields.io/badge/linux-x86%20%7C%20x86__64%20%7C%20aarch64%20%7C%20riscv64-1793D1?style=flat-square" alt="Linux">
</p>

<p align="center">
  <b>zebrac</b> is a fork of <a href="https://github.com/andrewrk/poop">poop</a>. Adds JSON output, warmup runs, configurable sample limits, shell-like quoting, cross-compilation, and tests.<br>
  <a href="CHANGELOG.md">CHANGELOG</a>
</p>

---

## Quick start

zebrac runs on Linux and needs `perf_event_open` (if counters fail, `--help` mentions `perf_event_paranoid`).

```bash
git clone https://github.com/eneskemalergin/zebrac
cd zebrac
zig build
./zig-out/bin/zebrac ./app-old ./app-new
```

You pass one quoted command string per program. With several commands, the first is the baseline and later ones get a % delta in the table. Warmups run first and are not measured. Zebrac then runs every command once per round in a changing order. Equal minimum and maximum sample limits give an exact count. With several commands, the time budget is `--duration` multiplied by the command count, and zebrac finishes the current round before stopping. Every command therefore keeps the same sample count. Flags and defaults: `zebrac --help`.

While samples run, a progress bar prints on stderr when stderr is a TTY (unless you pass `-q`). Piping stdout alone does not hide it. The results table still shows unless you use `--quiet`.

## What it measures

Nine fields per sample: `wall_time`, `peak_rss`, `minor_faults`, `major_faults`, and five perf counters (`cpu_cycles`, `instructions`, `cache_references`, `cache_misses`, `branch_misses`). Wall time starts just before zebrac starts the program and ends when that program exits. `peak_rss` is Linux's reported memory high-water mark for that program. Minor faults do not require disk I/O; major faults do. Each measured sample gets a new perf counter group. Zebrac rejects the counters unless the kernel reports that they ran for all of their enabled time.

Zebrac waits only for the program it starts. If that program starts background work, it must wait for the work before it exits. Otherwise the background process can overlap later samples. Waiting keeps the work inside the wall-time sample, but `peak_rss` still covers only that program, not every process that it starts.

`major_faults` drops out of the printed tables only if every command reported zero. JSON always keeps it. Each metric gets mean, σ, min, max, quartiles, and an outlier count. With two or more commands, each command keeps its own samples and summary. Later tables show the signed change in their mean relative to the first command: `+N%` means more of that measurement and `-N%` means less. Only wall time maps directly to slower or faster. The percentage does not include an uncertainty range or warning mark. If any command has fewer than two samples, every table shows `n/a` for that metric. A first-command mean that is zero or nearly zero also shows `n/a`.

Zebrac starts your program directly without `/bin/sh`. Paths with spaces need quoting ([below](#quoting)). Compared to upstream [poop](https://github.com/andrewrk/poop), this fork adds warmup, min/max sample limits, `--json`, `--` to stop flag parsing, and `--json=path` for awkward paths.

## Examples

```bash
# two builds, second column shows % vs the first
zebrac ./app-old ./app-new

# spaced executable path; inner quotes must reach zebrac
zebrac "'./build/my app'" "'./build/my app' --release"

# stop sampling after ~2s of wall time (still honors --min-samples)
zebrac --duration 2000 'curl https://example.com'

zebrac --warmup 10 --min-samples 20 './myapp'

# CI: no table, write JSON
zebrac --quiet --json ./ci-results.json --duration 5000 './myapp'

# keep sampling when exit code != 0; first failure prints stderr, rest get a count
zebrac -f './might-fail.sh' './baseline.sh'

# operand looks like a flag; everything after -- is the command
zebrac -d 500 -- '/bin/true --version'
```

## Quoting

Your shell handles zebrac's flags. Each command string is split again inside zebrac before exec. Quotes needed by the command must remain inside that string:

- `foo bar` - two words; unquoted spaces, tabs, newlines, carriage returns, form feeds, and vertical tabs separate words
- `'...'` and `"..."` - literal text, no escapes inside
- `\x` - outside quotes, takes the next character literally (`\\` -> `\`)
- `echo'hi'` - adjacent quote and text glue into one word (`echohi`)

No `$VAR`, backticks, globs, pipes, or redirects.

## JSON output

`--json` writes summaries to `zebrac-results.json` by default. When it comes before the command, use `--json -- './myapp'` so the command is not mistaken for a path. Use `--json=path` when the path starts with `-`.

Zebrac finishes the JSON in the destination directory before it replaces the requested path. If writing fails, an existing regular file stays unchanged. A successful replacement keeps that file's permissions. The destination path itself is replaced, so a symlink at that path is not followed.

The CLI table scales numbers (ms, KB) and can compare runs with a delta column. JSON keeps raw units (nanoseconds, bytes, counts) and does not store which command was the baseline or any compare %. It always includes `major_faults` even when the table hid that row. Under `-f`, JSON has `failed_sample_count`; the table shows `(N runs, M failed)` when M > 0.

```bash
zebrac --json --duration 3000 './myapp'
jq '.results[0].wall_time.mean' zebrac-results.json
jq '.results[0].major_faults.mean' zebrac-results.json
```

```python
import json
data = json.load(open("zebrac-results.json"))
print(data["results"][0]["minor_faults"]["mean"])
```

Each result has `sample_count`, `failed_sample_count`, `argv`, and the nine metrics above. Each metric object carries `mean`, `std_dev`, `min`, `max`, `median`, `q1`, `q3`, `outlier_count`, `sample_count`, `unit`. Root also has `schema_version`, `zebrac_version`, and `config` (duration, sample limits, warmup, `allow_failures`, `max_samples_cap`, and `max_samples_requested` when clamped).

## Build

[Zig](https://ziglang.org/) 0.16.0.

```bash
git clone https://github.com/eneskemalergin/zebrac
cd zebrac
zig build
./zig-out/bin/zebrac --help
```

Default `zig build` installs one stripped ReleaseFast binary to `zig-out/bin/zebrac` (native arch only). Debug: `zig build -Doptimize=Debug`. `zig build test` runs Debug tests; `zig build test-release` runs the same tests in ReleaseFast. Before a tag, run `zig build preflight` (fmt + both test modes). CI cross-builds all four Linux targets on every push; tag push also runs `zig build release` for tarballs (`zig-out/{arch}-linux-zebrac`).

## Releasing

1. Bump `version` in `src/help.zig`, the README badge, and add a `CHANGELOG.md` section.
2. Commit on `main`, then tag and push: `git tag v0.6.2 && git push origin v0.6.2`
3. [release.yml](.github/workflows/release.yml) runs CI, builds all four Linux targets, packages `zebrac-<tag>-<arch>-linux.tar.gz` plus `SHA256SUMS`, and opens a GitHub Release with the matching CHANGELOG section as release notes.

## Compared to Hyperfine

[Hyperfine](https://github.com/sharkdp/hyperfine) is the usual cross-platform wall-clock tool. zebrac stays on Linux because it pulls perf counters and page-fault counts Hyperfine does not report. Hyperfine often shells out; zebrac execs argv directly (you can still run `sh -c '...'` as your command). With multiple inputs, Hyperfine sorts by time and lets you pick a reference; zebrac always deltas against the first command.

Related: [poop](https://github.com/andrewrk/poop) (upstream), [perf](https://perf.wiki.kernel.org/) (kernel tooling underneath).

## License

MIT. See [LICENSE](LICENSE).

---

<p align="center"><em>
Cold gates swing in time,<br>
Cache and branch laid bare to see;<br>
Truth in every tick.
</em></p>
