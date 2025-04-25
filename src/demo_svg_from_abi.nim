import std/[os, strformat, strutils, sequtils, tables, math, algorithm]
import nimsvg

# Import the abif module properly
when defined(release):
  # When building as a nimble package
  import abif
else:
  # When running directly from source directory
  import ./abif

type
  Channel = enum
    A = "A", C = "C", G = "G", T = "T"
  
  TraceDataPoint = object
    position: int   # X position
    values: Table[Channel, int]  # Value for each channel
  
  TraceData = object
    points: seq[TraceDataPoint]   # Processed trace data points
    baseOrder: string             # Order of bases in channels
    peaks: seq[int]               # Peak positions
    sequence: string              # Called sequence
    traceLen: int                 # Total length of trace
    baseColors: Table[Channel, string]  # Color mapping for bases

proc getTraceData(trace: ABIFTrace, debug: bool = false): TraceData =
  # Function to parse numeric sequence from string representation
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
  scaleFn: proc(peakPos: int): int
): seq[tuple[x, peakPos: int, baseChar: char]] =
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

# Generate the SVG chromatogram and save to a file
proc renderChromatogram(
  data: TraceData, 
  outFile: string, 
  width: int = 1200, 
  height: int = 600,
  showBaseCalls: bool = true,
  startPos: int = 0, 
  endPos: int = -1,
  downsample: int = 1
) =
  # Calculate dimensions and scaling
  let padding = 50
  let titleHeight = 30
  let topPadding = padding + titleHeight
  let plotHeight = height - padding - topPadding
  let sample_name = outFile.extractFilename.changeFileExt("")
  
  # Calculate the range to display
  let dataLen = data.traceLen
  let displayStart = max(0, startPos)
  let displayEnd = if endPos < 0: dataLen else: min(dataLen, endPos)
  let displayLen = displayEnd - displayStart
  let effectiveLen = (displayLen + downsample - 1) div downsample  # Ceiling division
  let xScale = (width - (2 * padding)).float / effectiveLen.float
  
  if displayLen <= 0:
    echo "Error: Invalid range selected, no data to display"
    return
  
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
  
  # Build the SVG file
  buildSvgFile(outFile):
    svg(width=width, height=height):
      # Title
      text(x=width div 2, y=titleHeight, `text-anchor`="middle", 
           `font-family`="Arial", `font-size`=20, `font-weight`="bold"):
        t &"Chromatogram: {sample_name}"
      
      # White background with border
      rect(x=padding, y=topPadding, width=width-(2*padding), height=plotHeight, 
           fill="white", stroke="black", `stroke-width`=1)
      
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

proc getVersion(): string =
  let ver = abifVersion()
  return if ver == "<NimblePkgVersion>": "0.2.0" else: ver

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
  stderr.writeLine("  -w, --width WIDTH       SVG width in pixels (default: 1200)")
  stderr.writeLine("      --height HEIGHT     SVG height in pixels (default: 600)")
  stderr.writeLine("  -s, --start POS         Start position (default: 0)")
  stderr.writeLine("  -e, --end POS           End position (default: whole trace)")
  stderr.writeLine("  -d, --downsample FACTOR Downsample factor for smoother visualization (default: 1)")
  stderr.writeLine("      --hide-bases        Hide base calls")
  stderr.writeLine("      --debug             Show debug information")
  stderr.writeLine("  -h, --help              Show this help message and exit")
  stderr.writeLine("  -v, --version           Show version information and exit")
  stderr.writeLine("")
  stderr.writeLine("Examples:")
  stderr.writeLine("  abichromatogram input.ab1")
  stderr.writeLine("  abichromatogram input.ab1 -o output.svg -d 5")
  stderr.writeLine("  abichromatogram input.ab1 -s 500 -e 1000 --width 1600")
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
    width = 1200
    height = 600
    startPos = 0
    endPos = -1  # -1 means use full trace
    downsample = 1
    showBases = true
    debug = false
  
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
          i += 2
        else:
          stderr.writeLine("Error: Missing value for output file")
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
      
      of "--hide-bases":
        showBases = false
        i += 1
      
      of "--debug":
        debug = true
        i += 1
      
      else:
        # Assume it's the output file
        outFile = arg
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
    
    # Render the chromatogram
    renderChromatogram(
      traceData, 
      outFile,
      width=width, 
      height=height,
      showBaseCalls=showBases,
      startPos=startPos, 
      endPos=endPos,
      downsample=downsample
    )
    
    echo "Exported SVG chromatogram to: ", outFile
    
    # Close the file
    trace.close()
  except:
    echo "Error: ", getCurrentExceptionMsg()