#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-validates a CSV or XML import file against a JSON rules configuration.

.DESCRIPTION
    Validate-Imports.ps1 is the CLI entry point for the data-prevalidator toolkit.

    It:
      1. Loads rules from a JSON configuration file.
      2. Parses the import file (CSV or XML) into normalised records.
      3. Runs the rule engine against those records.
      4. Writes a colour-coded console report and, optionally, a JSON report.
      5. Exits with an automation-friendly exit code.

    Exit codes
    ----------
    0  No violations at or above the -FailOn threshold.
    1  Warnings found, no errors (only relevant when -FailOn Warning).
    2  One or more Errors found.
    3  Fatal error (bad arguments, file not found, parse failure).

.PARAMETER FilePath
    Path to the CSV or XML file to validate.

.PARAMETER RulesFile
    Path to the JSON file containing validation rules.

.PARAMETER ReportPath
    Optional. If supplied, a machine-readable JSON report is written to this path.

.PARAMETER Format
    Force the parser to treat the input as 'csv' or 'xml'.
    Default is 'auto', which infers the format from the file extension.

.PARAMETER FailOn
    Minimum severity level that causes a non-zero exit code.
    'Error'   (default) — only errors cause a non-zero exit.
    'Warning' — warnings also cause a non-zero exit.

.PARAMETER Quiet
    Suppress all console output.  Useful in CI pipelines where only the
    JSON report and exit code are needed.

.EXAMPLE
    .\Validate-Imports.ps1 -FilePath .\Samples\customers.csv -RulesFile .\Rules\example-csv-rules.json

.EXAMPLE
    .\Validate-Imports.ps1 `
        -FilePath   .\Samples\orders.xml `
        -RulesFile  .\Rules\example-xml-rules.json `
        -ReportPath .\Reports\orders-report.json

.EXAMPLE
    .\Validate-Imports.ps1 `
        -FilePath   data.csv `
        -RulesFile  rules.json `
        -ReportPath report.json `
        -FailOn     Error `
        -Quiet
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'Path to the CSV or XML file to validate.')]
    [string] $FilePath,

    [Parameter(Mandatory, HelpMessage = 'Path to the JSON rules configuration file.')]
    [string] $RulesFile,

    [Parameter(HelpMessage = 'Destination path for the JSON report.')]
    [string] $ReportPath,

    [Parameter(HelpMessage = "Force format: 'csv', 'xml', or 'auto' (default).")]
    [ValidateSet('csv', 'xml', 'auto')]
    [string] $Format = 'auto',

    [Parameter(HelpMessage = "Exit non-zero when violations at or above this severity are found.")]
    [ValidateSet('Error', 'Warning')]
    [string] $FailOn = 'Error',

    [Parameter(HelpMessage = 'Suppress all console output.')]
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Bootstrap: dot-source modules relative to this script's location
# ---------------------------------------------------------------------------
$scriptRoot = $PSScriptRoot

foreach ($module in @('Parser.Csv', 'Parser.Xml', 'Rules.Engine', 'Reporter')) {
    $modulePath = Join-Path $scriptRoot "Modules\$module.ps1"
    if (-not (Test-Path -LiteralPath $modulePath)) {
        Write-Error "Required module not found: $modulePath"
        exit 3
    }
    . $modulePath
}

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$FilePath  = [System.IO.Path]::GetFullPath($FilePath)
$RulesFile = [System.IO.Path]::GetFullPath($RulesFile)

if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    Write-Error "Import file not found: $FilePath"
    exit 3
}

if (-not (Test-Path -LiteralPath $RulesFile -PathType Leaf)) {
    Write-Error "Rules file not found: $RulesFile"
    exit 3
}

# ---------------------------------------------------------------------------
# Detect format
# ---------------------------------------------------------------------------
if ($Format -eq 'auto') {
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $Format = switch ($ext) {
        '.csv'  { 'csv' }
        '.xml'  { 'xml' }
        default {
            Write-Error "Cannot auto-detect format for extension '$ext'. Use -Format csv or -Format xml."
            exit 3
        }
    }
}

# ---------------------------------------------------------------------------
# Load rules
# ---------------------------------------------------------------------------
if (-not $Quiet) {
    Write-Host "Loading rules from: $RulesFile" -ForegroundColor DarkGray
}

$rulesJson = $null
try {
    $rulesJson = Get-Content -LiteralPath $RulesFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Error "Failed to load rules file '$RulesFile': $_"
    exit 3
}

if (-not $rulesJson.PSObject.Properties['rules'] -or $rulesJson.rules.Count -eq 0) {
    Write-Error "Rules file contains no 'rules' array: $RulesFile"
    exit 3
}

$rules = @($rulesJson.rules)

if (-not $Quiet) {
    Write-Host "  Loaded $($rules.Count) rule(s)." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Parse the import file
# ---------------------------------------------------------------------------
if (-not $Quiet) {
    Write-Host "Parsing $($Format.ToUpper()) file: $FilePath" -ForegroundColor DarkGray
}

$records     = $null
$xmlDocument = $null

try {
    if ($Format -eq 'csv') {
        $records = Invoke-CsvParser -FilePath $FilePath
    } else {
        $parseResult = Invoke-XmlParser -FilePath $FilePath
        $records     = $parseResult.Records
        $xmlDocument = $parseResult.Document
    }
} catch {
    Write-Error "Parse failure: $_"
    exit 3
}

if (-not $Quiet) {
    Write-Host "  Parsed $($records.Count) record field(s)." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Run the rule engine
# ---------------------------------------------------------------------------
$violations = $null

try {
    $engineParams = @{
        Records = $records
        Rules   = $rules
    }
    if ($null -ne $xmlDocument) {
        $engineParams['XmlDocument'] = $xmlDocument
    }

    $violations = @(Invoke-RuleEngine @engineParams)
} catch {
    Write-Error "Rule engine failure: $_"
    exit 3
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$sourceFileName = Split-Path $FilePath -Leaf
$errorCount     = @($violations | Where-Object { $_.Severity -eq 'Error'   }).Count
$warningCount   = @($violations | Where-Object { $_.Severity -eq 'Warning' }).Count
$passed         = $errorCount -eq 0

if (-not $Quiet) {
    Write-ConsoleReport `
        -Violations  $violations `
        -RecordCount $records.Count `
        -SourceFile  $sourceFileName
}

if ($ReportPath) {
    $ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
    Export-JsonReport `
        -Violations  $violations `
        -RecordCount $records.Count `
        -SourceFile  $sourceFileName `
        -OutputPath  $ReportPath `
        -Passed      $passed
}

# ---------------------------------------------------------------------------
# Exit code
# ---------------------------------------------------------------------------
if ($errorCount -gt 0) {
    exit 2
}

if ($FailOn -eq 'Warning' -and $warningCount -gt 0) {
    exit 1
}

exit 0
