<img align="right" width="128" height="128" src="docs/logo.svg" alt="Nim ABIF library logo">

# ABIF Parser for Nim

[![ABIF Tests](https://github.com/quadram-institute-bioscience/nim-abif/actions/workflows/test.yaml/badge.svg)](https://github.com/quadram-institute-bioscience/nim-abif/actions/workflows/test.yaml)
[![Conda Version](https://img.shields.io/conda/v/bioconda/nim-abif)](https://bioconda.github.io/recipes/nim-abif/README.html)
[![Conda Platform](https://img.shields.io/conda/p/bioconda/nim-abif)](https://bioconda.github.io/recipes/nim-abif/README.html)


A Nim library to parse [ABIF](chromatograms.md) (Applied Biosystems Information Format)
files from DNA sequencing machines, commonly used in Sanger capillary sequencing.

- [**API reference**](https://quadram-institute-bioscience.github.io/nim-abif/)

 

## Installation

To install the CLI packages:

```bash 
conda install -c bioconda nim-abif
```

If you have Nim installed, you can install binaries and library with:
```
nimble install abif
```

## Usage

### Basic Usage

```nim
import abif

# Parse a trace file
let trace = newABIFTrace("path/to/trace.ab1")

# Get sequence and quality information
let sequence = trace.getSequence()
let qualityValues = trace.getQualityValues()
let sampleName = trace.getSampleName()

# Export sequence to FASTA format
trace.exportFasta("output.fa")

# Export sequence to FASTQ format
trace.exportFastq("output.fq")

# Don't forget to close the trace when done
trace.close()
```

### Accessing Raw Data

```nim
# Get all tag names in the file
let tagNames = trace.getTagNames()

# Access data for a specific tag
let data = trace.getData("PBAS2")  # Base calls
let rawData = trace.getData("DATA1")  # Raw channel data
```

### Command-line Usage

The library provides three command-line tools:

 

#### FASTQ converter with quality trimming

```
abi2fq trace.ab1 output.fq
```

The abi2fq tool provides quality-based sequence trimming:

```
abi2fq --help                    # Show help message
abi2fq --window=15 --quality=25 trace.ab1  # Trim with window size 15, quality threshold 25
abi2fq --no-trim trace.ab1       # Skip quality trimming
abi2fq --verbose trace.ab1       # Show additional information
abi2fq trace.ab1                 # Output to STDOUT
```

#### Merging paired (forward/reverse) traces

```
abimerge forward.ab1 reverse.ab1 merged.fq
```

The abimerge tool combines forward and reverse Sanger reads using Smith-Waterman alignment:

```
abimerge --help                          # Show help message
abimerge --min-overlap=30 fwd.ab1 rev.ab1 # Require at least 30bp overlap
abimerge --score-match=10 --score-mismatch=-8 --score-gap=-10 fwd.ab1 rev.ab1  # Custom alignment scores
abimerge --join=10 fwd.ab1 rev.ab1       # Join seqs with 10 Ns if no overlap found
abimerge --pct-id=90 fwd.ab1 rev.ab1     # Require 90% identity in overlap region
abimerge --verbose fwd.ab1 rev.ab1       # Show alignment details
```

#### Render traces

Convert a trace (or part of it) into SVG

![rendered chromas](docs/chromas.png)

```bash
abichromatogram tests/A_forward.ab1 -o A.svg -s 500 -e 1000 --width 1600
```

## Data Types

The ABIF format supports various data types, all of which are properly handled by this parser:

- Numeric types (byte, word, short, long, float, double)
- String types (char, pString, cString)
- Date and time values
- Boolean values

## Development

### Running Tests

```
nimble test
```

### Building Documentation

```
nimble docs
```

## License

This library is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

This Nim implementation is based on:
- Co-authored with [Claude code](CLAUDE.md)
- Inspired by Python implementation: [abifpy](https://github.com/bow/abifpy) and a Perl implementation: [Bio::Trace::ABIF](https://metacpan.org/pod/Bio::Trace::ABIF) from CPAN

