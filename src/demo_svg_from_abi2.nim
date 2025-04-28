import std/[os, strformat, strutils, sequtils, tables, math]
import nimsvg
import abif

type
  TraceData = object
    raw1: seq[int]   # A channel
    raw2: seq[int]   # C channel 
    raw3: seq[int]   # G channel
    raw4: seq[int]   # T channel
    baseOrder: string
    peaks: seq[int]
    sequence: string
    baseColors: Table[char, string]
    qualityValues: seq[int]  # Added quality values

proc getTraceData(trace: ABIFTrace): TraceData =
  # Parse raw channel data from string representation of seq[int]
  let parseChannel = proc(rawStr: string): seq[int] =
    if rawStr.len < 3: # Empty or too short
      return @[]
    
    # Try first to see if the data is in the format "@[1234, 5678, ...]"
    if rawStr.startsWith("@[") and rawStr.endsWith("]"):
      let content = rawStr[2..^2] # Remove @[ and ]
      if content.len == 0:
        return @[]
      try:
        return content.split(", ").mapIt(it.strip().parseInt)
      except:
        echo "Failed to parse as seq: ", rawStr[0..min(20, rawStr.len-1)], "..."
    
    # If not in sequence format, just convert each character's ord value
    var result = newSeq[int](rawStr.len)
    for i, c in rawStr:
      result[i] = ord(c)
    return result
  
  # Define standard colors for bases
  result.baseColors = {
    'A': "green", 
    'C': "blue", 
    'G': "black", 
    'T': "red",
    'N': "purple"  # For undetermined bases
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
  
  # Get raw data directly using getData instead of relying on data table
  result.raw1 = parseChannel(trace.getData("DATA1"))
  result.raw2 = parseChannel(trace.getData("DATA2"))
  result.raw3 = parseChannel(trace.getData("DATA3"))
  result.raw4 = parseChannel(trace.getData("DATA4"))
  
  # Get peak locations
  result.peaks = parseChannel(trace.getData("PLOC2"))
  
  # Get sequence
  result.sequence = trace.getSequence()
  
  # Get quality values
  result.qualityValues = trace.getQualityValues()

proc downsampleTraces(data: var TraceData, targetSize: int = 10000) =
  # Downsample the trace data if it's too large
  # This helps make the SVG manageable and ensures better performance
  
  let maxLen = max(max(data.raw1.len, data.raw2.len), 
                   max(data.raw3.len, data.raw4.len))
  
  if maxLen <= targetSize:
    return  # No downsampling needed
  
  let factor = ceil(maxLen.float / targetSize.float).int
  if factor <= 1:
    return  # No downsampling needed
  
  # Downsample each channel
  proc downsample(chan: seq[int]): seq[int] =
    result = newSeq[int](chan.len div factor + 1)
    for i in 0..<result.len:
      var sum = 0
      var count = 0
      for j in 0..<factor:
        let idx = i * factor + j
        if idx < chan.len:
          sum += chan[idx]
          count += 1
      if count > 0:
        result[i] = sum div count
  
  data.raw1 = downsample(data.raw1)
  data.raw2 = downsample(data.raw2)
  data.raw3 = downsample(data.raw3)
  data.raw4 = downsample(data.raw4)
  
  # Also adjust peak positions
  for i in 0..<data.peaks.len:
    data.peaks[i] = data.peaks[i] div factor

proc normalizeTraces(data: var TraceData, amplifyFactor: float = 1.2) =
  # Find maximum value across all channels for scaling
  var maxVal = 0
  
  # Only consider non-zero values to avoid division by zero later
  proc updateMax(chan: seq[int]) =
    for val in chan:
      if val > 0:  # Skip zero values which might be artifacts
        maxVal = max(maxVal, val)
  
  updateMax(data.raw1)
  updateMax(data.raw2)
  updateMax(data.raw3)
  updateMax(data.raw4)
  
  if maxVal <= 0:
    # If all values are zero or negative, set a default
    maxVal = 1000
    return
  
  # Normalize all values to a scale of 0-1000, with optional amplification
  let normalizeChan = proc(chan: var seq[int]) =
    for i in 0..<chan.len:
      if chan[i] <= 0:
        chan[i] = 0
      else:
        # Use float division for more accurate scaling with amplification
        chan[i] = int((chan[i].float / maxVal.float) * 1000.0 * amplifyFactor)
        # Cap at 1000 to prevent overly large values
        if chan[i] > 1000:
          chan[i] = 1000
  
  normalizeChan(data.raw1)
  normalizeChan(data.raw2)
  normalizeChan(data.raw3) 
  normalizeChan(data.raw4)

proc renderChromatogram*(data: TraceData, outFile: string, 
                         width: int = 1200, height: int = 600,
                         zoomRegion: tuple[startPos, endPos: int] = (0, -1)) =
  # Calculate dimensions and scaling
  let 
    topPadding = 80      # More space at top for base letters
    bottomPadding = 50
    leftPadding = 60     # Space for y-axis
    rightPadding = 40
    
    plotHeight = height - (topPadding + bottomPadding)
    plotWidth = width - (leftPadding + rightPadding)
    
    # Determine data range to display (support zooming)
    dataStart = zoomRegion.startPos
    dataEnd = if zoomRegion.endPos > 0: zoomRegion.endPos 
              else: max(max(data.raw1.len, data.raw2.len), 
                        max(data.raw3.len, data.raw4.len))
    dataLen = dataEnd - dataStart
    
    # Calculate horizontal scaling factor
    xScale = plotWidth.float / dataLen.float
    
    # Set peak label spacing parameters
    peakHeight = 25      # Height for peak label ticks
    peakSpace = 45       # Minimum horizontal spacing between peak labels
    
    # Create an array to track where labels are placed to avoid overlaps
    labelPositions = newSeq[int]()
  
  # Create a mapping from base order to channel data
  var channelData: seq[(seq[int], string)] = @[]
  
  if data.baseOrder.len >= 4:
    let baseChar1 = data.baseOrder[0]
    let baseChar2 = data.baseOrder[1]
    let baseChar3 = data.baseOrder[2]
    let baseChar4 = data.baseOrder[3]
    
    # Map channels to colors based on base order
    if data.baseColors.hasKey(baseChar1):
      channelData.add((data.raw1, data.baseColors[baseChar1]))
    if data.baseColors.hasKey(baseChar2):
      channelData.add((data.raw2, data.baseColors[baseChar2]))
    if data.baseColors.hasKey(baseChar3):
      channelData.add((data.raw3, data.baseColors[baseChar3]))
    if data.baseColors.hasKey(baseChar4):
      channelData.add((data.raw4, data.baseColors[baseChar4]))
  
  # Function to check if a new label would overlap with existing ones
  proc wouldOverlap(xPos: int): bool =
    for pos in labelPositions:
      if abs(pos - xPos) < peakSpace:
        return true
    return false
  
  buildSvgFile(outFile):
    svg(width=width, height=height):
      # White background
      rect(x=0, y=0, width=width, height=height, fill="white")
      
      # Draw frame for the plot
      rect(x=leftPadding, y=topPadding, 
           width=plotWidth, height=plotHeight, 
           fill="none", stroke="gray", `stroke-width`=1)
      
      # Draw gridlines 
      for i in 0..10:  # Horizontal gridlines
        let y = topPadding + (i * (plotHeight / 10)).int
        line(x1=leftPadding, y1=y, x2=leftPadding+plotWidth, y2=y, 
             stroke="#e0e0e0", `stroke-width`=1)
      
      for i in 0..10:  # Vertical gridlines
        let x = leftPadding + (i * (plotWidth / 10)).int
        line(x1=x, y1=topPadding, x2=x, y2=topPadding+plotHeight, 
             stroke="#e0e0e0", `stroke-width`=1)
      
      # Draw axes labels
      text(x=(width/2).int, y=height-10, `text-anchor`="middle", fill="black",
           `font-family`="sans-serif", `font-size`=14):
        t "Base Position"
      
      text(x=10, y=(height/2).int, transform="rotate(-90,10," & $(height/2).int & ")",
           `text-anchor`="middle", fill="black", `font-family`="sans-serif", `font-size`=14):
        t "Signal Intensity"
      
      # Draw each channel as a polyline
      for (chan, color) in channelData:
        if chan.len >= 2:
          var points = ""
          for i in dataStart..<min(dataEnd, chan.len):
            let x = leftPadding + ((i - dataStart).float * xScale).int
            let y = topPadding + plotHeight - ((chan[i].float / 1000) * plotHeight.float).int
            points &= &"{x},{y} "
          
          polyline(points=points, fill="none", stroke=color, `stroke-width`=1.8)
      
      # Draw peak markers and base calls
      if data.peaks.len > 0 and data.sequence.len > 0:
        for i in 0..<min(data.peaks.len, data.sequence.len):
          let peakPos = data.peaks[i]
          
          # Skip peaks outside the view range
          if peakPos < dataStart or peakPos >= dataEnd:
            continue
          
          let x = leftPadding + ((peakPos - dataStart).float * xScale).int
          
          # Check if this position would overlap with existing labels
          if not wouldOverlap(x):
            let baseChar = data.sequence[i]
            let color = if data.baseColors.hasKey(baseChar): data.baseColors[baseChar] else: "black"
            
            # Add quality indicator (thicker line for higher quality)
            let qual = if i < data.qualityValues.len: data.qualityValues[i] else: 20
            let strokeWidth = 0.5 + (qual.float / 40.0) * 1.5
            
            # Draw vertical line at peak
            line(x1=x, y1=topPadding+plotHeight, x2=x, y2=topPadding+plotHeight-peakHeight, 
                 stroke=color, `stroke-width`=strokeWidth)
            
            # Draw base letter with larger font
            text(x=x, y=topPadding-15, `text-anchor`="middle", fill=color,
                 `font-family`="monospace", `font-size`=16, `font-weight`="bold"):
              t $baseChar
            
            # Record this label position
            labelPositions.add(x)
      
      # Add title with filename
      text(x=(width/2).int, y=25, `text-anchor`="middle", fill="black",
           `font-family`="sans-serif", `font-size`=18, `font-weight`="bold"):
        t "Chromatogram"
      
      # Add sequence length info
      text(x=width-rightPadding, y=height-5, `text-anchor`="end", fill="black",
           `font-family`="sans-serif", `font-size`=12):
        t &"Sequence length: {data.sequence.len}"

proc exportTraceVisualization*(trace: ABIFTrace, outFile: string, 
                              width: int = 1200, height: int = 600,
                              startPos: int = 0, endPos: int = -1) =
  # Main function to extract and visualize trace data
  var traceData = getTraceData(trace)
  
  # Downsample if needed to improve performance
  downsampleTraces(traceData)
  
  # Normalize and amplify to make peaks more visible
  normalizeTraces(traceData, 1.5)
  
  # Create the zoom region tuple
  let zoomRegion = (startPos: startPos, endPos: endPos)
  
  # Render the chromatogram
  renderChromatogram(traceData, outFile, width, height, zoomRegion)

when isMainModule:
  if paramCount() < 1:
    stderr.writeLine("Usage: abif_svg <trace_file.ab1> [output_file.svg] [options]")
    stderr.writeLine("Options:")
    stderr.writeLine("  --width=N    Set output width (default: 1200)")
    stderr.writeLine("  --height=N   Set output height (default: 600)")
    stderr.writeLine("  --start=N    Start position for zoomed view")
    stderr.writeLine("  --end=N      End position for zoomed view")
    stderr.writeLine("  --debug      Show debug information")
    quit(1)
  
  let inFile = paramStr(1)
  var outFile = "chromatogram.svg"
  var width = 1200
  var height = 600
  var startPos = 0
  var endPos = -1
  var debug = false
  
  # Parse command line arguments
  for i in 2..paramCount():
    let param = paramStr(i)
    if param.startsWith("--width="):
      width = parseInt(param[8..^1])
    elif param.startsWith("--height="):
      height = parseInt(param[9..^1])
    elif param.startsWith("--start="):
      startPos = parseInt(param[8..^1])
    elif param.startsWith("--end="):
      endPos = parseInt(param[6..^1])
    elif param == "--debug":
      debug = true
    elif not param.startsWith("--"):
      outFile = param
  
  try:
    let trace = newABIFTrace(inFile)
    echo "File version: ", trace.version
    echo "Sample name: ", trace.getSampleName()
    echo "Sequence length: ", trace.getSequence().len
    
    if debug:
      echo "Available tags:"
      for tag in trace.getTagNames():
        echo "  ", tag
      
      echo "Base order: ", trace.getData("FWO_1")
    
    # Export the SVG visualization
    exportTraceVisualization(trace, outFile, width, height, startPos, endPos)
    
    echo "Exported SVG chromatogram to: ", outFile
    
    trace.close()
  except:
    echo "Error: ", getCurrentExceptionMsg()