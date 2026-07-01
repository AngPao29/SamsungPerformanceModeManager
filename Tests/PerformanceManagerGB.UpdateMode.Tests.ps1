Describe 'PerformanceManagerGB - Percorso automatico' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers\PerformanceManagerGB.ModeEngine.TestHelpers.ps1')
        Initialize-ModeEngineTestContext
    }

    BeforeEach {
        $script:trayState.IsPaused = $false
        $script:trayState.ControlMode = 'Auto'
        $script:trayState.ManualOverrideMode = $null
        $script:trayState.CurrentMode = 'Ottimizzata'
        $script:trayState.ChargePercent = 0
        $script:trayState.IsOnAC = $false

        Mock Write-Log {}
        Mock Invoke-ModeSelection {}
        Mock Show-ModeNotification {}
        Mock Play-NotificationSound {}
        Mock Get-BatteryProtectionLimit { return 80 }
        Mock Get-CimInstance { [PSCustomObject]@{ EstimatedChargeRemaining = 50; BatteryStatus = 1 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CurrentPerformanceMode { return 2 }
    }

    It 'aggiorna trayState da telemetria batteria' {
        Mock Get-CimInstance { [PSCustomObject]@{ EstimatedChargeRemaining = 67; BatteryStatus = 6 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CurrentPerformanceMode { return 1 }

        Update-PerformanceMode

        $script:trayState.CurrentMode | Should -Be 'Silenzioso'
        $script:trayState.ChargePercent | Should -Be 67
        $script:trayState.IsOnAC | Should -BeTrue
    }

    It 'in AC e soglia raggiunta forza modalità 3 (PL1 atteso 25W)' {
        Mock Get-CimInstance { [PSCustomObject]@{ EstimatedChargeRemaining = 80; BatteryStatus = 2 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CurrentPerformanceMode { return 2 }

        Update-PerformanceMode

        Should -Invoke Invoke-ModeSelection -Times 1 -ParameterFilter { $Mode -eq 3 }
        (Get-ExpectedModePl1W -Mode 3) | Should -Be 25
    }

    It 'su batteria passa a modalità 2 (PL1 atteso 25W)' {
        Mock Get-CimInstance { [PSCustomObject]@{ EstimatedChargeRemaining = 60; BatteryStatus = 1 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CurrentPerformanceMode { return 3 }

        Update-PerformanceMode

        Should -Invoke Invoke-ModeSelection -Times 1 -ParameterFilter { $Mode -eq 2 }
        (Get-ExpectedModePl1W -Mode 2) | Should -Be 25
    }

    It 'in pausa non applica cambi automatici' {
        $script:trayState.IsPaused = $true
        Mock Get-CimInstance { [PSCustomObject]@{ EstimatedChargeRemaining = 80; BatteryStatus = 6 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CurrentPerformanceMode { return 2 }

        Update-PerformanceMode

        Should -Invoke Invoke-ModeSelection -Times 0
    }

    It 'protezione disabilitata con limite 100 passa a modalità 3 solo a carica piena' {
        Mock Get-BatteryProtectionLimit { return 100 }
        Mock Get-CimInstance { [PSCustomObject]@{ EstimatedChargeRemaining = 100; BatteryStatus = 6 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CurrentPerformanceMode { return 2 }

        Update-PerformanceMode

        Should -Invoke Invoke-ModeSelection -Times 1 -ParameterFilter { $Mode -eq 3 }
    }

    It 'in zona isteresi non cambia modalità' {
        Mock Get-CimInstance { [PSCustomObject]@{ EstimatedChargeRemaining = 78; BatteryStatus = 6 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CurrentPerformanceMode { return 2 }

        Update-PerformanceMode

        Should -Invoke Invoke-ModeSelection -Times 0
    }

    It 'propaga errore da Invoke-ModeSelection (mismatch PL1)' {
        Mock Get-CimInstance { [PSCustomObject]@{ EstimatedChargeRemaining = 80; BatteryStatus = 6 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CurrentPerformanceMode { return 2 }
        Mock Invoke-ModeSelection { throw 'Verifica PL1 fallita: modalita=3, atteso=25W, rilevato=18W.' }

        { Update-PerformanceMode } | Should -Throw 'Verifica PL1 fallita*'
    }
}
