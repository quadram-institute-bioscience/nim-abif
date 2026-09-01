## This module provides functionality to generate SVG chromatograms from ABIF trace files.
## It renders the four fluorescence channels with base calls in a visual format that
## resembles the output of DNA sequencing instruments.
## Command-line usage:
##
## .. code-block:: none
##   abichromatogram <trace_file.ab1> [options]
##
## Options:
##   -o, --output FILE       Output SVG file (default: chromatogram.svg)
##   --html FILE             Output a portable HTML report with embedded SVG
##   -w, --width WIDTH       SVG width in pixels (default: 1200)
##   --height HEIGHT         SVG height in pixels (default: 600)
##   -s, --start POS         Start position (default: 0)
##   -e, --end POS           End position (default: whole trace)
##   -d, --downsample        FACTOR Downsample factor for visualization (default: 1)
##   --highlight START-END   Highlight a trace scan region; repeat or comma-separate
##   --hide-bases            Hide base calls
##   --debug                 Show debug information
##   -h, --help              Show this help message and exit
##   -v, --version           Show version information and exit
##
## Example usage:
##
## .. code-block:: nim
##   # Generate a chromatogram from a trace file
##   abichromatogram input.ab1 -o output.svg
##
##   # Generate a portable HTML report
##   abichromatogram input.ab1 --html output.html
##
##   # Generate a zoomed view of a specific region with downsampling
##   abichromatogram input.ab1 -s 500 -e 1000 -d 5
##


import std/[os, strformat, strutils, sequtils, tables, math]
import nimsvg
import ./abif

const DefaultHighlightFill* = "#fff6a6"

type
  Channel* = enum
    ## The four channels used in capillary electrophoresis
    A = "A", C = "C", G = "G", T = "T"
  
  TraceDataPoint* = object
    ## A single data point in the trace with values for each channel
    position*: int               ## X position (scan number)
    values*: Table[Channel, int] ## Intensity value for each channel (scaled 0-1000)
  
  TraceData* = object
    ## Processed trace data ready for visualization
    points*: seq[TraceDataPoint]        ## Processed trace data points
    baseOrder*: string                 ## Order of bases in channels (e.g., "ACGT")
    peaks*: seq[int]                   ## Base call peak positions
    sequence*: string                  ## Called sequence
    traceLen*: int                     ## Total length of trace in data points
    baseColors*: Table[Channel, string] ## Color mapping for each nucleotide base

  HighlightRegion* = object
    ## A highlighted trace scan region to draw behind the chromatogram.
    startPos*, endPos*: int            ## Inclusive trace scan coordinates
    fill*: string                      ## SVG fill color; defaults to light yellow
    label*: string                     ## Optional label shown inside the highlight


proc newHighlightRegion*(startPos, endPos: int,
                         fill: string = DefaultHighlightFill,
                         label: string = ""): HighlightRegion =
  ## Convenience constructor for chromatogram highlight regions.
  HighlightRegion(startPos: startPos, endPos: endPos, fill: fill, label: label)


proc getTraceData*(trace: ABIFTrace, debug: bool = false): TraceData =
  ## Extracts and processes trace data from an ABIF file
  ##
  ## This function processes both raw and analyzed data from the trace file,
  ## normalizes values for display, and maps the correct channels to bases.
  ##
  ## Parameters:
  ##   trace: The ABIFTrace object
  ##   debug: Whether to print debug information
  ##
  ## Returns:
  ##   TraceData object containing processed data ready for visualization
  let parseChannel = proc(rawStr: string): seq[int] =
    if rawStr.len < 3: # Empty or too short
      return @[]
    
    # Try to parse in the format "@[1234, 5678, ...]"
    if rawStr.startsWith("@[") and rawStr.endsWith("]"):
      let content = rawStr[2..^2] # Remove @[ and ]
      if content.len == 0:
        return @[]
      try:
        return content.split(", ").mapIt(it.strip().parseInt)
      except:
        if debug:
          echo "Failed to parse as seq: ", rawStr[0..min(20, rawStr.len-1)], "..."
    
    # If not in sequence format, just convert each character's ord value
    var parsedSeq = newSeq[int](rawStr.len)
    for i, c in rawStr:
      parsedSeq[i] = ord(c)
    return parsedSeq
  
  # Standard colors for chromatograms
  result.baseColors = {
    A: "green", 
    C: "blue", 
    G: "black", 
    T: "red"
  }.toTable
  
  # Get base order (typically GATC or ACGT)
  var baseOrder = ""
  if trace.data.hasKey("baseorder"):
    baseOrder = trace.data["baseorder"]
  else:
    baseOrder = trace.getData("FWO_1")
  
  if baseOrder.len == 0:
    # Default base order if not found
    baseOrder = "ACGT"
  
  result.baseOrder = baseOrder
  
  # We need to map the base order to our Channel enum
  var channelMap: Table[int, Channel]
  for i, base in baseOrder:
    case base:
      of 'A': channelMap[i] = A
      of 'C': channelMap[i] = C
      of 'G': channelMap[i] = G
      of 'T': channelMap[i] = T
      else: discard
  
  if debug:
    echo "Channel mapping from base order '", baseOrder, "':"
    for i, ch in channelMap:
      echo "  Channel ", i+1, " = ", ch
  
  # Determine which DATA channels to use (older files use DATA1-4, newer may use DATA9-12)
  var channels: array[4, string]
  
  # First, try DATA9-12 which are processed channels in newer files
  let useProcessed = trace.getTagNames().anyIt(it == "DATA9")
  
  if useProcessed:
    if debug:
      echo "Using processed trace channels (DATA9-12)"
    channels = ["DATA9", "DATA10", "DATA11", "DATA12"]
  else:
    if debug:
      echo "Using raw trace channels (DATA1-4)"
    channels = ["DATA1", "DATA2", "DATA3", "DATA4"]
  
  # Read all channels
  var rawChannels: array[4, seq[int]]
  var maxLen = 0
  
  for i, chanName in channels:
    rawChannels[i] = parseChannel(trace.getData(chanName))
    maxLen = max(maxLen, rawChannels[i].len)
    if debug:
      echo "Read channel ", chanName, " with ", rawChannels[i].len, " points"
  
  result.traceLen = maxLen
  
  # Get peak locations
  result.peaks = parseChannel(trace.getData("PLOC2"))
  
  # Get sequence
  result.sequence = trace.getSequence()
  
  # Special cases like empty data
  if maxLen == 0 or result.sequence.len == 0:
    return result
  
  # Normalize and process the data
  # 1. Find the maximum values for each channel for normalization
  var maxVals: array[4, int]
  for i in 0..<4:
    if rawChannels[i].len > 0:
      maxVals[i] = max(1, rawChannels[i].max) # Avoid division by zero
  
  # 2. Prepare processed data points
  result.points = newSeq[TraceDataPoint](maxLen)
  
  for pos in 0..<maxLen:
    var point = TraceDataPoint(position: pos)
    
    # Initialize all channels to 0
    for ch in Channel:
      point.values[ch] = 0
    
    # Add values from each available channel
    for i in 0..<4:
      if i in channelMap and pos < rawChannels[i].len:
        let ch = channelMap[i]
        let normVal = if rawChannels[i][pos] <= 0: 0 
                      else: int((rawChannels[i][pos].float / maxVals[i].float) * 1000.0)
        point.values[ch] = normVal
    
    result.points[pos] = point

# Process a region of points to get a single value for a downsampling bin
proc getMaxInBin(points: seq[TraceDataPoint], ch: Channel, start, endPos: int): int =
  ## Process a region of points to get the maximum value for a downsampling bin
  ##
  ## Parameters:
  ##   points: Sequence of trace data points
  ##   ch: The channel to get the maximum value for
  ##   start: Starting position of the bin
  ##   endPos: Ending position of the bin
  ##
  ## Returns:
  ##   Maximum value in the bin for the specified channel
  for j in start..<endPos:
    if j < points.len:
      let val = points[j].values.getOrDefault(ch, 0)
      if val > result:
        result = val

# Generate the trace polyline for a channel


proc generatePolyline(
  points: seq[TraceDataPoint],
  ch: Channel, 
  displayStart, displayEnd, downsample: int,
  padding, topPadding, plotHeight: int,
  xScale: float
): string =
  ## Generate the SVG polyline string for a channel
  ##
  ## Parameters:
  ##   points: Sequence of trace data points
  ##   ch: The channel to generate a polyline for
  ##   displayStart: Starting position of the visible area
  ##   displayEnd: Ending position of the visible area
  ##   downsample: Factor to downsample the data by
  ##   padding: Horizontal padding in pixels
  ##   topPadding: Top padding in pixels
  ##   plotHeight: Height of the plot area in pixels
  ##   xScale: Scaling factor for X coordinates
  ##
  ## Returns:
  ##   String containing SVG polyline points
  var line = ""
  for i in countup(displayStart, displayEnd-1, downsample):
    let binEnd = min(i + downsample, displayEnd)
    let maxVal = getMaxInBin(points, ch, i, binEnd)
    
    let x = padding + (((i - displayStart) div downsample).float * xScale).int
    let y = topPadding + plotHeight - ((maxVal.float / 1000) * plotHeight.float).int
    
    if line.len == 0:
      line = $x & "," & $y
    else:
      line &= " " & $x & "," & $y
  
  return line

# Filter peak positions to just the ones that are visible
proc getVisiblePeaks(
  peaks: seq[int],
  sequence: string,
  displayStart, displayEnd, padding, width, topPadding: int,
  scaleFn: proc(peakPos: int): int {.gcsafe.}
): seq[tuple[x, peakPos: int, baseChar: char]] {.gcsafe.} =
  ## Filter peak positions to just the ones that are visible in the current view
  ##
  ## Parameters:
  ##   peaks: Sequence of peak positions
  ##   sequence: The base call sequence
  ##   displayStart: Starting position of the visible area
  ##   displayEnd: Ending position of the visible area
  ##   padding: Horizontal padding in pixels
  ##   width: Total width of the SVG in pixels
  ##   topPadding: Top padding in pixels
  ##   scaleFn: Function to scale peak position to X coordinate
  ##
  ## Returns:
  ##   Sequence of visible peaks with their positions and base calls
  result = @[]
  
  for i in 0..<min(peaks.len, sequence.len):
    let peakPos = peaks[i]
    
    # Only add to result if visible and within drawable area
    if peakPos >= displayStart and peakPos < displayEnd:
      # Get X position on the SVG
      let x = scaleFn(peakPos)
      
      # Only include if within drawable area
      if x > padding and x < (width - padding):
        let baseChar = sequence[i]
        result.add((x, peakPos, baseChar))

proc renderChromatogramSvg*(
  data: TraceData,
  sampleName: string,
  width: int = 1200,
  height: int = 600,
  showBaseCalls: bool = true,
  startPos: int = 0,
  endPos: int = -1,
  downsample: int = 1,
  highlights: seq[HighlightRegion] = @[]
): string {.gcsafe.} =
  ## Renders the chromatogram as an in-memory SVG string (for embedding in
  ## reports, e.g. `abiscreen`'s HTML evidence panels) rather than writing
  ## directly to a file. Returns "" if the requested range has no data.
  ##
## Command-line usage:
##
## .. code-block:: none
##   abichromatogram <trace_file.ab1> [options]
##
## Options:
##   -o, --output FILE       Output SVG file (default: chromatogram.svg)
##       --html FILE         Output a portable HTML report with embedded SVG
##   -w, --width WIDTH       SVG width in pixels (default: 1200)
##       --height HEIGHT     SVG height in pixels (default: 600)
##   -s, --start POS         Start position (default: 0)
##   -e, --end POS           End position (default: whole trace)
##   -d, --downsample FACTOR Downsample factor for visualization (default: 1)
##       --highlight START-END
##                            Highlight a trace scan region; repeat or comma-separate
##       --hide-bases        Hide base calls
##       --debug             Show debug information
##   -h, --help              Show this help message and exit
##   -v, --version           Show version information and exit
##
## Examples:
##
## .. code-block:: none
##   # Generate a basic chromatogram
##   abichromatogram input.ab1
##
##   # Specify output file and downsample for smoother display
##   abichromatogram input.ab1 -o output.svg -d 5
##
##   # Generate a portable HTML report
##   abichromatogram input.ab1 --html output.html
##
##   # Generate a zoomed view of a specific region with custom width
##   abichromatogram input.ab1 -s 500 -e 1000 --width 1600
##
##   # Highlight one or more scan regions
##   abichromatogram input.ab1 --highlight 540-620,780-830
##
##   # Generate a chromatogram without base call markers
##   abichromatogram input.ab1 --hide-bases

  # Calculate dimensions and scaling
  let padding = 50
  let titleHeight = 30
  let topPadding = padding + titleHeight
  let plotHeight = height - padding - topPadding
  let sample_name = sampleName

  # Calculate the range to display
  let dataLen = data.traceLen
  let displayStart = max(0, startPos)
  let displayEnd = if endPos < 0: dataLen else: min(dataLen, endPos)
  let displayLen = displayEnd - displayStart

  if displayLen <= 0:
    return ""

  let effectiveLen = (displayLen + downsample - 1) div downsample  # Ceiling division
  let xScale = (width - (2 * padding)).float / effectiveLen.float
  
  # Helper to calculate the x coordinate for a peak position
  proc getXCoordinate(peakPos: int): int =
    let scaledPos = (peakPos - displayStart) div downsample
    result = padding + (scaledPos.float * xScale).int
  
  # Prepare polylines for each channel
  var channelPolylines: Table[Channel, string]
  for ch in [A, C, G, T]:
    channelPolylines[ch] = generatePolyline(
      data.points, ch, displayStart, displayEnd, downsample,
      padding, topPadding, plotHeight, xScale
    )
  
  # Prepare visible peaks for drawing
  var visiblePeaks: seq[tuple[x, peakPos: int, baseChar: char]] = @[]
  if showBaseCalls:
    visiblePeaks = getVisiblePeaks(
      data.peaks, data.sequence, 
      displayStart, displayEnd, 
      padding, width, topPadding,
      getXCoordinate
    )
  
  # Build the SVG document in memory
  let nodes = buildSvg:
    svg(width=width, height=height):
      # Title
      text(x=width div 2, y=titleHeight, `text-anchor`="middle", 
           `font-family`="Arial", `font-size`=20, `font-weight`="bold"):
        t &"Chromatogram: {sample_name}"
      
      # White background
      rect(x=padding, y=topPadding, width=width-(2*padding), height=plotHeight,
           fill="white", stroke="none")

      # Draw highlighted trace scan regions under the grid and signal lines
      for region in highlights:
        let regionStart = max(displayStart, min(region.startPos, region.endPos))
        let regionEnd = min(displayEnd, max(region.startPos, region.endPos) + 1)
        if regionEnd > regionStart:
          let x1 = padding + (((regionStart - displayStart).float / downsample.float) * xScale).int
          let x2 = padding + (((regionEnd - displayStart).float / downsample.float) * xScale).int
          let rectX = max(padding, x1)
          let rectWidth = max(1, min(width - padding, x2) - rectX)
          let fill = if region.fill.len > 0: region.fill else: DefaultHighlightFill
          rect(x=rectX, y=topPadding, width=rectWidth, height=plotHeight,
               fill=fill, `fill-opacity`="0.65", stroke="none")
          if region.label.len > 0:
            text(x=rectX + (rectWidth div 2), y=topPadding + 16,
                 `text-anchor`="middle", fill="#6b5b00",
                 `font-family`="Arial", `font-size`=12):
              t region.label

      # Plot border
      rect(x=padding, y=topPadding, width=width-(2*padding), height=plotHeight,
           fill="none", stroke="black", `stroke-width`=1)
      
      # Draw grid lines
      let gridStep = 100
      for i in countup(0, effectiveLen, gridStep):
        let x = padding + (i.float * xScale).int
        if x > padding and x < (width - padding):
          # Vertical grid line
          line(x1=x, y1=topPadding, x2=x, y2=topPadding+plotHeight, 
               stroke="#DDDDDD", `stroke-width`=1)
      
      # Draw base position markers
      for pos in countup(0, displayLen, 100):
        let x = padding + ((pos div downsample).float * xScale).int
        if x > padding and x < (width - padding):
          # Position label
          let actualPos = displayStart + pos
          text(x=x, y=topPadding+plotHeight+20, `text-anchor`="middle", fill="black",
               `font-family`="Arial", `font-size`=12):
            t $actualPos
      
      # Draw each channel polyline
      for ch in [A, C, G, T]:
        let color = data.baseColors[ch]
        let points = channelPolylines[ch]
        
        if points.len > 0:
          polyline(points=points, fill="none", stroke=color, `stroke-width`=1.5)
      
      # Draw peak markers and base calls
      if showBaseCalls and visiblePeaks.len > 0:
        for peakInfo in visiblePeaks:
          let x = peakInfo.x
          let baseChar = peakInfo.baseChar
          
          # Get color based on the base
          let color = case baseChar:
            of 'A': data.baseColors[A]
            of 'C': data.baseColors[C]
            of 'G': data.baseColors[G]
            of 'T': data.baseColors[T]
            else: "black"
          
          # Draw vertical line at peak
          line(x1=x, y1=topPadding+plotHeight, x2=x, y2=topPadding, 
               stroke="#BBBBBB", `stroke-width`=0.5, `stroke-dasharray`="2,2")
          
          # Draw base letter
          text(x=x, y=topPadding-10, `text-anchor`="middle", fill=color,
               `font-family`="monospace", `font-weight`="bold", `font-size`=14):
            t $baseChar
        
        # Display count of bases in view
        text(x=width-padding, y=height-10, `text-anchor`="end", fill="black",
             `font-family`="Arial", `font-size`=12):
          t &"Showing {visiblePeaks.len} of {data.sequence.len} bases"
      
      # Add legend
      let legendX = padding + 10
      let legendY = topPadding + 25
      let legendSpacing = 80
      
      for i, ch in [A, C, G, T]:
        let x = legendX + (i * legendSpacing)
        let color = data.baseColors[ch]
        
        # Draw legend line
        line(x1=x, y1=legendY, x2=x+30, y2=legendY, 
             stroke=color, `stroke-width`=2)
        
        # Draw legend text
        text(x=x+40, y=legendY+5, `text-anchor`="start", fill=color,
             `font-family`="Arial", `font-size`=14, `font-weight`="bold"):
          t $ch

  nodes.render()

proc renderChromatogram(
  data: TraceData,
  outFile: string,
  width: int = 1200,
  height: int = 600,
  showBaseCalls: bool = true,
  startPos: int = 0,
  endPos: int = -1,
  downsample: int = 1,
  highlights: seq[HighlightRegion] = @[]
): bool =
  ## Generates the SVG chromatogram and writes it to `outFile`. Thin wrapper
  ## around `renderChromatogramSvg` kept for CLI/back-compat use.
  let sampleName = outFile.extractFilename.changeFileExt("")
  let svgText = renderChromatogramSvg(data, sampleName, width, height,
                                       showBaseCalls, startPos, endPos,
                                       downsample, highlights)
  if svgText.len == 0:
    return false

  let parent = outFile.parentDir
  if parent != "":
    createDir(parent)
  writeFile(outFile, svgText)
  result = true

proc htmlEscape*(s: string): string =
  ## Escapes text for safe inclusion in generated HTML.
  for ch in s:
    case ch
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    else: result.add(ch)

proc traceValue(trace: ABIFTrace, key: string): string =
  if trace.data.hasKey(key):
    trace.data[key]
  else:
    ""

proc joinedDateTime(trace: ABIFTrace, dateKey, timeKey: string): string =
  let dateVal = traceValue(trace, dateKey)
  let timeVal = traceValue(trace, timeKey)
  if dateVal.len > 0 and timeVal.len > 0:
    dateVal & " " & timeVal
  elif dateVal.len > 0:
    dateVal
  else:
    timeVal

proc averageQuality(qualities: seq[int]): string =
  if qualities.len == 0:
    return "n/a"
  var total = 0
  for q in qualities:
    total += q
  $int(round(total.float / qualities.len.float))

type MetadataRow = tuple[label: string, value: string]

proc collectMetadataRows(
  trace: ABIFTrace,
  data: TraceData,
  inputFile: string,
  qualities: seq[int],
  startPos, endPos, downsample: int
): seq[MetadataRow] =
  var rows: seq[MetadataRow] = @[]

  proc addRow(label, value: string) =
    if value.len > 0:
      rows.add((label: label, value: value))

  let sampleName = trace.getSampleName()
  let displayStart = max(0, startPos)
  let displayEnd = if endPos < 0: data.traceLen else: min(data.traceLen, endPos)
  let tagNames = trace.getTagNames()
  let channelSource = if tagNames.anyIt(it == "DATA9"):
                        "DATA9-DATA12 (processed)"
                      else:
                        "DATA1-DATA4 (raw)"

  addRow("File", inputFile.extractFilename)
  addRow("Sample name", sampleName)
  addRow("ABIF version", $trace.version)
  addRow("Read length", $data.sequence.len & " bp")
  addRow("Quality values", $qualities.len)
  addRow("Mean quality", averageQuality(qualities))
  addRow("Trace scans", $data.traceLen)
  addRow("Displayed scan range", $displayStart & "-" & $displayEnd)
  addRow("Downsample", $downsample)
  addRow("Base order (FWO_1)", data.baseOrder)
  addRow("Trace channels", channelSource)
  addRow("Instrument model", traceValue(trace, "model"))
  addRow("Polymer", traceValue(trace, "polymer"))
  addRow("Dye set", traceValue(trace, "dye"))
  addRow("Well", traceValue(trace, "well"))
  addRow("Run started", joinedDateTime(trace, "run_start_date", "run_start_time"))
  addRow("Run finished", joinedDateTime(trace, "run_finish_date", "run_finish_time"))
  addRow("Collection started", joinedDateTime(trace, "data_collection_start_date", "data_collection_start_time"))
  addRow("Collection finished", joinedDateTime(trace, "data_collection_finish_date", "data_collection_finish_time"))

  rows

proc jsString(s: string): string =
  ## Quotes a Nim string for safe inclusion in an inline JavaScript object.
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '<': result.add("\\u003C")
    of '>': result.add("\\u003E")
    of '&': result.add("\\u0026")
    else:
      if ord(ch) < 32:
        result.add("\\u")
        result.add(toHex(ord(ch), 4))
      else:
        result.add(ch)
  result.add("\"")

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, value in values:
    if i > 0:
      result.add(",")
    result.add($value)
  result.add("]")

proc channelValues(
  data: TraceData,
  ch: Channel,
  displayStart, displayEnd, downsample: int
): seq[int] =
  for pos in countup(displayStart, displayEnd - 1, downsample):
    result.add(getMaxInBin(data.points, ch, pos, min(pos + downsample, displayEnd)))

proc metadataRowsJson(rows: seq[MetadataRow]): string =
  result = "["
  for row in rows:
    if result.len > 1:
      result.add(",")
    result.add("[")
    result.add(jsString(row.label))
    result.add(",")
    result.add(jsString(row.value))
    result.add("]")
  result.add("]")

proc highlightsJson(highlights: seq[HighlightRegion]): string =
  result = "["
  for region in highlights:
    if result.len > 1:
      result.add(",")
    let regionStart = min(region.startPos, region.endPos)
    let regionEnd = max(region.startPos, region.endPos)
    result.add("{\"start\":")
    result.add($regionStart)
    result.add(",\"end\":")
    result.add($regionEnd)
    result.add(",\"fill\":")
    result.add(jsString(if region.fill.len > 0: region.fill else: DefaultHighlightFill))
    result.add(",\"label\":")
    result.add(jsString(region.label))
    result.add("}")
  result.add("]")

proc tracePayloadJson(
  trace: ABIFTrace,
  data: TraceData,
  inputFile: string,
  width, height: int,
  showBaseCalls: bool,
  startPos, endPos, downsample: int,
  highlights: seq[HighlightRegion]
): string =
  var sampleName = trace.getSampleName()
  if sampleName.len == 0:
    sampleName = inputFile.extractFilename.changeFileExt("")

  let qualities = trace.getQualityValues()
  let displayStart = max(0, startPos)
  let displayEnd = if endPos < 0: data.traceLen else: min(data.traceLen, endPos)
  let effectiveDownsample = max(1, downsample)
  let metadataRows = collectMetadataRows(trace, data, inputFile, qualities,
                                         displayStart, displayEnd,
                                         effectiveDownsample)

  result = "{"
  result.add("\"fileName\":")
  result.add(jsString(inputFile.extractFilename))
  result.add(",\"sampleName\":")
  result.add(jsString(sampleName))
  result.add(",\"abifVersion\":")
  result.add($trace.version)
  result.add(",\"sequence\":")
  result.add(jsString(data.sequence))
  result.add(",\"qualities\":")
  result.add(jsIntArray(qualities))
  result.add(",\"meanQuality\":")
  result.add(jsString(averageQuality(qualities)))
  result.add(",\"peaks\":")
  result.add(jsIntArray(data.peaks))
  result.add(",\"traceStart\":")
  result.add($displayStart)
  result.add(",\"traceEnd\":")
  result.add($displayEnd)
  result.add(",\"traceStep\":")
  result.add($effectiveDownsample)
  result.add(",\"traceLen\":")
  result.add($data.traceLen)
  result.add(",\"baseOrder\":")
  result.add(jsString(data.baseOrder))
  result.add(",\"showBases\":")
  result.add(if showBaseCalls: "true" else: "false")
  result.add(",\"requestedWidth\":")
  result.add($width)
  result.add(",\"requestedHeight\":")
  result.add($height)
  result.add(",\"channels\":{\"A\":")
  result.add(jsIntArray(channelValues(data, A, displayStart, displayEnd, effectiveDownsample)))
  result.add(",\"C\":")
  result.add(jsIntArray(channelValues(data, C, displayStart, displayEnd, effectiveDownsample)))
  result.add(",\"G\":")
  result.add(jsIntArray(channelValues(data, G, displayStart, displayEnd, effectiveDownsample)))
  result.add(",\"T\":")
  result.add(jsIntArray(channelValues(data, T, displayStart, displayEnd, effectiveDownsample)))
  result.add("},\"metadata\":")
  result.add(metadataRowsJson(metadataRows))
  result.add(",\"highlights\":")
  result.add(highlightsJson(highlights))
  result.add("}")

proc renderChromatogramHtml*(
  trace: ABIFTrace,
  data: TraceData,
  inputFile: string,
  width: int = 1200,
  height: int = 600,
  showBaseCalls: bool = true,
  startPos: int = 0,
  endPos: int = -1,
  downsample: int = 1,
  highlights: seq[HighlightRegion] = @[]
): string =
  ## Renders a portable, dependency-free HTML viewer with embedded chromatogram
  ## data. The exported file is self-contained and supports scrolling, zooming,
  ## metadata inspection, and sequence-to-trace recentering in the browser.
  var sampleName = trace.getSampleName()
  if sampleName.len == 0:
    sampleName = inputFile.extractFilename.changeFileExt("")

  let displayStart = max(0, startPos)
  let displayEnd = if endPos < 0: data.traceLen else: min(data.traceLen, endPos)
  if displayEnd <= displayStart:
    return ""

  let title = if sampleName.len > 0: sampleName else: "chromatogram"
  let escapedTitle = htmlEscape(title)
  let payload = tracePayloadJson(trace, data, inputFile, width, height,
                                 showBaseCalls, startPos, endPos,
                                 downsample, highlights)

  result = "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
  result.add("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
  result.add("<title>")
  result.add(escapedTitle)
  result.add(" chromatogram</title>\n<style>\n")
  result.add("""
:root{
  --bg:#111414; --panel:#181C1B; --panel-2:#202625; --line:#2F3836;
  --line-strong:#46504D; --text:#E9EFEC; --muted:#8B9893; --amber:#DFA84B;
  --A:#58B875; --C:#4B91D1; --G:#D9DFDD; --T:#D95662; --trace-pane-height:34%;
}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:var(--bg);color:var(--text);font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;overflow:hidden}
body.resizing{cursor:row-resize;user-select:none}
.mono{font-family:"IBM Plex Mono","SFMono-Regular",Consolas,monospace}
#app{display:flex;flex-direction:column;height:100vh;min-width:0}
header{display:flex;align-items:center;gap:18px;padding:0 18px;height:52px;flex-shrink:0;background:var(--panel);border-bottom:1px solid var(--line);min-width:0}
.filename{display:flex;align-items:center;gap:8px;min-width:150px;font-size:14px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.filename .dot{width:8px;height:8px;border-radius:50%;flex:0 0 auto;background:var(--A)}
.stat{font-size:12.5px;color:var(--muted);white-space:nowrap}
.stat b{color:var(--text);font-weight:500}
.legend{display:flex;gap:10px;margin-left:auto}
.legend span{display:flex;align-items:center;gap:5px;font-size:12px;color:var(--muted)}
.legend i{width:9px;height:9px;border-radius:2px;display:inline-block}
.zoom-wrap{display:flex;align-items:center;gap:8px}
.zoom-wrap label{font-size:11.5px;color:var(--muted)}
input[type=range]{-webkit-appearance:none;width:116px;height:2px;background:var(--line-strong);border-radius:2px;outline:none}
input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:12px;height:12px;border-radius:50%;background:var(--amber);cursor:pointer;border:2px solid var(--bg)}
input[type=range]::-moz-range-thumb{width:12px;height:12px;border-radius:50%;background:var(--amber);cursor:pointer;border:2px solid var(--bg)}
.icon-btn,.text-btn{background:var(--panel-2);border:1px solid var(--line);color:var(--text);height:32px;border-radius:6px;cursor:pointer;display:flex;align-items:center;justify-content:center;font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;transition:border-color .15s,color .15s,background .15s}
.icon-btn{width:32px;flex:0 0 auto;font-size:13px;font-weight:600}
.text-btn{padding:0 11px;font-size:11.5px}
.icon-btn:hover,.text-btn:hover{border-color:var(--muted)}
.icon-btn.active{border-color:var(--amber);color:var(--amber)}
#workspace{display:flex;flex-direction:column;flex:1;min-height:0}
#viewer-region{flex:0 0 var(--trace-pane-height);display:flex;flex-direction:column;min-width:0;min-height:160px;padding:12px 0 0;position:relative;background:var(--bg)}
#scroller{overflow-x:auto;overflow-y:hidden;flex:1;min-height:0;position:relative;border-top:1px solid var(--line);border-bottom:1px solid var(--line)}
#scroller::-webkit-scrollbar{height:9px}
#scroller::-webkit-scrollbar-track{background:var(--panel)}
#scroller::-webkit-scrollbar-thumb{background:#48534F;border-radius:5px}
#track{position:relative;height:100%}
#ruler{position:sticky;top:0;height:22px;display:block;z-index:2}
#trace-canvas{display:block}
#bases-row{position:relative;height:26px}
.base-cell{appearance:none;background:transparent;border:0;border-top:1px solid transparent;padding:0;font-family:"IBM Plex Mono","SFMono-Regular",Consolas,monospace;position:absolute;top:0;display:flex;align-items:center;justify-content:center;height:26px;font-size:12px;font-weight:600;cursor:pointer;transform:translateX(-50%)}
.base-cell.selected{background:rgba(223,168,75,.16);border-top-color:var(--amber)}
#crosshair,#selection-marker{position:absolute;top:22px;bottom:26px;width:1px;pointer-events:none;display:none}
#crosshair{background:rgba(223,168,75,.5)}
#selection-marker{background:var(--amber);box-shadow:0 0 0 1px rgba(223,168,75,.28)}
#tooltip{position:absolute;top:2px;transform:translateX(-50%);background:var(--panel-2);border:1px solid var(--line);border-radius:4px;padding:3px 7px;font-size:11px;white-space:nowrap;pointer-events:none;display:none;z-index:4}
.viewport-status{min-height:25px;padding:6px 18px 7px;font-size:11px;color:var(--muted);flex-shrink:0}
#splitter{height:12px;flex:0 0 12px;cursor:row-resize;background:var(--panel);border-top:1px solid var(--line);border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:center;outline:none}
#splitter::before{content:"";width:48px;height:3px;border-radius:3px;background:var(--line-strong)}
#splitter:hover::before,#splitter:focus-visible::before{background:var(--amber)}
#seq-panel{flex:1 1 auto;background:var(--panel);padding:12px 18px 16px;display:flex;flex-direction:column;min-width:0;min-height:160px}
.seq-head{display:flex;align-items:center;gap:14px;margin-bottom:8px;min-width:0}
.seq-head h2{font-size:12px;font-weight:600;margin:0;color:var(--muted);font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;white-space:nowrap}
.seq-head .count{color:var(--text);font-weight:500}
#seq-mini-status{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--muted);font-size:11px}
#copy-btn{margin-left:auto;flex:0 0 auto}
#seq-text{flex:1;min-height:0;font-size:13px;line-height:1.9;letter-spacing:0;overflow:auto;user-select:text;word-break:break-all;padding:4px 0 8px}
.seq-base{display:inline-block;min-width:1ch;border-radius:2px;cursor:pointer;text-align:center;border-bottom:2px solid transparent}
.seq-base:hover{background:rgba(233,239,236,.1)}
.seq-base.in-view{background:rgba(223,168,75,.19);border-bottom-color:rgba(223,168,75,.72)}
.seq-base.selected-base{background:var(--amber);color:#151614;border-bottom-color:var(--amber);font-weight:600}
.seq-base.out-of-range{opacity:.35;cursor:default}
.base-A{color:var(--A)} .base-C{color:var(--C)} .base-G{color:var(--G)} .base-T{color:var(--T)} .base-other{color:var(--muted)}
#drawer{position:fixed;top:0;right:0;height:100%;width:300px;background:var(--panel);border-left:1px solid var(--line);transform:translateX(100%);transition:transform .22s ease;z-index:10;padding:18px;overflow-y:auto}
#drawer.open{transform:translateX(0)}
#drawer h3{font-size:13px;margin:0 0 16px;color:var(--text)}
.meta-row{padding:9px 0;border-bottom:1px solid var(--line)}
.meta-row .k{font-size:10.5px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
.meta-row .v{font-size:13px;margin-top:3px;overflow-wrap:anywhere}
#scrim{position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:9;opacity:0;pointer-events:none;transition:opacity .2s}
#scrim.open{opacity:1;pointer-events:auto}
@media (max-width:760px){
  header{gap:10px;padding:0 12px}
  .legend,.stat{display:none}
  input[type=range]{width:86px}
  #seq-mini-status{display:none}
  #drawer{width:min(320px,88vw)}
}
""")
  result.add("</style>\n</head>\n<body>\n<div id=\"app\">\n")
  result.add("""
  <header>
    <div class="filename"><span class="dot" aria-hidden="true"></span><span id="file-name"></span></div>
    <div class="stat"><b id="stat-len"></b> bp</div>
    <div class="stat">Q avg <b id="stat-q"></b></div>
    <div class="legend">
      <span><i style="background:var(--A)"></i>A</span>
      <span><i style="background:var(--C)"></i>C</span>
      <span><i style="background:var(--G)"></i>G</span>
      <span><i style="background:var(--T)"></i>T</span>
    </div>
    <div class="zoom-wrap">
      <label for="zoom">Zoom</label>
      <input type="range" id="zoom" min="0.18" max="3" step="0.02" value="0.75">
    </div>
    <button class="icon-btn" id="meta-toggle" type="button" title="Metadata" aria-label="Metadata">i</button>
  </header>
  <main id="workspace">
    <section id="viewer-region" aria-label="Chromatogram">
      <div id="scroller">
        <div id="track">
          <canvas id="ruler"></canvas>
          <canvas id="trace-canvas"></canvas>
          <div id="bases-row"></div>
          <div id="selection-marker"></div>
          <div id="crosshair"></div>
          <div id="tooltip"></div>
        </div>
      </div>
      <div class="viewport-status" id="viewport-status"></div>
    </section>
    <div id="splitter" role="separator" aria-orientation="horizontal" aria-label="Resize trace panel" tabindex="0"></div>
    <section id="seq-panel" aria-label="Sequence">
      <div class="seq-head">
        <h2>SEQUENCE | <span class="count" id="seq-count"></span> bp</h2>
        <div id="seq-mini-status"></div>
        <button class="text-btn" id="copy-btn" type="button">Copy sequence</button>
      </div>
      <div id="seq-text" class="mono"></div>
    </section>
  </main>
</div>
<div id="scrim"></div>
<aside id="drawer" aria-label="Trace metadata">
  <h3>Trace metadata</h3>
  <div id="meta-rows"></div>
</aside>
<script>
const TRACE = """)
  result.add(payload)
  result.add(""";
const BASES = ['A','C','G','T'];
const COLORS = { A:'#58B875', C:'#4B91D1', G:'#D9DFDD', T:'#D95662' };
const RULER_HEIGHT = 22;
const BASE_ROW_HEIGHT = 26;
const sequence = TRACE.sequence.split('');
const quality = TRACE.qualities;
const peaks = TRACE.peaks;
const traces = TRACE.channels;
const N = sequence.length;
const scanStart = TRACE.traceStart;
const scanEnd = TRACE.traceEnd;
const scanStep = Math.max(1, TRACE.traceStep || 1);
const traceScanLength = Math.max(1, scanEnd - scanStart);

let pxPerScan = Math.min(3, Math.max(0.18, (Math.max(N, 1) * 12) / traceScanLength));
let selectedBaseIndex = null;
let scrollRaf = null;
let baseCells = [];
const workspace = document.getElementById('workspace');
const viewerRegion = document.getElementById('viewer-region');
const splitter = document.getElementById('splitter');
const scroller = document.getElementById('scroller');
const track = document.getElementById('track');
const rulerCv = document.getElementById('ruler');
const traceCv = document.getElementById('trace-canvas');
const basesRow = document.getElementById('bases-row');
const crosshair = document.getElementById('crosshair');
const selectionMarker = document.getElementById('selection-marker');
const tooltip = document.getElementById('tooltip');
const seqText = document.getElementById('seq-text');
const viewportStatus = document.getElementById('viewport-status');
const seqMiniStatus = document.getElementById('seq-mini-status');
const sequenceEls = [];

document.getElementById('file-name').textContent = TRACE.sampleName || TRACE.fileName || 'chromatogram';
document.getElementById('stat-len').textContent = N;
document.getElementById('stat-q').textContent = TRACE.meanQuality;
document.getElementById('seq-count').textContent = N;
document.getElementById('zoom').value = String(pxPerScan);

function clamp(value, min, max){ return Math.min(max, Math.max(min, value)); }
function baseClass(base){ return BASES.includes(base) ? `base-${base}` : 'base-other'; }
function baseInRange(index){
  const peak = peaks[index];
  return Number.isFinite(peak) && peak >= scanStart && peak < scanEnd;
}
function peakToX(index){
  return (peaks[index] - scanStart) * pxPerScan;
}
function scanAtX(x){
  return scanStart + x / pxPerScan;
}
function channelAtScan(base, scan){
  const arr = traces[base] || [];
  const idx = clamp(Math.round((scan - scanStart) / scanStep), 0, Math.max(0, arr.length - 1));
  return arr[idx] || 0;
}
function nearestBaseIndex(scan){
  let best = -1;
  let bestDistance = Infinity;
  for(let i = 0; i < peaks.length; i++){
    if(!baseInRange(i)) continue;
    const distance = Math.abs(peaks[i] - scan);
    if(distance < bestDistance){
      best = i;
      bestDistance = distance;
    }
  }
  return best;
}
function niceStep(raw){
  if(raw <= 0) return 100;
  const power = Math.pow(10, Math.floor(Math.log10(raw)));
  const fraction = raw / power;
  const nice = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10;
  return nice * power;
}
function escapeText(value){
  return value == null ? '' : String(value);
}

function buildMetadata(){
  const rows = document.getElementById('meta-rows');
  const frag = document.createDocumentFragment();
  for(const [key, value] of TRACE.metadata){
    const row = document.createElement('div');
    row.className = 'meta-row';
    const k = document.createElement('div');
    k.className = 'k';
    k.textContent = key;
    const v = document.createElement('div');
    v.className = 'v mono';
    v.textContent = value;
    row.append(k, v);
    frag.appendChild(row);
  }
  rows.replaceChildren(frag);
}

function buildSequencePanel(){
  const frag = document.createDocumentFragment();
  for(let i = 0; i < N; i++){
    const b = sequence[i].toUpperCase();
    const el = document.createElement('span');
    el.className = `seq-base ${baseClass(b)}`;
    if(!baseInRange(i)) el.classList.add('out-of-range');
    el.dataset.i = String(i);
    el.textContent = b;
    el.title = `${i + 1} ${b} Q${quality[i] ?? 0}`;
    sequenceEls[i] = el;
    frag.appendChild(el);
  }
  seqText.replaceChildren(frag);
}

function tracePaneLimits(){
  const h = workspace.clientHeight;
  return { min: Math.min(220, Math.max(140, h * 0.22)), max: Math.max(180, h - 170) };
}
function setTracePaneHeight(nextHeight){
  const limits = tracePaneLimits();
  const height = clamp(nextHeight, limits.min, limits.max);
  viewerRegion.style.flexBasis = `${height}px`;
  splitter.setAttribute('aria-valuenow', String(Math.round(height)));
  splitter.setAttribute('aria-valuemin', String(Math.round(limits.min)));
  splitter.setAttribute('aria-valuemax', String(Math.round(limits.max)));
  layout();
}

function layout(){
  const width = Math.max(scroller.clientWidth, Math.ceil(traceScanLength * pxPerScan));
  const traceHeight = Math.max(scroller.clientHeight - RULER_HEIGHT - BASE_ROW_HEIGHT, 60);
  track.style.width = `${width}px`;
  track.style.height = `${RULER_HEIGHT + traceHeight + BASE_ROW_HEIGHT}px`;
  rulerCv.width = width;
  rulerCv.height = RULER_HEIGHT;
  rulerCv.style.width = `${width}px`;
  rulerCv.style.height = `${RULER_HEIGHT}px`;
  traceCv.width = width;
  traceCv.height = traceHeight;
  traceCv.style.width = `${width}px`;
  traceCv.style.height = `${traceHeight}px`;
  drawRuler();
  drawTrace();
  buildBasesRow();
  updateHighlight();
  updateSelectionMarker();
}

function drawRuler(){
  const ctx = rulerCv.getContext('2d');
  ctx.fillStyle = '#181C1B';
  ctx.fillRect(0, 0, rulerCv.width, rulerCv.height);
  ctx.strokeStyle = '#2F3836';
  ctx.fillStyle = '#8B9893';
  ctx.font = "11px ui-monospace, 'SFMono-Regular', Menlo, Consolas, monospace";
  const step = niceStep(130 / pxPerScan);
  const first = Math.ceil(scanStart / step) * step;
  for(let scan = first; scan <= scanEnd; scan += step){
    const x = (scan - scanStart) * pxPerScan;
    ctx.beginPath();
    ctx.moveTo(x + 0.5, 14);
    ctx.lineTo(x + 0.5, RULER_HEIGHT);
    ctx.stroke();
    ctx.fillText(String(scan), x + 3, 12);
  }
}

function drawTrace(){
  const ctx = traceCv.getContext('2d');
  const w = traceCv.width;
  const h = traceCv.height;
  const pad = 6;
  const plotH = h - pad * 2;
  ctx.clearRect(0, 0, w, h);
  ctx.fillStyle = '#111414';
  ctx.fillRect(0, 0, w, h);

  for(const region of TRACE.highlights){
    const regionStart = clamp(Math.min(region.start, region.end), scanStart, scanEnd);
    const regionEnd = clamp(Math.max(region.start, region.end), scanStart, scanEnd);
    if(regionEnd <= regionStart) continue;
    ctx.globalAlpha = 0.18;
    ctx.fillStyle = region.fill || '#DFA84B';
    ctx.fillRect((regionStart - scanStart) * pxPerScan, 0, (regionEnd - regionStart) * pxPerScan, h);
    ctx.globalAlpha = 1;
  }

  ctx.strokeStyle = 'rgba(47,56,54,.48)';
  const gridStep = niceStep(100 / pxPerScan);
  const firstGrid = Math.ceil(scanStart / gridStep) * gridStep;
  for(let scan = firstGrid; scan <= scanEnd; scan += gridStep){
    const x = (scan - scanStart) * pxPerScan;
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, h);
    ctx.stroke();
  }

  for(const b of BASES){
    const arr = traces[b] || [];
    if(arr.length === 0) continue;
    ctx.beginPath();
    ctx.strokeStyle = COLORS[b];
    ctx.lineWidth = 1.55;
    for(let s = 0; s < arr.length; s++){
      const x = s * scanStep * pxPerScan;
      const y = h - pad - (arr[s] / 1000) * plotH;
      if(s === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
  }
}

function buildBasesRow(){
  basesRow.replaceChildren();
  baseCells = [];
  if(!TRACE.showBases) return;
  const frag = document.createDocumentFragment();
  for(let i = 0; i < N; i++){
    if(!baseInRange(i)) continue;
    const b = sequence[i].toUpperCase();
    const el = document.createElement('button');
    el.type = 'button';
    el.className = 'base-cell';
    el.style.left = `${peakToX(i)}px`;
    el.style.width = `${Math.max(12, Math.min(22, pxPerScan * 22))}px`;
    el.style.color = COLORS[b] || '#8B9893';
    el.textContent = pxPerScan >= 0.28 ? b : '';
    el.dataset.i = String(i);
    if(i === selectedBaseIndex) el.classList.add('selected');
    baseCells[i] = el;
    frag.appendChild(el);
  }
  basesRow.appendChild(frag);
}

function visibleScanRange(){
  return [scanAtX(scroller.scrollLeft), scanAtX(scroller.scrollLeft + scroller.clientWidth)];
}
function visibleBaseRange(scanLo, scanHi){
  let first = -1;
  let last = -1;
  for(let i = 0; i < peaks.length; i++){
    if(peaks[i] >= scanLo && peaks[i] <= scanHi){
      if(first < 0) first = i;
      last = i;
    }
  }
  return [first, last];
}
function updateSequenceHighlight(scanLo, scanHi){
  for(let i = 0; i < sequenceEls.length; i++){
    const inView = peaks[i] >= scanLo && peaks[i] <= scanHi;
    sequenceEls[i].classList.toggle('in-view', inView);
    sequenceEls[i].classList.toggle('selected-base', i === selectedBaseIndex);
  }
  for(let i = 0; i < baseCells.length; i++){
    if(baseCells[i]) baseCells[i].classList.toggle('selected', i === selectedBaseIndex);
  }
}
function updateHighlight(){
  const [scanLo, scanHi] = visibleScanRange();
  const [firstBase, lastBase] = visibleBaseRange(scanLo, scanHi);
  updateSequenceHighlight(scanLo, scanHi);
  const shown = firstBase < 0 ? 'no called bases' : `bases ${firstBase + 1}-${lastBase + 1}`;
  const selectedText = selectedBaseIndex === null ? '' :
    ` | selected ${selectedBaseIndex + 1} ${sequence[selectedBaseIndex]} Q${quality[selectedBaseIndex] ?? 0}`;
  viewportStatus.textContent = `${shown} | scans ${Math.round(scanLo)}-${Math.round(scanHi)} of ${TRACE.traceLen}${selectedText}`;
  seqMiniStatus.textContent = `Visible ${shown}${selectedText}`;
}
function updateSelectionMarker(){
  if(selectedBaseIndex === null || !baseInRange(selectedBaseIndex)){
    selectionMarker.style.display = 'none';
    return;
  }
  selectionMarker.style.display = 'block';
  selectionMarker.style.left = `${peakToX(selectedBaseIndex)}px`;
}
function centerOnBase(index, behavior = 'smooth'){
  if(!baseInRange(index)){
    selectedBaseIndex = index;
    updateHighlight();
    return;
  }
  selectedBaseIndex = index;
  const target = peakToX(index) - scroller.clientWidth / 2;
  const maxScroll = Math.max(0, track.offsetWidth - scroller.clientWidth);
  scroller.scrollTo({ left: clamp(target, 0, maxScroll), behavior });
  updateSelectionMarker();
  updateHighlight();
}

scroller.addEventListener('scroll', () => {
  if(scrollRaf) return;
  scrollRaf = requestAnimationFrame(() => {
    updateHighlight();
    scrollRaf = null;
  });
});
document.getElementById('zoom').addEventListener('input', (e) => {
  const oldPx = pxPerScan;
  const centerScan = scanStart + (scroller.scrollLeft + scroller.clientWidth / 2) / oldPx;
  pxPerScan = parseFloat(e.target.value);
  layout();
  scroller.scrollLeft = (centerScan - scanStart) * pxPerScan - scroller.clientWidth / 2;
  updateHighlight();
});
traceCv.addEventListener('mousemove', (e) => {
  const rect = traceCv.getBoundingClientRect();
  const x = e.clientX - rect.left;
  const scan = scanAtX(x);
  const idx = nearestBaseIndex(scan);
  crosshair.style.display = 'block';
  crosshair.style.left = `${x}px`;
  tooltip.style.display = 'block';
  tooltip.style.left = `${x}px`;
  if(idx >= 0){
    const values = BASES.map(b => `${b}:${channelAtScan(b, scan)}`).join(' ');
    tooltip.textContent = `scan ${Math.round(scan)} | ${idx + 1} ${sequence[idx]} Q${quality[idx] ?? 0} | ${values}`;
  }else{
    tooltip.textContent = `scan ${Math.round(scan)}`;
  }
});
traceCv.addEventListener('mouseleave', () => {
  crosshair.style.display = 'none';
  tooltip.style.display = 'none';
});
seqText.addEventListener('click', (e) => {
  const base = e.target.closest('.seq-base');
  if(!base || base.classList.contains('out-of-range')) return;
  centerOnBase(parseInt(base.dataset.i, 10));
});
basesRow.addEventListener('click', (e) => {
  const base = e.target.closest('.base-cell');
  if(!base) return;
  centerOnBase(parseInt(base.dataset.i, 10));
});
document.getElementById('copy-btn').addEventListener('click', async () => {
  const btn = document.getElementById('copy-btn');
  const original = btn.textContent;
  try{
    await navigator.clipboard.writeText(TRACE.sequence);
    btn.textContent = 'Copied';
  }catch(_err){
    btn.textContent = 'Copy failed';
  }
  setTimeout(() => btn.textContent = original, 1200);
});

let dragStartY = 0;
let dragStartHeight = 0;
function startResize(e){
  dragStartY = e.clientY;
  dragStartHeight = viewerRegion.getBoundingClientRect().height;
  document.body.classList.add('resizing');
  splitter.setPointerCapture(e.pointerId);
}
function moveResize(e){
  if(!document.body.classList.contains('resizing')) return;
  setTracePaneHeight(dragStartHeight + e.clientY - dragStartY);
}
function stopResize(e){
  if(!document.body.classList.contains('resizing')) return;
  document.body.classList.remove('resizing');
  if(splitter.hasPointerCapture(e.pointerId)) splitter.releasePointerCapture(e.pointerId);
}
splitter.addEventListener('pointerdown', startResize);
splitter.addEventListener('pointermove', moveResize);
splitter.addEventListener('pointerup', stopResize);
splitter.addEventListener('pointercancel', stopResize);
splitter.addEventListener('keydown', (e) => {
  const current = viewerRegion.getBoundingClientRect().height;
  if(e.key === 'ArrowUp'){
    setTracePaneHeight(current - 24);
    e.preventDefault();
  }else if(e.key === 'ArrowDown'){
    setTracePaneHeight(current + 24);
    e.preventDefault();
  }
});

const drawer = document.getElementById('drawer');
const scrim = document.getElementById('scrim');
const metaBtn = document.getElementById('meta-toggle');
function toggleDrawer(){
  drawer.classList.toggle('open');
  scrim.classList.toggle('open');
  metaBtn.classList.toggle('active');
}
metaBtn.addEventListener('click', toggleDrawer);
scrim.addEventListener('click', toggleDrawer);
window.addEventListener('resize', () => {
  const current = viewerRegion.getBoundingClientRect().height;
  setTracePaneHeight(current);
});

buildMetadata();
buildSequencePanel();
setTracePaneHeight(workspace.clientHeight * 0.34);
layout();
</script>
</body>
</html>
""")

proc writeChromatogramHtml*(
  trace: ABIFTrace,
  data: TraceData,
  inputFile,
  outFile: string,
  width: int = 1200,
  height: int = 600,
  showBaseCalls: bool = true,
  startPos: int = 0,
  endPos: int = -1,
  downsample: int = 1,
  highlights: seq[HighlightRegion] = @[]
): bool =
  ## Writes a portable HTML chromatogram report to `outFile`.
  let htmlText = renderChromatogramHtml(trace, data, inputFile, width, height,
                                        showBaseCalls, startPos, endPos,
                                        downsample, highlights)
  if htmlText.len == 0:
    return false
  let parent = outFile.parentDir
  if parent != "":
    createDir(parent)
  writeFile(outFile, htmlText)
  result = true

proc parseHighlightRegions(spec: string): seq[HighlightRegion] =
  ## Parses CLI highlight specs like "100-200" or "100-200,350-375".
  for rawPart in spec.split(","):
    let part = rawPart.strip()
    if part.len == 0:
      continue

    let bounds =
      if ".." in part:
        part.split("..", maxsplit = 1)
      elif ":" in part:
        part.split(":", maxsplit = 1)
      else:
        part.split("-", maxsplit = 1)

    if bounds.len != 2 or bounds[0].strip().len == 0 or bounds[1].strip().len == 0:
      raise newException(ValueError, "expected START-END highlight region, got '" & part & "'")

    let startPos = parseInt(bounds[0].strip())
    let endPos = parseInt(bounds[1].strip())
    if startPos < 0 or endPos < 0:
      raise newException(ValueError, "highlight coordinates must be non-negative: '" & part & "'")
    if endPos < startPos:
      raise newException(ValueError, "highlight end is before start: '" & part & "'")

    result.add(newHighlightRegion(startPos, endPos))

proc getVersion(): string =
  abifVersion()

proc showVersion() =
  stdout.writeLine("abichromatogram version ", getVersion())
  stdout.writeLine("Part of the ABIF toolkit")
  quit(0)

proc showHelp() =
  stderr.writeLine("ABIF Chromatogram Generator")
  stderr.writeLine("Version: ", getVersion())
  stderr.writeLine("")
  stderr.writeLine("Usage: abichromatogram <trace_file.ab1> [options]")
  stderr.writeLine("")
  stderr.writeLine("Description:")
  stderr.writeLine("  Generates an SVG chromatogram from an ABIF trace file,")
  stderr.writeLine("  displaying the four fluorescence channels with base calls.")
  stderr.writeLine("")
  stderr.writeLine("Options:")
  stderr.writeLine("  -o, --output FILE       Output SVG file (default: chromatogram.svg)")
  stderr.writeLine("      --html FILE         Output a portable HTML report with embedded SVG")
  stderr.writeLine("  -w, --width WIDTH       SVG width in pixels (default: 1200)")
  stderr.writeLine("      --height HEIGHT     SVG height in pixels (default: 600)")
  stderr.writeLine("  -s, --start POS         Start position (default: 0)")
  stderr.writeLine("  -e, --end POS           End position (default: whole trace)")
  stderr.writeLine("  -d, --downsample FACTOR Downsample factor for smoother visualization (default: 1)")
  stderr.writeLine("      --highlight START-END")
  stderr.writeLine("                          Highlight a trace scan region; repeat or comma-separate")
  stderr.writeLine("      --hide-bases        Hide base calls")
  stderr.writeLine("      --debug             Show debug information")
  stderr.writeLine("  -h, --help              Show this help message and exit")
  stderr.writeLine("  -v, --version           Show version information and exit")
  stderr.writeLine("")
  stderr.writeLine("Examples:")
  stderr.writeLine("  abichromatogram input.ab1")
  stderr.writeLine("  abichromatogram input.ab1 -o output.svg -d 5")
  stderr.writeLine("  abichromatogram input.ab1 --html output.html")
  stderr.writeLine("  abichromatogram input.ab1 -s 500 -e 1000 --width 1600")
  stderr.writeLine("  abichromatogram input.ab1 --highlight 540-620,780-830")
  quit(0)

when isMainModule:
  # Check for help/version flags
  for i in 1..paramCount():
    if paramStr(i) == "--help" or paramStr(i) == "-h":
      showHelp()
    elif paramStr(i) == "--version" or paramStr(i) == "-v":
      showVersion()
  
  # Check if enough arguments
  if paramCount() < 1:
    stderr.writeLine("Error: Missing input file")
    stderr.writeLine("Run 'abichromatogram --help' for usage information")
    quit(1)
  
  let inFile = paramStr(1)
  var 
    outFile = "chromatogram.svg"
    htmlOutFile = ""
    width = 1200
    height = 600
    startPos = 0
    endPos = -1  # -1 means use full trace
    downsample = 1
    showBases = true
    debug = false
    svgOutputExplicit = false
    highlights: seq[HighlightRegion] = @[]
  
  # Parse remaining arguments
  var i = 2
  while i <= paramCount():
    let arg = paramStr(i)
    case arg:
      of "-v", "--version":
        showVersion()
        
      of "-o", "--output":
        if i+1 <= paramCount():
          outFile = paramStr(i+1)
          svgOutputExplicit = true
          i += 2
        else:
          stderr.writeLine("Error: Missing value for output file")
          quit(1)

      of "--html":
        if i+1 <= paramCount():
          htmlOutFile = paramStr(i+1)
          i += 2
        else:
          stderr.writeLine("Error: Missing value for HTML output file")
          quit(1)
      
      of "-w", "--width":
        if i+1 <= paramCount():
          try:
            width = parseInt(paramStr(i+1))
            i += 2
          except:
            stderr.writeLine("Error: Invalid width value")
            quit(1)
        else:
          stderr.writeLine("Error: Missing value for width")
          quit(1)
      
      of "--height":
        if i+1 <= paramCount():
          try:
            height = parseInt(paramStr(i+1))
            i += 2
          except:
            stderr.writeLine("Error: Invalid height value")
            quit(1)
        else:
          stderr.writeLine("Error: Missing value for height")
          quit(1)
      
      of "-s", "--start":
        if i+1 <= paramCount():
          try:
            startPos = parseInt(paramStr(i+1))
            i += 2
          except:
            stderr.writeLine("Error: Invalid start position")
            quit(1)
        else:
          stderr.writeLine("Error: Missing value for start position")
          quit(1)
      
      of "-e", "--end":
        if i+1 <= paramCount():
          try:
            endPos = parseInt(paramStr(i+1))
            i += 2
          except:
            stderr.writeLine("Error: Invalid end position")
            quit(1)
        else:
          stderr.writeLine("Error: Missing value for end position")
          quit(1)
      
      of "-d", "--downsample":
        if i+1 <= paramCount():
          try:
            downsample = max(1, parseInt(paramStr(i+1)))
            i += 2
          except:
            stderr.writeLine("Error: Invalid downsample factor")
            quit(1)
        else:
          stderr.writeLine("Error: Missing value for downsample factor")
          quit(1)

      of "--highlight":
        if i+1 <= paramCount():
          try:
            highlights.add(parseHighlightRegions(paramStr(i+1)))
            i += 2
          except ValueError:
            stderr.writeLine("Error: ", getCurrentExceptionMsg())
            quit(1)
        else:
          stderr.writeLine("Error: Missing value for highlight region")
          quit(1)
      
      of "--hide-bases":
        showBases = false
        i += 1
      
      of "--debug":
        debug = true
        i += 1
      
      else:
        if arg.startsWith("--html="):
          htmlOutFile = arg.split("=", maxsplit = 1)[1]
          if htmlOutFile.len == 0:
            stderr.writeLine("Error: Missing value for HTML output file")
            quit(1)
          i += 1
        else:
          # Assume it's the SVG output file for backwards compatibility
          outFile = arg
          svgOutputExplicit = true
          i += 1
  
  try:
    # Load the trace file
    let trace = newABIFTrace(inFile)
    echo "File version: ", trace.version
    echo "Sample name: ", trace.getSampleName()
    echo "Sequence length: ", trace.getSequence().len
    
    # Print debug information if requested
    if debug:
      echo "Available tags:"
      for tag in trace.getTagNames():
        echo "  ", tag
      
      echo "Base order: ", trace.getData("FWO_1")
      
      let peek = proc(tag: string) =
        let data = trace.getData(tag)
        echo tag, " (length: ", data.len, "): ", 
             if data.len > 50: data[0..50] & "..." else: data
      
      # Check for DATA9-12 channels (processed data in newer files)
      let hasProcessed = trace.getTagNames().anyIt(it == "DATA9")
      
      if hasProcessed:
        echo "File has processed channels DATA9-12"
        peek("DATA9")
        peek("DATA10")
        peek("DATA11")
        peek("DATA12")
      else:
        echo "Using raw channels DATA1-4"
        peek("DATA1")
        peek("DATA2")
        peek("DATA3")
        peek("DATA4")
      
      peek("PLOC2")
    
    # Extract the trace data
    var traceData = getTraceData(trace, debug)
    
    let writeSvg = htmlOutFile.len == 0 or svgOutputExplicit
    if writeSvg:
      if not renderChromatogram(
        traceData, 
        outFile,
        width=width, 
        height=height,
        showBaseCalls=showBases,
        startPos=startPos, 
        endPos=endPos,
        downsample=downsample,
        highlights=highlights
      ):
        stderr.writeLine("Error: Invalid range selected, no data to display")
        quit(1)
      echo "Exported SVG chromatogram to: ", outFile

    if htmlOutFile.len > 0:
      if not writeChromatogramHtml(
        trace,
        traceData,
        inFile,
        htmlOutFile,
        width=width,
        height=height,
        showBaseCalls=showBases,
        startPos=startPos,
        endPos=endPos,
        downsample=downsample,
        highlights=highlights
      ):
        stderr.writeLine("Error: Invalid range selected, no data to display")
        quit(1)
      echo "Exported HTML chromatogram to: ", htmlOutFile
    
    # Close the file
    trace.close()
  except:
    stderr.writeLine("Error: ", getCurrentExceptionMsg())
    quit(1)
