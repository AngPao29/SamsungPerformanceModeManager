function Initialize-ModeEngineTestContext {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $mainScriptPath = Join-Path $repoRoot 'PerformanceManagerGB.ps1'

    $tokens = $null
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($mainScriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Impossibile analizzare PerformanceManagerGB.ps1: $($parseErrors[0].Message)"
    }

    function script:Import-MainTopLevelAssignment {
        param(
            [System.Management.Automation.Language.ScriptBlockAst]$Ast,
            [string]$VariableName
        )

        $assignment = $Ast.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { return $false }
            if ($node.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
            if ($node.Left.VariablePath.UserPath -ne $VariableName) { return $false }

            $parent = $node.Parent
            while ($parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false }
                $parent = $parent.Parent
            }
            return $true
        }, $true) | Select-Object -First 1

        if ($null -eq $assignment) {
            throw "Assegnazione non trovata nel file principale: `$${VariableName}"
        }

        $assignmentText = $assignment.Extent.Text
        $pattern = '^\s*\$' + [regex]::Escape($VariableName) + '\s*='
        $assignmentText = [regex]::Replace($assignmentText, $pattern, ('$script:' + $VariableName + ' ='), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        Invoke-Expression $assignmentText
    }

    function script:Import-MainFunction {
        param(
            [System.Management.Automation.Language.ScriptBlockAst]$Ast,
            [string]$FunctionName
        )

        $functionAst = $Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
        }, $true)

        if ($null -eq $functionAst) {
            throw "Funzione non trovata nel file principale: $FunctionName"
        }

        $definitionText = $functionAst.Extent.Text
        $pattern = '^\s*function\s+' + [regex]::Escape($FunctionName) + '\b'
        $definitionText = [regex]::Replace($definitionText, $pattern, ("function script:$FunctionName"), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        Invoke-Expression $definitionText
    }

    foreach ($varName in @(
            'MODE_NO_NOISE',
            'MODE_SILENT',
            'MODE_OPTIMIZED',
            'MODE_HIGH_PERFORMANCE',
            'MODE_NAMES',
            'MODE_EXPECTED_PL1_W',
            'MODE_VISUALS',
            'BATTERY_STATUS_NAMES',
            'AC_STATUSES',
            'hysteresisMargin',
            'chargeTolerance',
            'pl1VerifyMaxAttempts',
            'pl1VerifyRetryDelayMs',
            'regPerformance'
        )) {
        Import-MainTopLevelAssignment -Ast $scriptAst -VariableName $varName
    }

    # Accelera i retry PL1 nei test
    $script:pl1VerifyMaxAttempts = 3
    $script:pl1VerifyRetryDelayMs = 1
    $script:_pl1TelemetryCimCandidates = @()

    $script:trayState = [hashtable]::Synchronized(@{
        CurrentMode             = 'Ottimizzata'
        ChargePercent           = 0
        IsOnAC                  = $false
        IsPaused                = $false
        SoundEnabled            = $true
        NotifPopupEnabled       = $true
        ControlMode             = 'Auto'
        RequestedMode           = $null
        RequestedModeSource     = $null
        ManualOverrideMode      = $null
        ManualOverrideSource    = $null
        ManualOverrideTimestamp = $null
    })

    function script:Write-Log { param([string]$Message) }
    function script:Play-NotificationSound {}
    function script:Show-ModeNotification {
        param([string]$ModeName,[string]$IconGlyph,[string]$AccentColor,[string]$Subtitle = '')
    }
    function script:Get-BatteryProtectionLimit { return 80 }
    function script:Get-CurrentPerformanceMode { return 2 }
    function script:Set-PerformanceMode { param([int]$Mode) }
    foreach ($fnName in @(
            'Convert-ToPl1Watts',
            'Get-Pl1TelemetryFromCimRuntime',
            'Get-Pl1TelemetryFromSamsungRegistry',
            'Get-ExpectedModePl1W',
            'Get-DynamicPl1Telemetry',
            'Wait-Pl1VerificationDelay',
            'Invoke-ModeSelection',
            'Update-PerformanceMode'
        )) {
        Import-MainFunction -Ast $scriptAst -FunctionName $fnName
    }

    function script:Invoke-ForcedModeRequest {
        param(
            [int]$RequestedMode,
            [string]$RequestedModeSource = 'Tray'
        )

        $reqModeName = $script:MODE_NAMES[$RequestedMode]
        if (-not $reqModeName) { return $false }

        try {
            Invoke-ModeSelection -Mode $RequestedMode -Subtitle 'Impostata manualmente' -PlaySound
            $script:trayState.CurrentMode = $reqModeName
            $script:trayState.ControlMode = 'Manual'
            $script:trayState.ManualOverrideMode = $RequestedMode
            $script:trayState.ManualOverrideSource = $RequestedModeSource
            $script:trayState.ManualOverrideTimestamp = Get-Date
            return $true
        }
        catch {
            Write-Log "ERROR [tray] Impossibile forzare modalita': $_"
            return $false
        }
    }
}
