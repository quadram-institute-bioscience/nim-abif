import std/[os, tables, strformat, strutils, parseopt, sequtils, streams, algorithm]
import ./abif

#[
  abimetadata - Display and modify metadata in ABIF files

  Usage:
  abimetadata [options] <input.ab1>

  Options:
  -h, --help                 Show this help message
  -l, --list                 List all metadata fields (default if no other option specified)
  -o, --output STRING        Output file for modified ABI file (required when editing)
  -t, --tag STRING           Tag name to edit or remove (e.g., "SMPL1")
  -v, --value STRING         New value for tag (use empty string to remove)
  --debug                    Show additional debug information
]#

type
  Config = object
    inputFile: string
    outputFile: string
    tag: string
    value: string
    listTags: bool
    debug: bool
    limit: int

proc printHelp() =
  echo """
abimetadata - Display and modify metadata in ABIF files

Usage:
  abimetadata [options] <input.ab1>

Options:
  -h, --help                 Show this help message
  -l, --list                 List all metadata fields (default if no other option specified)
  -o, --output STRING        Output file for modified ABI file (required when editing)
  -t, --tag STRING           Tag name to edit or remove (e.g., "SMPL1")
  -v, --value STRING         New value for tag (use empty string to remove)
  --limit INT                Limit number of tags displayed (default: all)
  --debug                    Show additional debug information
"""
  quit(0)

proc parseCommandLine(): Config =
  var p = initOptParser(commandLineParams())
  result = Config(
    listTags: true,  # Default to listing tags if no other options specified
    debug: false,
    limit: 0  # 0 means no limit
  )
  
  var fileArgs: seq[string] = @[]
  
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      fileArgs.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        printHelp()
      of "l", "list":
        result.listTags = true
      of "o", "output":
        result.outputFile = val
      of "t", "tag":
        result.tag = val
      of "v", "value":
        result.value = val
      of "limit":
        try:
          result.limit = parseInt(val)
        except:
          echo "Error: Invalid limit value. Using default."
          result.limit = 0
      of "debug":
        result.debug = true
      else:
        echo "Unknown option: ", key
        printHelp()
    of cmdEnd: assert(false)
  
  if fileArgs.len < 1:
    echo "Error: Input file required"
    printHelp()
  
  result.inputFile = fileArgs[0]
  
  # Check if editing mode is requested
  if result.tag.len > 0:
    # In editing mode, ensure output file is specified
    if result.outputFile.len == 0:
      echo "Error: Output file (-o, --output) must be specified when editing tags"
      quit(1)
    
    # Don't allow overwriting the input file
    if absolutePath(result.outputFile) == absolutePath(result.inputFile):
      echo "Error: Output file must be different from input file"
      quit(1)

proc formatTagValue(tagName: string, entry: DirectoryEntry, trace: ABIFTrace): string =
  let tagType = $entry.elemType
  if tagType.toLowerAscii().contains("string"):
    let data = trace.getData(tagName)
    let firstChars = if data.len > 100: data[0..<100] & "..." else: data
    return firstChars.replace("\n", "\\n")
  else:
    return trace.getData(tagName)

proc listMetadata(trace: ABIFTrace, debug: bool, limit: int = 0) =
  let tagNames = trace.getTagNames()
  
  echo "Found ", tagNames.len, " tag names"
  if debug:
    echo "Debug: Tag names: ", tagNames
  
  # Create a table for pretty formatting
  var headers = @["Tag", "Data Type", "Size", "Value"]
  var rows: seq[seq[string]] = @[]
  
  stderr.writeLine( "Processing tags..." )
  var processedCount = 0
  var limitCount = 0
  for tagName in tagNames:
    # Check if we've reached the limit
    if limit > 0 and limitCount >= limit:
      break
      
    if debug:
      stderr.writeLine( "Processing tag: ", tagName)
      
    if not trace.tags.hasKey(tagName):
      if debug:
        echo "  Tag not found in trace.tags"
      continue
      
    limitCount.inc()
      
    let entry = trace.tags[tagName]
    
    # To avoid spending time processing tags
    var displayValue = ""
    
    # Skip data arrays which are typically large chromatogram traces
    if tagName.startsWith("DATA") and entry.dataSize > 1000:
      displayValue = "(chromatogram data, " & $entry.dataSize & " bytes)"
    elif entry.dataSize > 1000 and not debug:
      displayValue = "(large data, " & $entry.dataSize & " bytes)"
    else:
      try:
        let value = formatTagValue(tagName, entry, trace)
        displayValue = if value.len > 120: value[0..119] & "..." else: value
      except:
        displayValue = "(error getting value: " & getCurrentExceptionMsg() & ")"
    
    # Organize data for display  
    var row = @[
      tagName,
      $entry.elemType,
      $entry.dataSize,
      displayValue
    ]
    rows.add(row)
    
    processedCount.inc()
    if processedCount mod 10 == 0:
      echo "  Processed ", processedCount, " tags..."
  
  # Sort rows by tag name
  echo "Sorting tags..."
  proc compareRows(x, y: seq[string]): int =
    result = cmp(x[0], y[0])
  
  sort(rows, compareRows)
  
  # Calculate column widths
  echo "Formatting output..."
  var colWidths: seq[int] = @[]
  for i in 0..<headers.len:
    var maxWidth = headers[i].len
    for row in rows:
      if i < row.len and row[i].len > maxWidth:
        maxWidth = min(row[i].len, 60)  # Cap at 60 chars
    colWidths.add(maxWidth)
  
  # Print headers
  var header = ""
  for i, h in headers:
    header &= h.alignLeft(colWidths[i] + 2)
  echo header
  
  # Print separator
  echo repeat("=", header.len)
  
  # Print rows
  for row in rows:
    var line = ""
    for i, cell in row:
      line &= cell.alignLeft(colWidths[i] + 2)
    echo line
    
  echo "\nTotal tags: ", rows.len

proc modifyTag(trace: ABIFTrace, tagName: string, newValue: string, outputFile: string): bool =
  # This is a simplified implementation that works for string-based tags
  if not trace.tags.hasKey(tagName):
    echo "Error: Tag ", tagName, " not found in file"
    return false
    
  let entry = trace.tags[tagName]
  let tagType = $entry.elemType
  
  # Only allow modification of string-based tags for now
  if not (tagType.toLowerAscii().contains("string")):
    echo "Error: Only string-type tags can be modified in this version"
    return false
    
  try:
    # Create a copy of the input file
    copyFile(trace.fileName, outputFile)
    
    # Open the output file for writing
    var outStream = newFileStream(outputFile, fmReadWrite)
    if outStream == nil:
      echo "Error: Could not open output file for writing"
      return false
      
    # Position at the data offset for this tag
    outStream.setPosition(entry.dataOffset)
    
    if tagType.toLowerAscii().contains("cstring"):
      # For C strings, write the null-terminated string
      outStream.writeData(newValue.cstring, newValue.len)
      outStream.write('\0')  # Null terminator
    elif tagType.toLowerAscii().contains("pstring"):
      # For Pascal strings, write length byte first
      if newValue.len > 255:
        echo "Error: Pascal string cannot exceed 255 characters"
        outStream.close()
        return false
      outStream.write(newValue.len.uint8)
      outStream.writeData(newValue.cstring, newValue.len)
    else:
      # For other string types, just write the data
      outStream.writeData(newValue.cstring, newValue.len)
    
    outStream.close()
    return true
  except:
    echo "Error: ", getCurrentExceptionMsg()
    return false

proc main() =
  let config = parseCommandLine()
  
  if config.debug:
    echo "Processing file: ", config.inputFile
    if config.tag.len > 0:
      echo "Modifying tag: ", config.tag, " with value: ", config.value
      echo "Output file: ", config.outputFile
  
  try:
    var trace = newABIFTrace(config.inputFile)
    
    if not trace.tags.len > 0:
      echo "Error: Not a valid ABIF file or no tags found"
      quit(1)
    
    if config.listTags:
      echo "Metadata from ", config.inputFile, ":"
      listMetadata(trace, config.debug, config.limit)
    
    if config.tag.len > 0:
      # Modify the tag and write to output file
      echo "Modifying tag ", config.tag, " to: ", config.value
      if modifyTag(trace, config.tag, config.value, config.outputFile):
        echo "Successfully modified tag and saved to: ", config.outputFile
      else:
        echo "Failed to modify tag"
        quit(1)
    
    trace.close()
  except:
    echo "Error: ", getCurrentExceptionMsg()
    quit(1)

when isMainModule:
  main()

#[
NOTE: Implementing tag modification requires deeper understanding of the ABIF file format and 
the ability to modify binary files. A proper implementation would:

1. Create a copy of the original file
2. Update the directory entry for the specific tag
3. If the data size is the same, update the data directly
4. If the data size changes, rewrite the file with the new data size and offset
5. Update checksums and other metadata as necessary

The current implementation just lists the tags, similar to the Perl script when no value is specified.
]#