Describe 'PerformanceManagerGB - Percorso forzato e ripristino automatico' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers\PerformanceManagerGB.ModeEngine.TestHelpers.ps1')
        Initialize-ModeEngineTestContext

        function script:Invoke-ResumeAutoClick {
            param([hashtable]$State)
            $State.ResumeAutomaticRequested = $true
            try { $State.WakeSignal.Set() } catch { }
        }

        function script:Invoke-LoopCommand {
            param([hashtable]$State)

            $trigger = 'polling'
            $resumeRequested = $false
            if ($State.ResumeAutomaticRequested) {
                $State.ResumeAutomaticRequested = $false
                $resumeRequested = $true
                $State.RequestedMode = $null
                $State.RequestedModeSource = $null
                $State.ControlMode = 'Auto'
                $State.ManualOverrideMode = $null
                $State.ManualOverrideSource = $null
                $State.ManualOverrideTimestamp = $null
                $trigger = 'resume'
            }

            if (-not $resumeRequested -and $null -ne $State.RequestedMode) {
                $requestedMode = $State.RequestedMode
                $requestedSource = $State.RequestedModeSource
                $State.RequestedMode = $null
                $State.RequestedModeSource = $null
                [void](Invoke-ForcedModeRequest -RequestedMode $requestedMode -RequestedModeSource $requestedSource)
            }

            Update-PerformanceMode -Trigger $trigger
            return $trigger
        }
    }

    BeforeEach {
        $script:trayState.ControlMode = 'Auto'
        $script:trayState.ManualOverrideMode = $null
        $script:trayState.ManualOverrideSource = $null
        $script:trayState.ManualOverrideTimestamp = $null
        $script:trayState.RequestedMode = $null
        $script:trayState.RequestedModeSource = $null
        $script:trayState.ResumeAutomaticRequested = $false
        $script:trayState.WakeSignal = [PSCustomObject]@{ SetCalls = 0 }
        $script:trayState.WakeSignal | Add-Member -MemberType ScriptMethod -Name Set -Value { $this.SetCalls++ } -Force

        Mock Update-PerformanceMode {}
        Mock Invoke-ModeSelection {}
        Mock Write-Log {}
    }

    It 'forzatura riuscita aggiorna override manuale' {
        Mock Invoke-ModeSelection {}

        $ok = Invoke-ForcedModeRequest -RequestedMode 1 -RequestedModeSource 'Tray'

        $ok | Should -BeTrue
        $script:trayState.ControlMode | Should -Be 'Manual'
        $script:trayState.ManualOverrideMode | Should -Be 1
        (Get-ExpectedModePl1W -Mode 1) | Should -Be 18
    }

    It 'forzatura fallita non aggiorna override manuale' {
        Mock Invoke-ModeSelection { throw 'Verifica PL1 fallita: modalita=1, atteso=18W, rilevato=8W.' }

        $ok = Invoke-ForcedModeRequest -RequestedMode 1 -RequestedModeSource 'Tray'

        $ok | Should -BeFalse
        $script:trayState.ControlMode | Should -Be 'Auto'
        $script:trayState.ManualOverrideMode | Should -Be $null
    }

    It 'click riprendi automatico imposta flag e sveglia wake signal' {
        Invoke-ResumeAutoClick -State $script:trayState

        $script:trayState.ResumeAutomaticRequested | Should -BeTrue
        $script:trayState.WakeSignal.SetCalls | Should -Be 1
    }

    It 'loop con resume richiesto azzera override e usa trigger resume' {
        $script:trayState.ControlMode = 'Manual'
        $script:trayState.ManualOverrideMode = 3
        $script:trayState.ManualOverrideSource = 'Tray'
        $script:trayState.ManualOverrideTimestamp = Get-Date
        $script:trayState.RequestedMode = 0
        $script:trayState.RequestedModeSource = 'Tray'
        $script:trayState.ResumeAutomaticRequested = $true

        $trigger = Invoke-LoopCommand -State $script:trayState

        $trigger | Should -Be 'resume'
        $script:trayState.ControlMode | Should -Be 'Auto'
        $script:trayState.ManualOverrideMode | Should -Be $null
        $script:trayState.RequestedMode | Should -Be $null
        Should -Invoke Update-PerformanceMode -Times 1 -ParameterFilter { $Trigger -eq 'resume' }
    }
}
