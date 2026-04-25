# data-prevalidator

A lightweight, rule-driven PowerShell toolkit for pre-validating CSV and XML import files **before** they reach downstream systems.

---

## Overview

`data-prevalidator` validates structured import files against a JSON rules configuration. It normalises CSV rows and XML nodes into a common internal representation so the same rule engine covers both formats.

Failures are reported with enough context (file name, path, offending value, rule name, severity, line/column where available) to let Support or On-Call diagnose issues without digging through raw files.

---

## Repository structure

```
.
├── Validate-Imports.ps1          # CLI entry point
├── Modules/
│   ├── Parser.Csv.ps1            # CSV adapter
│   ├── Parser.Xml.ps1            # XML adapter
│   ├── Rules.Engine.ps1          # Rule engine
│   └── Reporter.ps1              # Console + JSON reporting
├── Rules/
│   ├── example-csv-rules.json    # Example rules for CSV imports
│   └── example-xml-rules.json    # Example rules for XML imports
├── Samples/
│   ├── customers.csv             # Sample CSV data
│   └── orders.xml                # Sample XML data
└── Reports/                      # Default output directory (git-ignored)
```

---

## Requirements

- PowerShell 5.1 or PowerShell 7+
- No external modules required

---

## Quick start

```powershell
# Validate a CSV file
.\Validate-Imports.ps1 -FilePath .\Samples\customers.csv -RulesFile .\Rules\example-csv-rules.json

# Validate an XML file and save a JSON report
.\Validate-Imports.ps1 -FilePath .\Samples\orders.xml -RulesFile .\Rules\example-xml-rules.json -ReportPath .\Reports\orders-report.json

# Treat only Errors as failures (ignore Warnings for exit-code purposes)
.\Validate-Imports.ps1 -FilePath .\Samples\customers.csv -RulesFile .\Rules\example-csv-rules.json -FailOn Error

# Suppress console output (machine/CI mode — JSON report only)
.\Validate-Imports.ps1 -FilePath data.csv -RulesFile rules.json -ReportPath report.json -Quiet
```

---

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | No violations at or above `-FailOn` threshold |
| 1 | Warnings found (no errors) |
| 2 | One or more Errors found |
| 3 | Fatal — bad arguments, file not found, or parse failure |

---

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-FilePath` | String | ✔ | — | Path to the CSV or XML file to validate |
| `-RulesFile` | String | ✔ | — | Path to the JSON rules configuration |
| `-ReportPath` | String | | — | If provided, writes a machine-readable JSON report to this path |
| `-Format` | String | | `auto` | Force format: `csv`, `xml`, or `auto` (detected from extension) |
| `-FailOn` | String | | `Error` | Minimum severity that causes a non-zero exit: `Error` or `Warning` |
| `-Quiet` | Switch | | off | Suppress console output (useful in CI when only the report matters) |

---

## Rules file format

Rules are loaded from a JSON file.  A rules file may contain rules for CSV, XML, or both.

```json
{
  "rules": [
    {
      "name":        "UniqueRuleName",
      "description": "Optional human-readable description",
      "format":      "csv",
      "target":      "ColumnName",
      "type":        "Required",
      "severity":    "Error",
      "message":     "ColumnName must not be blank"
    }
  ]
}
```

### Common fields

| Field | Description |
|-------|-------------|
| `name` | Unique rule identifier (appears in reports) |
| `description` | Optional description |
| `format` | `csv`, `xml`, or `any` |
| `target` | For CSV: column name. For XML: normalised XPath (e.g. `/Orders/Order/@id`) |
| `type` | Rule type (see below) |
| `severity` | `Error`, `Warning`, or `Info` |
| `message` | Human-readable failure message |

---

## Supported rule types

### `Required`
Value must not be null or whitespace.
```json
{ "type": "Required" }
```

### `Regex`
Value must match the supplied regular expression.
```json
{ "type": "Regex", "pattern": "^ORD-[0-9]{6}$" }
```

### `AllowedValues`
Value must be one of the specified options.
```json
{ "type": "AllowedValues", "values": ["Active", "Inactive", "Pending"], "caseSensitive": false }
```

### `MinLength`
String length must be at least `min` characters.
```json
{ "type": "MinLength", "min": 2 }
```

### `MaxLength`
String length must not exceed `max` characters.
```json
{ "type": "MaxLength", "max": 100 }
```

### `NumericRange`
Value must parse as a number and fall within `[min, max]`. Omit either bound to leave it open.
```json
{ "type": "NumericRange", "min": 0, "max": 150 }
```

### `DateFormat`
Value must parse as a date matching the specified format string.
```json
{ "type": "DateFormat", "dateFormat": "yyyy-MM-dd" }
```

### `Unique`
Value must be unique across all records that match the target.
```json
{ "type": "Unique" }
```

### `DependsOn`
Target field is required when another field (`dependsOnField`) equals a specific value (`dependsOnValue`).
```json
{ "type": "DependsOn", "dependsOnField": "ContactMethod", "dependsOnValue": "Phone" }
```

### `ForbiddenValue`
Value must not equal the specified `value` (case-insensitive by default).
```json
{ "type": "ForbiddenValue", "value": "Deleted" }
```

### `XPathExists`
*(XML only)* The specified XPath expression must select at least one node in the document.
```json
{ "type": "XPathExists", "target": "/Orders/Order" }
```

---

## CSV rules — targeting

Set `"format": "csv"` and `"target"` to the **column header name** exactly as it appears in the CSV:

```json
{
  "name":     "EmailFormat",
  "format":   "csv",
  "target":   "Email",
  "type":     "Regex",
  "pattern":  "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$",
  "severity": "Error",
  "message":  "Email must be a valid email address"
}
```

---

## XML rules — targeting

Set `"format": "xml"` and `"target"` to a **normalised XPath** — the path without numeric indices.  The engine matches it against every node at that structural position.

```
/Orders/Order/@id          → all id attributes on Order elements
/Orders/Order/Customer     → all Customer text nodes inside Order
```

Wildcards (`*`) are supported:
```
/Orders/*/CustomerName     → CustomerName under any direct child of Orders
```

---

## JSON report format

```json
{
  "GeneratedAt":       "2026-04-25T18:00:00Z",
  "SourceFile":        "customers.csv",
  "RecordsValidated":  150,
  "Passed":            false,
  "ViolationCount":    3,
  "ErrorCount":        2,
  "WarningCount":      1,
  "InfoCount":         0,
  "Violations": [
    {
      "RuleName":   "CustomerNameRequired",
      "RuleType":   "Required",
      "Severity":   "Error",
      "Message":    "CustomerName is required and must not be blank",
      "SourceFile": "customers.csv",
      "Format":     "csv",
      "Path":       "Row[3].CustomerName",
      "Value":      "",
      "Line":       4,
      "Column":     1,
      "Timestamp":  "2026-04-25T18:00:00.000Z"
    }
  ]
}
```

---

## Example: validating the sample files

```powershell
# Clone the repo and cd into it
git clone https://github.com/axelnanol/data-prevalidator.git
Set-Location data-prevalidator

# Validate sample CSV
.\Validate-Imports.ps1 `
    -FilePath  .\Samples\customers.csv `
    -RulesFile .\Rules\example-csv-rules.json `
    -ReportPath .\Reports\customers-report.json

# Validate sample XML
.\Validate-Imports.ps1 `
    -FilePath  .\Samples\orders.xml `
    -RulesFile .\Rules\example-xml-rules.json `
    -ReportPath .\Reports\orders-report.json
```

---

## Adding your own rules

1. Copy one of the example rule files in `Rules/` and rename it for your import type.
2. Adjust (or add) rules for each field or path you want to enforce.
3. Point `-RulesFile` at the new file when running the validator.

---

## CI / automation usage

```yaml
# GitHub Actions example
- name: Validate import file
  shell: pwsh
  run: |
    .\Validate-Imports.ps1 `
      -FilePath  ${{ github.workspace }}/imports/data.csv `
      -RulesFile ${{ github.workspace }}/Rules/my-rules.json `
      -ReportPath ${{ github.workspace }}/Reports/report.json `
      -FailOn Error
    # Non-zero exit automatically fails the step
```

---

## Limitations (first version)

- CSV parser assumes no multi-line quoted fields (RFC 4180 line continuations).
- XML line-number tracking relies on `System.Xml.XmlTextReader`; very large files may have reduced accuracy.
- `DependsOn` is supported for CSV row grouping; XML grouping uses the immediate parent element path.