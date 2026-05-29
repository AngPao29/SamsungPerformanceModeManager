Describe 'PerformanceManagerGB - Ripristino automatico dalla tray' {
    BeforeAll {
        function script:New-TestWakeSignal {
            $signal = New-Object PSObject -Property @{ SetCalls = 0 }
            $signal | Add-Member -MemberType ScriptMethod -Name Set -Value { $this.SetCalls++ }
            return $signal
        }

        function script:Invoke-ResumeAutoClick {
            param([hashtable]$State)

            $State.ResumeAutomaticRequested = $true
            try { $State.WakeSignal.Set() } catch { }
        }

        function script:Invoke-LoopCommand {
            param([hashtable]$State)

            $trigger = 'polling'
            $justForced = $false
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

            $requestedMode = $null
            $requestedModeSource = $null
            if (-not $resumeRequested) {
                $requestedMode = $State.RequestedMode
                $requestedModeSource = $State.RequestedModeSource
            }

            if ($null -ne $requestedMode) {
                $State.RequestedMode = $null
                $State.RequestedModeSource = $null
                Set-PerformanceMode -Mode $requestedMode
                $State.ControlMode = 'Manual'
                $State.ManualOverrideMode = $requestedMode
                $State.ManualOverrideSource = $requestedModeSource
                $State.ManualOverrideTimestamp = Get-Date
                $justForced = $true
            }

            Update-PerformanceMode -Trigger $trigger

            [PSCustomObject]@{
                Trigger = $trigger
                ResumeRequested = $resumeRequested
                JustForced = $justForced
            }
        }

        function script:Set-PerformanceMode {
            param([int]$Mode)
        }

        function script:Update-PerformanceMode {
            param([string]$Trigger)
        }

        $script:trayState = @{
            ControlMode = 'Auto'
            ManualOverrideMode = $null
            ManualOverrideSource = $null
            ManualOverrideTimestamp = $null
            ResumeAutomaticRequested = $false
            RequestedMode = $null
            RequestedModeSource = $null
            WakeSignal = $null
        }
    }

    BeforeEach {
        $script:trayState.ControlMode = 'Auto'
        $script:trayState.ManualOverrideMode = $null
        $script:trayState.ManualOverrideSource = $null
        $script:trayState.ManualOverrideTimestamp = $null
        $script:trayState.ResumeAutomaticRequested = $false
        $script:trayState.RequestedMode = $null
        $script:trayState.RequestedModeSource = $null
        $script:trayState.WakeSignal = New-TestWakeSignal

        Mock Update-PerformanceMode { }
        Mock Set-PerformanceMode { }
    }

    Context 'Handler riprendi automatico' {
        It 'imposta ResumeAutomaticRequested e chiama WakeSignal.Set' {
            Invoke-ResumeAutoClick -State $script:trayState

            $script:trayState.ResumeAutomaticRequested | Should -BeTrue
            $script:trayState.WakeSignal.SetCalls | Should -Be 1
        }
    }

    Context 'Main loop ripristino automatico' {
        It 'azzera override e richieste manuali e usa trigger resume' {
            $script:trayState.ControlMode = 'Manual'
            $script:trayState.ManualOverrideMode = 2
            $script:trayState.ManualOverrideSource = 'Tray'
            $script:trayState.ManualOverrideTimestamp = (Get-Date).AddMinutes(-5)
            $script:trayState.RequestedMode = 1
            $script:trayState.RequestedModeSource = 'Tray'
            $script:trayState.ResumeAutomaticRequested = $true

            $result = Invoke-LoopCommand -State $script:trayState

            $result.Trigger | Should -Be 'resume'
            $result.ResumeRequested | Should -BeTrue
            $script:trayState.ControlMode | Should -Be 'Auto'
            $script:trayState.ManualOverrideMode | Should -Be $null
            $script:trayState.ManualOverrideSource | Should -Be $null
            $script:trayState.ManualOverrideTimestamp | Should -Be $null
            $script:trayState.RequestedMode | Should -Be $null
            $script:trayState.RequestedModeSource | Should -Be $null
            $script:trayState.ResumeAutomaticRequested | Should -BeFalse

            Should -Invoke Update-PerformanceMode -Times 1 -ParameterFilter { $Trigger -eq 'resume' }
            Should -Invoke Set-PerformanceMode -Times 0
        }

        It 'esegue la richiesta manuale quando resume non e richiesto' {
            $script:trayState.RequestedMode = 1
            $script:trayState.RequestedModeSource = 'Tray'

            $result = Invoke-LoopCommand -State $script:trayState

            $result.Trigger | Should -Be 'polling'
            $result.JustForced | Should -BeTrue
            $script:trayState.ControlMode | Should -Be 'Manual'
            $script:trayState.ManualOverrideMode | Should -Be 1
            $script:trayState.ManualOverrideSource | Should -Be 'Tray'
            $script:trayState.RequestedMode | Should -Be $null

            Should -Invoke Set-PerformanceMode -Times 1 -ParameterFilter { $Mode -eq 1 }
            Should -Invoke Update-PerformanceMode -Times 1 -ParameterFilter { $Trigger -eq 'polling' }
        }
    }
}
