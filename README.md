# lama-freq

Counts reachable Lama bytecode instructions and adjacent instruction pairs.

## Run

```sh
docker run dmfrpro/lama-freq
analyze Sort --limit 8
lama-freq --help
```

## Tests

```sh
test-all core    # fast correctness suite
test-all stress  # resource-conscious tests
test-all         # everything
```

## Benchmarks

```sh
bench performance
bench stress
bench stress-full             # all 2-GiB inputs
bench stress-full dense_2gib  # one input
```

Reports CPU time and peak memory. Inputs are cached in `tmp/bench`.
Use `--work DIR` to change the cache or `--regenerate` to recreate them

## Algorithm

1. Traverse the reachable CFG from public entries (optionally offset zero),
joining function-owner and stack-depth contexts and validating instructions and targets
2. Intern instruction identities and count consecutive instructions and pairs
while streaming fallthrough paths, then subtract pairs invalidated by newly discovered
jump labels. Captures and fallback mode use raw instruction bytes
3. Spill signed counts to external merge sort when the memory budget is exceeded.
Report nonzero counts by descending frequency, then encoded key bytes

## Benchmark results

```shell
stress-full
╭───┬────────────────┬───────────┬──────────┬──────────┬───────────╮
│ # │   benchmark    │  status   │ input_mb │  cpu_ms  │ memory_mb │
├───┼────────────────┼───────────┼──────────┼──────────┼───────────┤
│ 0 │ sparse_2gib    │ completed │  2147.48 │     0.00 │     11.46 │
│ 1 │ near_zero_2gib │ completed │  2147.48 │     0.00 │     11.16 │
│ 2 │ dense_2gib     │ completed │  2147.48 │ 30470.00 │   2429.51 │
│ 3 │ variables_2gib │ completed │  2147.48 │ 31780.00 │   2429.39 │
│ 4 │ calls_2gib     │ completed │  2147.48 │ 28500.00 │   2428.83 │
│ 5 │ closures_2gib  │ completed │  2147.48 │ 26940.00 │   2418.11 │
│ 6 │ shuffled_2gib  │ completed │  2147.48 │ 46000.00 │   2702.37 │
╰───┴────────────────┴───────────┴──────────┴──────────┴───────────╯
```
