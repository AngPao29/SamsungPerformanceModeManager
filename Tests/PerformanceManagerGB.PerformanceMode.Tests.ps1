Describe 'PerformanceManagerGB - Apply mode con verifica PL1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers\PerformanceManagerGB.ModeEngine.TestHelpers.ps1')
        Initialize-ModeEngineTestContext
    }

    BeforeEach {
        Mock Set-PerformanceMode {}
        Mock Show-ModeNotification {}
        Mock Play-NotificationSound {}
        Mock Write-Log {}
        Mock Wait-Pl1VerificationDelay {}
        Mock Get-CurrentPerformanceMode { return 2 }
        Mock Get-DynamicPl1Telemetry {
            [PSCustomObject]@{ Available = $false; Pl1W = $null; Source = 'NotAvailable'; Error = $null }
        }
    }

    Context 'Mapping modalità -> PL1 atteso' {
        It 'usa 8/18/25/25 per modalità 0/1/2/3' {
            (Get-ExpectedModePl1W -Mode 0) | Should -Be 8
            (Get-ExpectedModePl1W -Mode 1) | Should -Be 18
            (Get-ExpectedModePl1W -Mode 2) | Should -Be 25
            (Get-ExpectedModePl1W -Mode 3) | Should -Be 25
        }
    }

    Context 'Invoke-ModeSelection' {
        It 'scrive registro e valida readback modalità' {
            Mock Get-CurrentPerformanceMode { return 3 }

            Invoke-ModeSelection -Mode 3 -Subtitle 'test'

            Should -Invoke Set-PerformanceMode -Times 1 -ParameterFilter { $Mode -eq 3 }
            Should -Invoke Get-CurrentPerformanceMode -Times 1
        }

        It 'fallisce se readback modalità non corrisponde' {
            Mock Get-CurrentPerformanceMode { return 2 }

            { Invoke-ModeSelection -Mode 3 } | Should -Throw 'Verifica applicazione fallita*'
            Should -Invoke Show-ModeNotification -Times 0
        }

        It 'con telemetria non disponibile non blocca il successo' {
            Mock Get-CurrentPerformanceMode { return 1 }
            Mock Get-DynamicPl1Telemetry {
                [PSCustomObject]@{ Available = $false; Pl1W = $null; Source = 'Mock'; Error = $null }
            }

            { Invoke-ModeSelection -Mode 1 } | Should -Not -Throw
            Should -Invoke Show-ModeNotification -Times 1
        }

        It 'con telemetria non verificabile non blocca il successo' {
            Mock Get-CurrentPerformanceMode { return 1 }
            Mock Get-DynamicPl1Telemetry {
                [PSCustomObject]@{ Available = $true; Verifiable = $false; Pl1W = 18; Source = 'Mock'; Error = 'NotVerifiable' }
            }

            { Invoke-ModeSelection -Mode 1 } | Should -Not -Throw
            Should -Invoke Show-ModeNotification -Times 1
            Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -like 'WARN  Telemetria PL1 non verificabile runtime*' }
        }

        It 'con telemetria disponibile valida PL1 atteso (8/18/25/25)' {
            Mock Get-CurrentPerformanceMode { return 0 }
            Mock Get-DynamicPl1Telemetry {
                [PSCustomObject]@{ Available = $true; Pl1W = 8; Source = 'Mock'; Error = $null }
            }

            { Invoke-ModeSelection -Mode 0 } | Should -Not -Throw
            Should -Invoke Get-DynamicPl1Telemetry -Times 1
        }

        It 'retry telemetria e poi successo se PL1 converge' {
            Mock Get-CurrentPerformanceMode { return 2 }
            $script:callCount = 0
            Mock Get-DynamicPl1Telemetry {
                $script:callCount++
                if ($script:callCount -lt 3) {
                    return [PSCustomObject]@{ Available = $true; Pl1W = 18; Source = 'Mock'; Error = $null }
                }
                return [PSCustomObject]@{ Available = $true; Pl1W = 25; Source = 'Mock'; Error = $null }
            }

            { Invoke-ModeSelection -Mode 2 } | Should -Not -Throw
            Should -Invoke Wait-Pl1VerificationDelay -Times 2
            Should -Invoke Get-DynamicPl1Telemetry -Times 3
        }

        It 'su mismatch PL1 genera errore esplicito e non notifica successo' {
            Mock Get-CurrentPerformanceMode { return 3 }
            Mock Get-DynamicPl1Telemetry {
                [PSCustomObject]@{ Available = $true; Pl1W = 18; Source = 'Mock'; Error = 'Mismatch' }
            }

            { Invoke-ModeSelection -Mode 3 } | Should -Throw 'Verifica PL1 fallita*'
            Should -Invoke Show-ModeNotification -Times 0
            Should -Invoke Play-NotificationSound -Times 0
        }
    }
}
