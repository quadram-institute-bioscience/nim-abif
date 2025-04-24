# ABIF Parser for Nim

A Nim library to parse ABIF (Applied Biosystems Information Format) files from DNA sequencing machines, commonly used in Sanger capillary sequencing.

## Features

- Parse `.ab1` and `.fsa` trace files
- Extract sequence data, quality values, and sample names
- Supports all standard ABIF data types
- Export to FASTA and FASTQ formats
- Correctly handles big-endian binary data

## Installation

```
nimble install abif
```

Or add to your `.nimble` file:

```
requires "abif >= 0.1.0"
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

The library also provides a simple command-line tool:

```
abif trace.ab1 output.fa
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

This library is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

This Nim implementation is based on:
- Python implementation: [abifpy](https://github.com/bow/abifpy)
- Perl implementation: Bio::Trace::ABIF from CPAN
- Co-authored with [Claude code](https://claude.ai)
