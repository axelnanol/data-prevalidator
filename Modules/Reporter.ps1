#Requires -Version 5.1
<#
.SYNOPSIS
    Reporting functions — console and JSON.
.DESCRIPTION
    Write-ConsoleReport  : Writes a colour-coded summary to the host.
    Export-JsonReport    : Saves a machine-readable JSON report to disk.
#>

function Write-ConsoleReport {
    <#
    .SYNOPSIS
        Writes a colour-coded validation report to the console.
    .PARAMETER Violations
        Array of violation objects returned by Invoke-RuleEngine.
    .PARAMETER RecordCount
        Total number of ParsedRecord objects that were validated.
    .PARAMETER SourceFile
        Name of the file that was validated (used in the summary line).
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [array] $Violations = @(),
        [Parameter(Mandatory)] [int]     $RecordCount,
        [Parameter(Mandatory)] [string]  $SourceFile
    )

    $errors   = @($Violations | Where-Object { $_.Severity -eq 'Error'   })
    $warnings = @($Violations | Where-Object { $_.Severity -eq 'Warning' })
    $infos    = @($Violations | Where-Object { $_.Severity -eq 'Info'    })

    Write-Host ''
    Write-Host "=== data-prevalidator  |  $SourceFile ===" -ForegroundColor Cyan
    Write-Host ''

    if ($Violations.Count -eq 0) {
        Write-Host '  No violations found.' -ForegroundColor Green
    } else {
        # Sort: errors first, then warnings, then info; within each group by path
        $sorted = $Violations | Sort-Object @{ Expression = {
            switch ($_.Severity) { 'Error' { 0 } 'Warning' { 1 } default { 2 } }
        }}, Path

        foreach ($v in $sorted) {
            $color = switch ($v.Severity) {
                'Error'   { 'Red'    }
                'Warning' { 'Yellow' }
                default   { 'Cyan'   }
            }

            $location = ''
            if ($v.Line -gt 0) {
                $location = " [Line $($v.Line)"
                if ($v.Column -gt 0) { $location += ", Col $($v.Column)" }
                $location += ']'
            }

            Write-Host "  [$($v.Severity.ToUpper())] $($v.RuleName)$location" -ForegroundColor $color
            Write-Host "    File    : $($v.SourceFile)"  -ForegroundColor DarkGray
            Write-Host "    Path    : $($v.Path)"        -ForegroundColor DarkGray
            Write-Host "    Value   : '$($v.Value)'"     -ForegroundColor DarkGray
            Write-Host "    Message : $($v.Message)"     -ForegroundColor DarkGray
            Write-Host ''
        }
    }

    Write-Host ('--- Summary ' + ('-' * 50)) -ForegroundColor DarkGray
    Write-Host "  File             : $SourceFile"   -ForegroundColor Gray
    Write-Host "  Records checked  : $RecordCount"  -ForegroundColor Gray

    if ($errors.Count -gt 0) {
        Write-Host "  Errors           : $($errors.Count)"   -ForegroundColor Red
    } else {
        Write-Host "  Errors           : 0"                  -ForegroundColor Green
    }

    if ($warnings.Count -gt 0) {
        Write-Host "  Warnings         : $($warnings.Count)" -ForegroundColor Yellow
    } else {
        Write-Host "  Warnings         : 0"                  -ForegroundColor Green
    }

    if ($infos.Count -gt 0) {
        Write-Host "  Info             : $($infos.Count)"    -ForegroundColor Cyan
    }

    Write-Host ''
}

function Export-JsonReport {
    <#
    .SYNOPSIS
        Writes a machine-readable JSON report to the specified path.
    .PARAMETER Violations
        Array of violation objects returned by Invoke-RuleEngine.
    .PARAMETER RecordCount
        Total number of ParsedRecord objects that were validated.
    .PARAMETER SourceFile
        Name of the file that was validated.
    .PARAMETER OutputPath
        Destination path for the JSON file.
    .PARAMETER Passed
        Boolean indicating whether validation passed (no errors).
    #>
    param(
        [Parameter(Mandatory = $false)] [AllowNull()] [array] $Violations = @(),
        [Parameter(Mandatory)] [int]     $RecordCount,
        [Parameter(Mandatory)] [string]  $SourceFile,
        [Parameter(Mandatory)] [string]  $OutputPath,
        [Parameter(Mandatory)] [bool]    $Passed
    )

    $report = [PSCustomObject]@{
        GeneratedAt      = (Get-Date -Format 'o')
        SourceFile       = $SourceFile
        RecordsValidated = $RecordCount
        Passed           = $Passed
        ViolationCount   = $Violations.Count
        ErrorCount       = @($Violations | Where-Object { $_.Severity -eq 'Error'   }).Count
        WarningCount     = @($Violations | Where-Object { $_.Severity -eq 'Warning' }).Count
        InfoCount        = @($Violations | Where-Object { $_.Severity -eq 'Info'    }).Count
        Violations       = $Violations
    }

    $outputDir = Split-Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host "  Report saved: $OutputPath" -ForegroundColor DarkGray
}
