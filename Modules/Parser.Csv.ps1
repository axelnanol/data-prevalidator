#Requires -Version 5.1
<#
.SYNOPSIS
    CSV parser adapter.
.DESCRIPTION
    Reads a CSV file and converts every field in every row into a normalised
    ParsedRecord object that the rule engine can consume.
.NOTES
    Assumption: CSV files do not contain multi-line quoted fields.
#>

function Split-CsvLine {
    <#
    .SYNOPSIS
        Splits a single CSV line into fields, respecting double-quote enclosure.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Line
    )

    $fields  = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inQuote = $false

    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]

        if ($ch -eq '"') {
            if ($inQuote -and ($i + 1) -lt $Line.Length -and $Line[$i + 1] -eq '"') {
                # Escaped double-quote inside quoted field
                [void]$current.Append('"')
                $i++
            } else {
                $inQuote = -not $inQuote
            }
        } elseif ($ch -eq ',' -and -not $inQuote) {
            $fields.Add($current.ToString())
            [void]$current.Clear()
        } else {
            [void]$current.Append($ch)
        }
    }

    $fields.Add($current.ToString())
    return $fields.ToArray()
}

function Invoke-CsvParser {
    <#
    .SYNOPSIS
        Parses a CSV file into an array of normalised ParsedRecord objects.
    .PARAMETER FilePath
        Absolute or relative path to the CSV file.
    .OUTPUTS
        System.Collections.Generic.List[PSObject]
        Each object has the following properties:
          SourceFile, Format, RecordKey, RecordIndex, FieldName,
          NormalizedPath, Path, Value, Line, Column, Raw
    #>
    [OutputType([System.Collections.Generic.List[PSObject]])]
    param(
        [Parameter(Mandatory)][string]$FilePath
    )

    $FilePath = [System.IO.Path]::GetFullPath($FilePath)

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "CSV file not found: $FilePath"
    }

    $records  = [System.Collections.Generic.List[PSObject]]::new()
    $fileName = Split-Path $FilePath -Leaf

    $rawLines = [System.IO.File]::ReadAllLines($FilePath, [System.Text.Encoding]::UTF8)

    if ($rawLines.Count -eq 0) {
        Write-Warning "CSV file is empty: $fileName"
        return $records
    }

    # --- Parse headers from the first line ---
    $headers = Split-CsvLine -Line $rawLines[0]

    if ($headers.Count -eq 0) {
        throw "CSV file has no headers: $fileName"
    }

    # --- Parse each data row ---
    for ($lineIdx = 1; $lineIdx -lt $rawLines.Count; $lineIdx++) {
        $rawLine = $rawLines[$lineIdx]

        # Skip blank lines
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }

        $rowIndex  = $lineIdx          # 1-based data-row index (line 1 = header)
        $lineNum   = $lineIdx + 1      # 1-based line number in the file
        $recordKey = "Row[$rowIndex]"
        $values    = Split-CsvLine -Line $rawLine

        for ($colIdx = 0; $colIdx -lt $headers.Count; $colIdx++) {
            $fieldName = $headers[$colIdx].Trim()
            $value     = if ($colIdx -lt $values.Count) { $values[$colIdx] } else { '' }

            $records.Add([PSCustomObject]@{
                SourceFile     = $fileName
                Format         = 'csv'
                RecordKey      = $recordKey
                RecordIndex    = $rowIndex
                FieldName      = $fieldName
                NormalizedPath = $fieldName          # For CSV the normalised path is just the field name
                Path           = "$recordKey.$fieldName"
                Value          = $value
                Line           = $lineNum
                Column         = $colIdx + 1
                Raw            = $value
            })
        }
    }

    return $records
}
