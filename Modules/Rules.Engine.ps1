#Requires -Version 5.1
<#
.SYNOPSIS
    Generic rule engine.
.DESCRIPTION
    Applies a list of JSON-loaded rules against a list of ParsedRecord objects
    (produced by Parser.Csv.ps1 or Parser.Xml.ps1) and returns violation objects.

    Supported rule types:
      Required, Regex, AllowedValues, MinLength, MaxLength,
      NumericRange, DateFormat, Unique, DependsOn, ForbiddenValue, XPathExists
#>

#region Helper functions

function New-Violation {
    <#
    .SYNOPSIS
        Constructs a violation object.
    #>
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] $Record,
        [string] $OverrideMessage = ''
    )

    return [PSCustomObject]@{
        RuleName   = $Rule.name
        RuleType   = $Rule.type
        Severity   = $Rule.severity
        Message    = if ($OverrideMessage) { $OverrideMessage } else { $Rule.message }
        SourceFile = $Record.SourceFile
        Format     = $Record.Format
        Path       = $Record.Path
        Value      = $Record.Value
        Line       = $Record.Line
        Column     = $Record.Column
        Timestamp  = (Get-Date -Format 'o')
    }
}

function Get-MatchingRecords {
    <#
    .SYNOPSIS
        Returns the subset of records that a rule targets.
    .DESCRIPTION
        For CSV rules the target is matched against the FieldName.
        For XML rules the target is matched against NormalizedPath (supports
        wildcards via -like).
    #>
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.List[PSObject]] $Records,
        [Parameter(Mandatory)] $Rule
    )

    $format = if ($Rule.PSObject.Properties['format']) { $Rule.format } else { 'any' }

    $scoped = if ($format -eq 'any') {
        $Records
    } else {
        $Records | Where-Object { $_.Format -eq $format }
    }

    if (-not $scoped) { return @() }

    $target = $Rule.target

    $matched = $scoped | Where-Object {
        $_.NormalizedPath -eq $target -or
        $_.NormalizedPath -like $target -or
        $_.FieldName      -eq $target
    }

    return @($matched)
}

#endregion

function Invoke-RuleEngine {
    <#
    .SYNOPSIS
        Runs all rules against the supplied records and returns violations.
    .PARAMETER Records
        ParsedRecord objects from a parser.
    .PARAMETER Rules
        Array of rule objects deserialized from a JSON rules file.
    .PARAMETER XmlDocument
        The raw XmlDocument; required only when XPathExists rules are present.
    .OUTPUTS
        System.Collections.Generic.List[PSObject]  (violation objects)
    #>
    [OutputType([System.Collections.Generic.List[PSObject]])]
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.List[PSObject]] $Records,
        [Parameter(Mandatory)] [array] $Rules,
        [System.Xml.XmlDocument] $XmlDocument = $null
    )

    $violations = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($rule in $Rules) {

        if (-not $rule.PSObject.Properties['type']) {
            Write-Warning "Rule '$($rule.name)' has no 'type' field — skipped."
            continue
        }

        if (-not $rule.PSObject.Properties['severity']) {
            Write-Warning "Rule '$($rule.name)' has no 'severity' field — defaulting to Warning."
            $rule | Add-Member -NotePropertyName severity -NotePropertyValue 'Warning' -Force
        }

        switch ($rule.type) {

            # ----------------------------------------------------------------
            'Required' {
                $targets = Get-MatchingRecords -Records $Records -Rule $rule
                foreach ($rec in $targets) {
                    if ([string]::IsNullOrWhiteSpace($rec.Value)) {
                        $violations.Add((New-Violation -Rule $rule -Record $rec))
                    }
                }
            }

            # ----------------------------------------------------------------
            'Regex' {
                if (-not $rule.PSObject.Properties['pattern']) {
                    Write-Warning "Rule '$($rule.name)': Regex rule missing 'pattern' — skipped."
                    continue
                }
                $targets = Get-MatchingRecords -Records $Records -Rule $rule
                foreach ($rec in $targets) {
                    if ([string]::IsNullOrWhiteSpace($rec.Value)) { continue }
                    if ($rec.Value -notmatch $rule.pattern) {
                        $violations.Add((New-Violation -Rule $rule -Record $rec))
                    }
                }
            }

            # ----------------------------------------------------------------
            'AllowedValues' {
                if (-not $rule.PSObject.Properties['values']) {
                    Write-Warning "Rule '$($rule.name)': AllowedValues rule missing 'values' — skipped."
                    continue
                }
                $caseSensitive = $rule.PSObject.Properties['caseSensitive'] -and $rule.caseSensitive -eq $true
                $allowed       = @($rule.values)

                $targets = Get-MatchingRecords -Records $Records -Rule $rule
                foreach ($rec in $targets) {
                    if ([string]::IsNullOrWhiteSpace($rec.Value)) { continue }

                    $matched = if ($caseSensitive) {
                        $allowed -ccontains $rec.Value
                    } else {
                        $allowed -icontains $rec.Value
                    }

                    if (-not $matched) {
                        $violations.Add((New-Violation -Rule $rule -Record $rec))
                    }
                }
            }

            # ----------------------------------------------------------------
            'MinLength' {
                if (-not $rule.PSObject.Properties['min']) {
                    Write-Warning "Rule '$($rule.name)': MinLength rule missing 'min' — skipped."
                    continue
                }
                $min     = [int]$rule.min
                $targets = Get-MatchingRecords -Records $Records -Rule $rule
                foreach ($rec in $targets) {
                    if ([string]::IsNullOrWhiteSpace($rec.Value)) { continue }
                    if ($rec.Value.Length -lt $min) {
                        $violations.Add((New-Violation -Rule $rule -Record $rec))
                    }
                }
            }

            # ----------------------------------------------------------------
            'MaxLength' {
                if (-not $rule.PSObject.Properties['max']) {
                    Write-Warning "Rule '$($rule.name)': MaxLength rule missing 'max' — skipped."
                    continue
                }
                $max     = [int]$rule.max
                $targets = Get-MatchingRecords -Records $Records -Rule $rule
                foreach ($rec in $targets) {
                    if ([string]::IsNullOrWhiteSpace($rec.Value)) { continue }
                    if ($rec.Value.Length -gt $max) {
                        $violations.Add((New-Violation -Rule $rule -Record $rec))
                    }
                }
            }

            # ----------------------------------------------------------------
            'NumericRange' {
                $hasMin  = $rule.PSObject.Properties['min']
                $hasMax  = $rule.PSObject.Properties['max']
                $targets = Get-MatchingRecords -Records $Records -Rule $rule

                foreach ($rec in $targets) {
                    if ([string]::IsNullOrWhiteSpace($rec.Value)) { continue }

                    $num = 0.0
                    if (-not [double]::TryParse(
                            $rec.Value,
                            [System.Globalization.NumberStyles]::Any,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [ref]$num)) {
                        $violations.Add((New-Violation -Rule $rule -Record $rec `
                            -OverrideMessage "$($rule.message) (value is not numeric)"))
                        continue
                    }

                    $fail = $false
                    if ($hasMin -and $num -lt [double]$rule.min) { $fail = $true }
                    if ($hasMax -and $num -gt [double]$rule.max) { $fail = $true }

                    if ($fail) {
                        $violations.Add((New-Violation -Rule $rule -Record $rec))
                    }
                }
            }

            # ----------------------------------------------------------------
            'DateFormat' {
                if (-not $rule.PSObject.Properties['dateFormat']) {
                    Write-Warning "Rule '$($rule.name)': DateFormat rule missing 'dateFormat' — skipped."
                    continue
                }
                $fmt     = $rule.dateFormat
                $targets = Get-MatchingRecords -Records $Records -Rule $rule

                foreach ($rec in $targets) {
                    if ([string]::IsNullOrWhiteSpace($rec.Value)) { continue }

                    $parsed = [datetime]::MinValue
                    $ok = [datetime]::TryParseExact(
                        $rec.Value,
                        $fmt,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None,
                        [ref]$parsed)

                    if (-not $ok) {
                        $violations.Add((New-Violation -Rule $rule -Record $rec))
                    }
                }
            }

            # ----------------------------------------------------------------
            'Unique' {
                $targets = Get-MatchingRecords -Records $Records -Rule $rule
                if (-not $targets) { continue }

                # Group values; flag duplicates
                $seen      = @{}
                $flagged   = [System.Collections.Generic.HashSet[string]]::new()

                foreach ($rec in $targets) {
                    $v = $rec.Value
                    if ($seen.ContainsKey($v)) {
                        [void]$flagged.Add($v)
                    } else {
                        $seen[$v] = $rec
                    }
                }

                # Emit a violation for every occurrence of a duplicate value
                foreach ($rec in $targets) {
                    if ($flagged.Contains($rec.Value)) {
                        $violations.Add((New-Violation -Rule $rule -Record $rec `
                            -OverrideMessage "$($rule.message) (duplicate value: '$($rec.Value)')"))
                    }
                }
            }

            # ----------------------------------------------------------------
            'DependsOn' {
                if (-not $rule.PSObject.Properties['dependsOnField']) {
                    Write-Warning "Rule '$($rule.name)': DependsOn rule missing 'dependsOnField' — skipped."
                    continue
                }
                if (-not $rule.PSObject.Properties['dependsOnValue']) {
                    Write-Warning "Rule '$($rule.name)': DependsOn rule missing 'dependsOnValue' — skipped."
                    continue
                }

                $format       = if ($rule.PSObject.Properties['format']) { $rule.format } else { 'any' }
                $scoped       = if ($format -eq 'any') { $Records } else { $Records | Where-Object { $_.Format -eq $format } }
                $depField     = $rule.dependsOnField
                $depValue     = $rule.dependsOnValue

                # Group all records by RecordKey
                $groups = @($scoped) | Group-Object -Property RecordKey

                foreach ($group in $groups) {
                    $groupRecords = @($group.Group)

                    # Find the record for the dependency field in this group
                    $depRecord = $groupRecords | Where-Object {
                        $_.FieldName -eq $depField -or $_.NormalizedPath -like "*$depField"
                    } | Select-Object -First 1

                    if ($null -eq $depRecord) { continue }

                    # Check if dependency condition is met
                    if ($depRecord.Value -ne $depValue) { continue }

                    # Condition met — target field must not be blank
                    $targetRecord = $groupRecords | Where-Object {
                        $_.FieldName -eq $rule.target -or $_.NormalizedPath -like "*$($rule.target)"
                    } | Select-Object -First 1

                    if ($null -eq $targetRecord -or [string]::IsNullOrWhiteSpace($targetRecord.Value)) {
                        $syntheticRecord = if ($null -ne $targetRecord) {
                            $targetRecord
                        } else {
                            # Target field not present at all — report at the dependency record's location
                            [PSCustomObject]@{
                                SourceFile     = $depRecord.SourceFile
                                Format         = $depRecord.Format
                                RecordKey      = $depRecord.RecordKey
                                RecordIndex    = $depRecord.RecordIndex
                                FieldName      = $rule.target
                                NormalizedPath = $rule.target
                                Path           = "$($depRecord.RecordKey).$($rule.target)"
                                Value          = ''
                                Line           = $depRecord.Line
                                Column         = 0
                                Raw            = ''
                            }
                        }
                        $violations.Add((New-Violation -Rule $rule -Record $syntheticRecord))
                    }
                }
            }

            # ----------------------------------------------------------------
            'ForbiddenValue' {
                if (-not $rule.PSObject.Properties['value']) {
                    Write-Warning "Rule '$($rule.name)': ForbiddenValue rule missing 'value' — skipped."
                    continue
                }
                $forbidden = $rule.value
                $targets   = Get-MatchingRecords -Records $Records -Rule $rule

                foreach ($rec in $targets) {
                    if ([string]::IsNullOrWhiteSpace($rec.Value)) { continue }
                    if ($rec.Value -ieq $forbidden) {
                        $violations.Add((New-Violation -Rule $rule -Record $rec))
                    }
                }
            }

            # ----------------------------------------------------------------
            'XPathExists' {
                if ($null -eq $XmlDocument) {
                    Write-Warning "Rule '$($rule.name)': XPathExists requires an XmlDocument (XML input only) — skipped."
                    continue
                }
                if (-not $rule.PSObject.Properties['target']) {
                    Write-Warning "Rule '$($rule.name)': XPathExists rule missing 'target' — skipped."
                    continue
                }

                $xpathResult = $XmlDocument.SelectNodes($rule.target)
                if ($null -eq $xpathResult -or $xpathResult.Count -eq 0) {
                    # Synthetic document-level record
                    $docRecord = [PSCustomObject]@{
                        SourceFile     = if ($Records.Count -gt 0) { $Records[0].SourceFile } else { 'unknown' }
                        Format         = 'xml'
                        RecordKey      = '/'
                        RecordIndex    = 0
                        FieldName      = $rule.target
                        NormalizedPath = $rule.target
                        Path           = $rule.target
                        Value          = ''
                        Line           = 0
                        Column         = 0
                        Raw            = ''
                    }
                    $violations.Add((New-Violation -Rule $rule -Record $docRecord))
                }
            }

            # ----------------------------------------------------------------
            default {
                Write-Warning "Rule '$($rule.name)': Unknown rule type '$($rule.type)' — skipped."
            }
        }
    }

    return $violations
}
