# =============================================================================
# Pester v5 - Test per PerformanceManagerGB.ps1
# Funzioni coperte:
#   - Get-CurrentPerformanceMode
#   - Set-PerformanceMode
#
# Esecuzione:
#   Invoke-Pester -Path 'C:\Scripts\Tests\' -Output Detailed
#
# NON richiede privilegi di amministratore.
# NON accede al registro reale: usa Mock di Pester.
# =============================================================================

Describe 'PerformanceManagerGB - PerformanceMode' {

    BeforeAll {
        $script:regPerformance        = 'HKLM:\SOFTWARE\Samsung\SamsungSettings\ModulePerformance'
        $script:MODE_OPTIMIZED        = 2
        $script:MODE_HIGH_PERFORMANCE = 3

        function script:Get-CurrentPerformanceMode {
            try {
                return [int](Get-ItemProperty -Path $script:regPerformance -ErrorAction Stop).Value
            }
            catch {
                return $null
            }
        }

        function script:Set-PerformanceMode {
            param([int]$Mode)
            Set-ItemProperty -Path $script:regPerformance -Name 'Value' -Value $Mode -ErrorAction Stop
        }
    }

    # ===========================================================================
    Context 'Get-CurrentPerformanceMode' {

        It 'restituisce 0 quando Value=0 nel registro (Nessun rumore)' {
            Mock Get-ItemProperty { return [PSCustomObject]@{ Value = 0 } }

            $result = Get-CurrentPerformanceMode

            $result | Should -Be 0
        }

        It 'restituisce 1 quando Value=1 nel registro (Silenzioso)' {
            Mock Get-ItemProperty { return [PSCustomObject]@{ Value = 1 } }

            $result = Get-CurrentPerformanceMode

            $result | Should -Be 1
        }

        It 'restituisce 2 quando Value=2 nel registro' {
            Mock Get-ItemProperty { return [PSCustomObject]@{ Value = 2 } }

            $result = Get-CurrentPerformanceMode

            $result | Should -Be 2
        }

        It 'restituisce 3 quando Value=3 nel registro' {
            Mock Get-ItemProperty { return [PSCustomObject]@{ Value = 3 } }

            $result = Get-CurrentPerformanceMode

            $result | Should -Be 3
        }

        It 'restituisce $null se il registro non esiste (eccezione)' {
            Mock Get-ItemProperty { throw 'Chiave di registro non trovata.' }

            $result = Get-CurrentPerformanceMode

            $result | Should -BeNullOrEmpty
        }

        It 'il valore restituito e di tipo [int] quando la chiave esiste' {
            Mock Get-ItemProperty { return [PSCustomObject]@{ Value = 2 } }

            $result = Get-CurrentPerformanceMode

            $result | Should -BeOfType [int]
        }
    }

    # ===========================================================================
    Context 'Set-PerformanceMode' {

        It 'chiama Set-ItemProperty con Path corretto, Name=Value e Value=0 (Nessun rumore)' {
            Mock Set-ItemProperty {}

            Set-PerformanceMode -Mode 0

            Should -Invoke Set-ItemProperty -Exactly 1 -ParameterFilter {
                $Path  -eq $script:regPerformance -and
                $Name  -eq 'Value'                 -and
                $Value -eq 0
            }
        }

        It 'chiama Set-ItemProperty con Path corretto, Name=Value e Value=1 (Silenzioso)' {
            Mock Set-ItemProperty {}

            Set-PerformanceMode -Mode 1

            Should -Invoke Set-ItemProperty -Exactly 1 -ParameterFilter {
                $Path  -eq $script:regPerformance -and
                $Name  -eq 'Value'                 -and
                $Value -eq 1
            }
        }

        It 'chiama Set-ItemProperty con Path corretto, Name=Value e Value=2' {
            Mock Set-ItemProperty {}

            Set-PerformanceMode -Mode 2

            Should -Invoke Set-ItemProperty -Exactly 1 -ParameterFilter {
                $Path  -eq $script:regPerformance -and
                $Name  -eq 'Value'                 -and
                $Value -eq 2
            }
        }

        It 'chiama Set-ItemProperty con Path corretto, Name=Value e Value=3' {
            Mock Set-ItemProperty {}

            Set-PerformanceMode -Mode 3

            Should -Invoke Set-ItemProperty -Exactly 1 -ParameterFilter {
                $Path  -eq $script:regPerformance -and
                $Name  -eq 'Value'                 -and
                $Value -eq 3
            }
        }

        It 'propaga le eccezioni lanciate da Set-ItemProperty (non le silenzia)' {
            Mock Set-ItemProperty { throw 'Accesso al registro negato.' }

            { Set-PerformanceMode -Mode 2 } | Should -Throw 'Accesso al registro negato.'
        }

        It 'chiama Set-ItemProperty esattamente 1 volta per singola invocazione' {
            Mock Set-ItemProperty {}

            Set-PerformanceMode -Mode 2

            Should -Invoke Set-ItemProperty -Exactly 1
        }
    }
}