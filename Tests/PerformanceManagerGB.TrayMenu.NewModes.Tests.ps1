Describe 'PerformanceManagerGB - Handler tray Forza modalità' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers\PerformanceManagerGB.ModeEngine.TestHelpers.ps1')
        Initialize-ModeEngineTestContext

        function script:Invoke-ForceModeClick {
            param(
                [hashtable]$State,
                [int]$Mode
            )

            if ($State.ControlMode -eq 'Manual' -and $State.ManualOverrideMode -eq $Mode) {
                $State.ResumeAutomaticRequested = $true
            }
            else {
                $State.RequestedMode = $Mode
                $State.RequestedModeSource = 'Tray'
            }
            try { $State.WakeSignal.Set() } catch { }
        }
    }

    BeforeEach {
        $script:trayState.ControlMode = 'Auto'
        $script:trayState.ManualOverrideMode = $null
        $script:trayState.ResumeAutomaticRequested = $false
        $script:trayState.RequestedMode = $null
        $script:trayState.RequestedModeSource = $null
        $script:trayState.WakeSignal = [PSCustomObject]@{ SetCalls = 0 }
        $script:trayState.WakeSignal | Add-Member -MemberType ScriptMethod -Name Set -Value { $this.SetCalls++ } -Force
    }

    It 'Forza Nessun rumore richiede mode 0 (PL1 8W)' {
        Invoke-ForceModeClick -State $script:trayState -Mode 0

        $script:trayState.RequestedMode | Should -Be 0
        $script:trayState.RequestedModeSource | Should -Be 'Tray'
        $script:trayState.WakeSignal.SetCalls | Should -Be 1
        (Get-ExpectedModePl1W -Mode 0) | Should -Be 8
    }

    It 'Forza Silenzioso richiede mode 1 (PL1 18W)' {
        Invoke-ForceModeClick -State $script:trayState -Mode 1

        $script:trayState.RequestedMode | Should -Be 1
        (Get-ExpectedModePl1W -Mode 1) | Should -Be 18
    }

    It 'se stessa modalità già forzata passa a ResumeAutomaticRequested' {
        $script:trayState.ControlMode = 'Manual'
        $script:trayState.ManualOverrideMode = 3

        Invoke-ForceModeClick -State $script:trayState -Mode 3

        $script:trayState.ResumeAutomaticRequested | Should -BeTrue
        $script:trayState.RequestedMode | Should -Be $null
    }
}
