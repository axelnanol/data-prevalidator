#Requires -Version 5.1
<#
.SYNOPSIS
    XML parser adapter.
.DESCRIPTION
    Reads an XML file using System.Xml.XmlReader (which exposes accurate
    per-node line and column positions) while building normalised ParsedRecord
    objects.  A separate System.Xml.XmlDocument is also returned for use by
    the XPathExists rule.

    Paths returned:
      Path           - fully indexed XPath, e.g. /Orders/Order[2]/@id
      NormalizedPath - structural path without indices, e.g. /Orders/Order/@id
      RecordKey      - indexed path of the containing element (groups siblings)
#>

function Invoke-XmlParser {
    <#
    .SYNOPSIS
        Parses an XML file into an array of normalised ParsedRecord objects.
    .PARAMETER FilePath
        Absolute or relative path to the XML file.
    .OUTPUTS
        Hashtable with keys:
          Records  - System.Collections.Generic.List[PSObject]
          Document - System.Xml.XmlDocument (used by XPathExists rule)
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$FilePath
    )

    $FilePath = [System.IO.Path]::GetFullPath($FilePath)

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "XML file not found: $FilePath"
    }

    $fileName = Split-Path $FilePath -Leaf
    $records  = [System.Collections.Generic.List[PSObject]]::new()

    # ------------------------------------------------------------------
    # Pass 1: Walk with XmlReader to capture records WITH line numbers.
    # ------------------------------------------------------------------
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.IgnoreWhitespace = $true
    $settings.IgnoreComments   = $true

    $xr = $null

    # Each stack entry is a hashtable describing the current element level.
    # Stack entry keys:
    #   FullPath        - e.g. /Orders/Order[2]
    #   NormPath        - e.g. /Orders/Order
    #   Name            - local element name
    #   ParentFullPath  - parent element's full path (for RecordKey of text nodes)
    #   ChildCounts     - hashtable of child-element-name -> sibling index (mutable)
    $elementStack = [System.Collections.Generic.Stack[hashtable]]::new()

    try {
        $xr = [System.Xml.XmlReader]::Create($FilePath, $settings)

        while ($xr.Read()) {

            switch ($xr.NodeType) {

                # ---- Start of element ----------------------------------------
                ([System.Xml.XmlNodeType]::Element) {

                    $elName      = $xr.LocalName
                    $isEmptyElem = $xr.IsEmptyElement
                    $elLine      = $xr.LineNumber
                    $elCol       = $xr.LinePosition

                    # Compute full/normalised paths from parent state
                    if ($elementStack.Count -eq 0) {
                        # Document root element
                        $fullPath       = "/$elName"
                        $normPath       = "/$elName"
                        $parentFullPath = ''
                    } else {
                        $parent = $elementStack.Peek()
                        $counts = $parent.ChildCounts

                        if (-not $counts.ContainsKey($elName)) { $counts[$elName] = 0 }
                        $counts[$elName]++
                        $idx = $counts[$elName]

                        $fullPath       = "$($parent.FullPath)/$elName[$idx]"
                        $normPath       = "$($parent.NormPath)/$elName"
                        $parentFullPath = $parent.FullPath
                    }

                    # Process attributes while reader is positioned on the element
                    if ($xr.HasAttributes) {
                        for ($ai = 0; $ai -lt $xr.AttributeCount; $ai++) {
                            [void]$xr.MoveToAttribute($ai)
                            $attrName  = $xr.LocalName
                            $attrValue = $xr.Value
                            $attrLine  = $xr.LineNumber
                            $attrCol   = $xr.LinePosition

                            $records.Add([PSCustomObject]@{
                                SourceFile     = $fileName
                                Format         = 'xml'
                                RecordKey      = $fullPath
                                RecordIndex    = 0
                                FieldName      = "@$attrName"
                                NormalizedPath = "$normPath/@$attrName"
                                Path           = "$fullPath/@$attrName"
                                Value          = $attrValue
                                Line           = $attrLine
                                Column         = $attrCol
                                Raw            = $attrValue
                            })
                        }
                        [void]$xr.MoveToElement()
                    }

                    # Push this element onto the stack only if it is NOT self-closing.
                    # Self-closing elements emit no EndElement event and have no children.
                    if (-not $isEmptyElem) {
                        $elementStack.Push(@{
                            FullPath       = $fullPath
                            NormPath       = $normPath
                            Name           = $elName
                            ParentFullPath = $parentFullPath
                            Line           = $elLine
                            Column         = $elCol
                            ChildCounts    = @{}
                        })
                    }
                }

                # ---- Text node -----------------------------------------------
                ([System.Xml.XmlNodeType]::Text) {
                    if ($elementStack.Count -gt 0) {
                        $cur       = $elementStack.Peek()
                        $textValue = $xr.Value
                        $textLine  = $xr.LineNumber
                        $textCol   = $xr.LinePosition

                        $records.Add([PSCustomObject]@{
                            SourceFile     = $fileName
                            Format         = 'xml'
                            RecordKey      = $cur.ParentFullPath
                            RecordIndex    = 0
                            FieldName      = $cur.Name
                            NormalizedPath = $cur.NormPath
                            Path           = $cur.FullPath
                            Value          = $textValue
                            Line           = $textLine
                            Column         = $textCol
                            Raw            = $textValue
                        })
                    }
                }

                # ---- CDATA section -------------------------------------------
                ([System.Xml.XmlNodeType]::CDATA) {
                    if ($elementStack.Count -gt 0) {
                        $cur       = $elementStack.Peek()
                        $textValue = $xr.Value
                        $textLine  = $xr.LineNumber
                        $textCol   = $xr.LinePosition

                        $records.Add([PSCustomObject]@{
                            SourceFile     = $fileName
                            Format         = 'xml'
                            RecordKey      = $cur.ParentFullPath
                            RecordIndex    = 0
                            FieldName      = $cur.Name
                            NormalizedPath = $cur.NormPath
                            Path           = $cur.FullPath
                            Value          = $textValue
                            Line           = $textLine
                            Column         = $textCol
                            Raw            = $textValue
                        })
                    }
                }

                # ---- End of element ------------------------------------------
                ([System.Xml.XmlNodeType]::EndElement) {
                    if ($elementStack.Count -gt 0) {
                        [void]$elementStack.Pop()
                    }
                }
            }
        }
    } catch {
        throw "Failed to parse XML file '$fileName': $_"
    } finally {
        if ($null -ne $xr) { $xr.Close() }
    }

    # ------------------------------------------------------------------
    # Pass 2: Load XmlDocument for XPathExists rule evaluation.
    # ------------------------------------------------------------------
    $doc = [System.Xml.XmlDocument]::new()
    try {
        $doc.Load($FilePath)
    } catch {
        throw "Failed to load XML document '$fileName' for XPath evaluation: $_"
    }

    if ($records.Count -eq 0) {
        Write-Warning "XML file produced no parseable records: $fileName"
    }

    return @{ Records = $records; Document = $doc }
}
