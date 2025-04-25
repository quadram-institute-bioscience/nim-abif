# ABIF (Applied Biosystems Information Format) File Format

The ABIF format is a binary file format used by Applied Biosystems for storing genetic analysis data. It's used primarily for `.ab1` (sequencing data) and `.fsa` (fragment analysis data) files.

## Key Format Concepts

- **Tags**: Data elements in ABIF files are identified by tags (name, number) pairs
- **Directory**: Contains entries pointing to the data in the file
- **Header**: Fixed 128-byte area at the beginning that identifies the file format

## File Structure

1. **Header** (128 bytes)
   - First 4 bytes: ASCII "ABIF"
   - Bytes 4-6: Version number (typically 101)
   - Bytes 6-34: Directory entry for the main directory
   - Bytes 34-128: Reserved/unused space

2. **Directory**
   - Contains entries pointing to data elements
   - Each entry is 28 bytes
   - Directory can be located anywhere in the file

3. **Data**
   - Binary data referred to by directory entries

## Directory Entry Structure

Each directory entry is 28 bytes with the following fields:
- `name` (4 bytes): Tag name (4 ASCII characters)
- `number` (4 bytes): Tag number
- `elementtype` (2 bytes): Data type code
- `elementsize` (2 bytes): Size of one element in bytes
- `numelements` (4 bytes): Number of elements in the item
- `datasize` (4 bytes): Total size of the data in bytes
- `dataoffset` (4 bytes): Offset to the data, or the data itself for small items
- `datahandle` (4 bytes): Reserved, always zero

## Data Types

Common data types include:
- `byte` (1): Unsigned 8-bit integer
- `char` (2): 8-bit ASCII character
- `word` (3): Unsigned 16-bit integer
- `short` (4): Signed 16-bit integer
- `long` (5): Signed 32-bit integer
- `float` (7): 32-bit floating point
- `double` (8): 64-bit floating point
- `date` (10): Packed date structure
- `time` (11): Packed time structure
- `pString` (18): Pascal-style string (length + data)
- `cString` (19): C-style null-terminated string

## Common Tags

Different instrument models and software versions use different tags. Some common ones:

- `DATA 1-4`: Raw channel data
- `PBAS 1`: Basecalled sequence
- `PLOC 1`: Base locations
- `DyeN 1-4`: Dye names
- `SMPL`: Sample name
- `RUND`: Run dates
- `RUNT`: Run times

## Implementation Notes

1. Read the header and extract the directory information
2. Parse the directory entries
3. For each entry, read its data according to the data type and size
4. Small data items (<=4 bytes) are stored directly in the `dataoffset` field
5. Larger items have their binary data at the location specified by `dataoffset`

All integers in the format are stored in big-endian byte order (high-order byte first).

# Chromatogram Generation

The abif library now includes functionality to generate SVG chromatograms from ABIF trace files. The chromatogram visualizer renders trace data with professional features like color-coding, base calls, and position markers.

## Usage

```
abichromatogram <trace_file.ab1> [options]
```

Where:
- `<trace_file.ab1>` is the input ABIF trace file

Options:
- `-o, --output FILE` - Output SVG file (default: chromatogram.svg)
- `-w, --width WIDTH` - SVG width in pixels (default: 1200)
- `-h, --height HEIGHT` - SVG height in pixels (default: 600)
- `-s, --start POS` - Start position for region display (default: 0)
- `-e, --end POS` - End position for region display (default: whole trace)
- `-d, --downsample FACTOR` - Downsample factor to reduce data density (default: 1)
- `--hide-bases` - Hide base calls
- `--debug` - Show debug information

## Features

The chromatogram visualization shows:

1. Raw trace data from the four fluorescence channels
2. Base call positions marked with vertical lines
3. Base letters shown at the top of the peaks
4. Color-coded channels based on nucleotide type:
   - A: green
   - C: blue
   - G: black
   - T: red
5. Position markers and grid lines for navigation
6. Trace channel legend 
7. Base count summary

## Technical Implementation

The chromatogram generator extracts the following data from the ABIF file:

- Raw trace data from the DATA1-DATA4 tags (or DATA9-DATA12 in newer files)
- Base order from FWO_1 tag to identify which channel corresponds to which base
- Peak locations from PLOC2 tag for marking base calls
- Base calls from PBAS2 tag for sequence annotation

The raw traces are normalized to a consistent scale and rendered as SVG polylines. Base calls are rendered as text at each peak position.

## Examples

Basic usage:
```
abichromatogram tests/3730.ab1 output.svg
```

With downsampling for smoother visualization:
```
abichromatogram tests/3730.ab1 -o output.svg -d 5
```

Viewing a specific region:
```
abichromatogram tests/3730.ab1 -o region.svg -s 500 -e 1000
```

Changing dimensions:
```
abichromatogram tests/3730.ab1 -w 1600 -h 800
```

Debugging mode:
```
abichromatogram tests/3730.ab1 --debug
```

## Integration

The chromatogram generator is integrated into the abif library build system:

- Added to the namedBin list in abif.nimble
- Included in the buildbin and install tasks
- Requires the nimsvg package for SVG generation

## Future Enhancements

Potential future improvements:

1. Zooming capability to focus on specific regions
2. Quality score visualization
3. Interactive web-based visualization
4. Export as PNG/PDF
5. Additional annotations and metrics
6. Region highlighting for areas of interest

> Made by Claude Code (Sonnet 3.7), summarising the original ABIF format documentation
