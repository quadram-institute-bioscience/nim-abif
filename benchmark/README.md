# Benchmark

## Tools required

* the `nim-abif` package
* a Perl implementation
* hyperfine, to measure times


```bash
mamba create -n benchmark -c conda-forge -c bioconda \
  perl-fastx-abi=1.0.1 \
  hyperfine=1.18
```
## Running the benchmarks

```bash
# Speed of abi to fastq
hyperfine "mergeabi --for tests/A_forward.ab1 --rev tests/A_reverse.ab1 " \
  "./bin/abimerge tests/A_forward.ab1 tests/A_reverse.ab1 " \
  --warmup 1 --export-markdown benchmark/merge.md

# Speed of merge abi
hyperfine "abi2fq tests/A_forward.ab1 " \
   "./bin/abi2fq tests/A_forward.ab1"  \
   --warmup 1  --export-markdown benchmark/abi2fq.md
```

## Results

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `abi2fq tests/A_forward.ab1 ` | 51.9 ± 2.2 | 48.7 | 57.3 | 4.85 ± 0.48 |
| `./bin/abi2fq tests/A_forward.ab1` | 10.7 ± 1.0 | 9.1 | 13.7 | 1.00 |

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `mergeabi --for tests/A_forward.ab1 --rev tests/A_reverse.ab1 ` | 473.9 ± 19.2 | 456.6 | 515.5 | 15.65 ± 1.07 |
| `./bin/abimerge tests/A_forward.ab1 tests/A_reverse.ab1 ` | 30.3 ± 1.7 | 28.1 | 37.4 | 1.00 |

