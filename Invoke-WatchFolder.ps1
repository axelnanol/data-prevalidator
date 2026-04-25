#Requires -Version 5.1
<#
.SYNOPSIS
    Batch pre-validates all CSV/XML files in a watch folder and quarantines
    failures to an errors folder.

.DESCRIPTION
    Invoke-WatchFolder.ps1 is designed to sit at the start of an automated
    import workflow triggered by files being dropped into a watch folder.

    For every CSV or XML file found in the watch folder it:
      1. Validates the file against the supplied JSON rules.
      2. If the file PASSES  — leaves it in place for the downstream workflow
         to process as normal.
      3. If the file FAILS   — writes a JSON validation report beside the file
         in the errors folder, then moves the file itself there so it is
         quarantined and never reaches the import step.
      4. Prints a colour-coded batch summary to the console and, optionally,
         writes a machine-readable JSON batch summary.

    Multiple watch folders on the same server can each be configured with their
    own -RulesFile, so different import schemas are handled independently.

    Exit codes
    ----------
    0  All files passed validation (or the folder was empty).
    1  No errors, but warnings were found (only relevant when -FailOn Warning).
    2  One or more files contained errors and were quarantined.
    3  Fatal — bad arguments, folder/rules file not found, or unrecoverable error.

.PARAMETER WatchFolder
    Path to the folder containing the drop files to validate.
    Sub-folders are NOT scanned; only files directly in this folder are checked.
    The errors sub-folder is excluded automatically.

.PARAMETER RulesFile
    Path to the JSON validation rules file that applies to this watch folder.

.PARAMETER ErrorFolder
    Folder where failing files (and their validation reports) are moved.
    Defaults to a sub-folder named 'errors' inside the watch folder.
    Created automatically if it does not exist.

.PARAMETER ReportFolder
    Folder where per-file JSON reports for PASSING files are written, if you
    want to keep an audit trail for good files too.
    If omitted, reports are only written for failing files (in ErrorFolder).

.PARAMETER BatchReportPath
    Optional. If supplied, a single JSON file summarising the entire batch run
    is written to this path.

.PARAMETER FilePattern
    Comma-separated list of file extensions to process (without the dot).
    Default: 'csv,xml'

.PARAMETER FailOn
    Minimum severity level that causes a file to be treated as failed.
    'Error'   (default) — only errors quarantine a file.
    'Warning' — warnings also cause the file to be quarantined.

.PARAMETER Quiet
    Suppress per-file console output.  The batch summary is still printed.

.EXAMPLE
    # Validate all files in a watch folder using the folder's own rules schema
    .\Invoke-WatchFolder.ps1 `
        -WatchFolder C:\Imports\Invoices `
        -RulesFile   C:\Imports\Invoices\rules\invoice-rules.json

.EXAMPLE
    # Full usage with custom error folder and batch report
    .\Invoke-WatchFolder.ps1 `
        -WatchFolder     C:\Imports\CustomerData `
        -RulesFile       C:\Schemas\customer-rules.json `
        -ErrorFolder     C:\Imports\CustomerData\errors `
        -BatchReportPath C:\Logs\customer-batch-$(Get-Date -Format 'yyyyMMdd-HHmmss').json `
        -FailOn          Error

.EXAMPLE
    # Quiet mode — only the summary and exit code matter (for automation logs)
    .\Invoke-WatchFolder.ps1 `
        -WatchFolder C:\Imports\Orders `
        -RulesFile   C:\Schemas\orders-rules.json `
        -Quiet
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'Path to the watch folder to process.')]
    [string] $WatchFolder,

    [Parameter(Mandatory, HelpMessage = 'Path to the JSON rules file for this watch folder.')]
    [string] $RulesFile,

    [Parameter(HelpMessage = 'Folder where failing files are moved. Defaults to <WatchFolder>\errors.')]
    [string] $ErrorFolder,

    [Parameter(HelpMessage = 'Folder where per-file reports for passing files are written (optional audit trail).')]
    [string] $ReportFolder,

    [Parameter(HelpMessage = 'Path for the JSON batch summary report (optional).')]
    [string] $BatchReportPath,

    [Parameter(HelpMessage = "Comma-separated file extensions to process. Default: 'csv,xml'")]
    [string] $FilePattern = 'csv,xml',

    [Parameter(HelpMessage = "Severity threshold for quarantine: 'Error' (default) or 'Warning'.")]
    [ValidateSet('Error', 'Warning')]
    [string] $FailOn = 'Error',

    [Parameter(HelpMessage = 'Suppress per-file console output.')]
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Bootstrap modules
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
# Resolve and validate paths
# ---------------------------------------------------------------------------
$WatchFolder = [System.IO.Path]::GetFullPath($WatchFolder)
$RulesFile   = [System.IO.Path]::GetFullPath($RulesFile)

if (-not (Test-Path -LiteralPath $WatchFolder -PathType Container)) {
    Write-Error "Watch folder not found: $WatchFolder"
    exit 3
}

if (-not (Test-Path -LiteralPath $RulesFile -PathType Leaf)) {
    Write-Error "Rules file not found: $RulesFile"
    exit 3
}

# Default error folder: <WatchFolder>\errors
if (-not $ErrorFolder) {
    $ErrorFolder = Join-Path $WatchFolder 'errors'
}
$ErrorFolder = [System.IO.Path]::GetFullPath($ErrorFolder)

# Resolve optional folders
if ($ReportFolder) {
    $ReportFolder = [System.IO.Path]::GetFullPath($ReportFolder)
}
if ($BatchReportPath) {
    $BatchReportPath = [System.IO.Path]::GetFullPath($BatchReportPath)
}

# ---------------------------------------------------------------------------
# Load rules once (shared across all files in this batch)
# ---------------------------------------------------------------------------
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

Write-Host ''
Write-Host "=== data-prevalidator  |  Watch Folder Batch ===" -ForegroundColor Cyan
Write-Host "  Folder    : $WatchFolder"  -ForegroundColor DarkGray
Write-Host "  Rules     : $RulesFile ($($rules.Count) rule(s))" -ForegroundColor DarkGray
Write-Host "  ErrorFolder: $ErrorFolder" -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# Discover files  (exclude the errors sub-folder itself)
# ---------------------------------------------------------------------------
$extensions = $FilePattern -split ',' | ForEach-Object { $_.Trim().TrimStart('.').ToLowerInvariant() }

$candidateFiles = @(Get-ChildItem -LiteralPath $WatchFolder -File |
    Where-Object {
        $ext = $_.Extension.TrimStart('.').ToLowerInvariant()
        $ext -in $extensions -and
        $_.FullName -notlike "$ErrorFolder*"
    })

if ($candidateFiles.Count -eq 0) {
    Write-Host '  No files to process.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

Write-Host "  Found $($candidateFiles.Count) file(s) to validate." -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# Process each file
# ---------------------------------------------------------------------------
$batchResults = [System.Collections.Generic.List[PSObject]]::new()

$batchErrorCount   = 0
$batchWarningCount = 0
$batchPassCount    = 0

foreach ($file in $candidateFiles) {

    $fileName = $file.Name
    $filePath = $file.FullName

    if (-not $Quiet) {
        Write-Host "  Validating: $fileName" -ForegroundColor DarkGray
    }

    # --- Detect format ---
    $ext    = $file.Extension.ToLowerInvariant()
    $format = switch ($ext) {
        '.csv'  { 'csv' }
        '.xml'  { 'xml' }
        default { 'unknown' }
    }

    if ($format -eq 'unknown') {
        Write-Warning "  Skipping '$fileName' — unsupported extension '$ext'."
        continue
    }

    # --- Parse ---
    $records     = $null
    $xmlDocument = $null
    $parseError  = $null

    try {
        if ($format -eq 'csv') {
            $records = Invoke-CsvParser -FilePath $filePath
        } else {
            $parseResult = Invoke-XmlParser -FilePath $filePath
            $records     = $parseResult.Records
            $xmlDocument = $parseResult.Document
        }
    } catch {
        $parseError = $_.ToString()
        Write-Warning "  Parse failure for '$fileName': $parseError"
    }

    # --- Run rules (or record a parse failure) ---
    $violations = @()

    if ($null -ne $parseError) {
        # Treat parse failure as a single fatal Error violation
        $violations = @([PSCustomObject]@{
            RuleName   = 'ParseFailure'
            RuleType   = 'ParseFailure'
            Severity   = 'Error'
            Message    = "File could not be parsed: $parseError"
            SourceFile = $fileName
            Format     = $format
            Path       = ''
            Value      = ''
            Line       = 0
            Column     = 0
            Timestamp  = (Get-Date -Format 'o')
        })
    } else {
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
            Write-Warning "  Rule engine failure for '$fileName': $_"
            $violations = @([PSCustomObject]@{
                RuleName   = 'RuleEngineFailure'
                RuleType   = 'RuleEngineFailure'
                Severity   = 'Error'
                Message    = "Rule engine failed: $_"
                SourceFile = $fileName
                Format     = $format
                Path       = ''
                Value      = ''
                Line       = 0
                Column     = 0
                Timestamp  = (Get-Date -Format 'o')
            })
        }
    }

    $errorCount   = @($violations | Where-Object { $_.Severity -eq 'Error'   }).Count
    $warningCount = @($violations | Where-Object { $_.Severity -eq 'Warning' }).Count
    $recordCount  = if ($null -ne $records) { $records.Count } else { 0 }

    # A file "fails" if it has violations at or above the FailOn threshold
    $fileFailed = $errorCount -gt 0 -or ($FailOn -eq 'Warning' -and $warningCount -gt 0)
    $filePassed = -not $fileFailed

    # --- Write report ---
    $reportDestFolder = if ($fileFailed) { $ErrorFolder } elseif ($ReportFolder) { $ReportFolder } else { $null }

    $reportFilePath = $null
    if ($null -ne $reportDestFolder) {
        if (-not (Test-Path -LiteralPath $reportDestFolder)) {
            New-Item -ItemType Directory -Path $reportDestFolder -Force | Out-Null
        }
        $reportFileName = "$([System.IO.Path]::GetFileNameWithoutExtension($fileName))-validation-report.json"
        $reportFilePath = Join-Path $reportDestFolder $reportFileName

        Export-JsonReport `
            -Violations  $violations `
            -RecordCount $recordCount `
            -SourceFile  $fileName `
            -OutputPath  $reportFilePath `
            -Passed      $filePassed
    }

    # --- Move failing file to error folder ---
    $movedTo = $null
    if ($fileFailed) {
        if (-not (Test-Path -LiteralPath $ErrorFolder)) {
            New-Item -ItemType Directory -Path $ErrorFolder -Force | Out-Null
        }

        $destPath = Join-Path $ErrorFolder $fileName

        # Handle name collision in error folder (append timestamp)
        if (Test-Path -LiteralPath $destPath) {
            $ts       = Get-Date -Format 'yyyyMMdd-HHmmss'
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $extension = [System.IO.Path]::GetExtension($fileName)
            $destPath = Join-Path $ErrorFolder "$baseName-$ts$extension"
        }

        Move-Item -LiteralPath $filePath -Destination $destPath
        $movedTo = $destPath
    }

    # --- Per-file console output ---
    if (-not $Quiet) {
        if ($filePassed) {
            Write-Host "    [PASS] $fileName ($recordCount records checked, $errorCount errors, $warningCount warnings)" `
                -ForegroundColor Green
        } else {
            Write-Host "    [FAIL] $fileName — $errorCount error(s), $warningCount warning(s) — moved to errors folder" `
                -ForegroundColor Red
            if ($violations.Count -gt 0) {
                foreach ($v in ($violations | Select-Object -First 5)) {
                    $loc = if ($v.Line -gt 0) { " [Line $($v.Line)]" } else { '' }
                    Write-Host "           [$($v.Severity)] $($v.RuleName)$loc — $($v.Path): $($v.Message)" `
                        -ForegroundColor DarkRed
                }
                if ($violations.Count -gt 5) {
                    Write-Host "           ... and $($violations.Count - 5) more violation(s) — see report for full details." `
                        -ForegroundColor DarkGray
                }
            }
        }
    }

    # Accumulate batch totals
    if ($filePassed) {
        $batchPassCount++
    } else {
        $batchErrorCount++
        $batchWarningCount += $warningCount
    }

    $batchResults.Add([PSCustomObject]@{
        FileName        = $fileName
        Format          = $format
        Passed          = $filePassed
        RecordCount     = $recordCount
        ErrorCount      = $errorCount
        WarningCount    = $warningCount
        ViolationCount  = $violations.Count
        MovedTo         = $movedTo
        ReportPath      = $reportFilePath
        Violations      = $violations
    })
}

# ---------------------------------------------------------------------------
# Batch summary — always shown (even in Quiet mode)
# ---------------------------------------------------------------------------
$totalFiles = $batchResults.Count

Write-Host ''
Write-Host ('--- Batch Summary ' + ('-' * 44)) -ForegroundColor DarkGray
Write-Host "  Watch folder : $WatchFolder"            -ForegroundColor Gray
Write-Host "  Files found  : $totalFiles"             -ForegroundColor Gray
Write-Host "  Passed       : $batchPassCount"         -ForegroundColor $(if ($batchPassCount -gt 0) { 'Green' } else { 'Gray' })

if ($batchErrorCount -gt 0) {
    Write-Host "  Failed       : $batchErrorCount  (moved to $ErrorFolder)" -ForegroundColor Red
} else {
    Write-Host "  Failed       : 0"                    -ForegroundColor Green
}
Write-Host ''

# ---------------------------------------------------------------------------
# Write batch summary report
# ---------------------------------------------------------------------------
if ($BatchReportPath) {
    $batchReport = [PSCustomObject]@{
        GeneratedAt  = (Get-Date -Format 'o')
        WatchFolder  = $WatchFolder
        RulesFile    = $RulesFile
        ErrorFolder  = $ErrorFolder
        FailOn       = $FailOn
        TotalFiles   = $totalFiles
        PassedCount  = $batchPassCount
        FailedCount  = $batchErrorCount
        AllPassed    = ($batchErrorCount -eq 0)
        Files        = $batchResults | Select-Object FileName, Format, Passed, RecordCount, ErrorCount, WarningCount, ViolationCount, MovedTo, ReportPath
    }

    $batchReportDir = Split-Path $BatchReportPath -Parent
    if ($batchReportDir -and -not (Test-Path -LiteralPath $batchReportDir)) {
        New-Item -ItemType Directory -Path $batchReportDir -Force | Out-Null
    }

    $batchReport | ConvertTo-Json -Depth 10 | Set-Content -Path $BatchReportPath -Encoding UTF8
    Write-Host "  Batch report saved: $BatchReportPath" -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Exit code
# ---------------------------------------------------------------------------
if ($batchErrorCount -gt 0) {
    exit 2
}

if ($FailOn -eq 'Warning' -and $batchWarningCount -gt 0) {
    exit 1
}

exit 0
