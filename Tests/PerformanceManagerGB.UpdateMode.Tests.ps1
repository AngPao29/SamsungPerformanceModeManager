# =============================================================================
# Pester v5 - Test per PerformanceManagerGB.ps1
# Funzione coperta: Update-PerformanceMode
#
# Scenari coperti (14 totali):
#   1.  Batteria assente -> return immediato, nessun Set-PerformanceMode
#   2.  trayState.CurrentMode aggiornato correttamente
#   3.  trayState.ChargePercent aggiornato correttamente
#   4.  trayState.IsOnAC = $true quando batteryStatus in AC_STATUSES
#   5.  trayState.IsOnAC = $false quando batteryStatus = 1
#   6.  IsPaused = $true -> nessun Set-PerformanceMode
#   7.  AC=true, carica=79%, limite=80%, tolleranza=1% -> Mode 3
#   8.  AC=true, carica=80%, limite=80% -> Mode 3
#   9.  AC=true, gia Mode=3 -> nessun Set-PerformanceMode
#  10.  AC=true, carica=78%, limite=80% -> NON imposta Mode 3
#  11.  AC=false, Mode corrente=3 -> Mode 2
#  12.  AC=true, carica=76%, limite=80%, isteresi=3% -> Mode 2
#  13.  AC=false, gia Mode=2 -> nessun Set-PerformanceMode
#  14.  AC=true, carica=78%, zona isteresi -> nessun Set-PerformanceMode
#
# Esecuzione:
#   Invoke-Pester -Path 'C:\Scripts\Tests\PerformanceManagerGB.UpdateMode.Tests.ps1' -Output Detailed
# =============================================================================

Describe 'PerformanceManagerGB - Update-PerformanceMode' {

    BeforeAll {

        $script:MODE_OPTIMIZED        = 2
        $script:MODE_HIGH_PERFORMANCE = 3
        $script:hysteresisMargin      = 3
        $script:chargeTolerance       = 1
        $script:AC_STATUSES           = @(2, 3, 6, 7, 8, 9)

        $script:MODE_NAMES = @{
            0 = 'Nessun rumore'
            1 = 'Silenzioso'
            2 = 'Ottimizzata'
            3 = 'Prestazioni Elevate'
        }

        $script:BATTERY_STATUS_NAMES = @{
            1='Batteria (scarica)'; 2='AC (connesso)'; 3='Carica completa'
            4='Bassa'; 5='Critica'; 6='In carica'; 7='In carica (alta)'
            8='In carica (bassa)'; 9='In carica (critica)'; 10='Non definito'; 11='Parzialmente carica'
        }

        $script:trayState = [hashtable]::Synchronized(@{
            CurrentMode       = 'Ottimizzata'
            ChargePercent     = 0
            IsOnAC            = $false
            IsPaused          = $false
            SoundEnabled      = $true
            NotifPopupEnabled = $true
            RequestedMode     = $null
            RequestExit       = $false
            LogFile           = "$env:TEMP\test_gestore.log"
        })

        function script:Write-Log              { param([string]$Message) }
        function script:Get-BatteryProtectionLimit { return 80 }
        function script:Get-CurrentPerformanceMode { return 2 }
        function script:Set-PerformanceMode    { param([int]$Mode) }
        function script:Show-ModeNotification  {
            param([string]$ModeName,[string]$IconGlyph,[string]$AccentColor,[string]$Subtitle='')
        }
        function script:Play-NotificationSound {
            if (-not $script:trayState.SoundEnabled) { return }
        }

        function script:Update-PerformanceMode {
            param([string]$Trigger = 'polling')

            $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop |
                       Select-Object -First 1

            if ($null -eq $battery) {
                Write-Log "WARN  [$Trigger] Nessuna batteria rilevata. Salto ciclo."
                return
            }

            $chargePercent = $battery.EstimatedChargeRemaining
            $batteryStatus = $battery.BatteryStatus
            $statusName    = $script:BATTERY_STATUS_NAMES[[int]$batteryStatus]
            if (-not $statusName) { $statusName = "Sconosciuto($batteryStatus)" }

            $chargeLimit = Get-BatteryProtectionLimit

            $currentMode     = Get-CurrentPerformanceMode
            $currentModeName = $script:MODE_NAMES[[int]$currentMode]
            if (-not $currentModeName) { $currentModeName = "Sconosciuta($currentMode)" }

            $isOnAC = $batteryStatus -in $script:AC_STATUSES

            $script:trayState.CurrentMode   = $currentModeName
            $script:trayState.ChargePercent = $chargePercent
            $script:trayState.IsOnAC        = $isOnAC

            if ($script:trayState.IsPaused) {
                Write-Log "DEBUG [$Trigger] Automatismo sospeso, salto valutazione."
                return
            }

            if ($isOnAC -and ($chargePercent -ge ($chargeLimit - $script:chargeTolerance))) {
                if ($currentMode -ne $script:MODE_HIGH_PERFORMANCE) {
                    Set-PerformanceMode -Mode $script:MODE_HIGH_PERFORMANCE
                    Show-ModeNotification -ModeName "Prestazioni Elevate" -IconGlyph ([char]0xE945) -AccentColor "#FFAA2C" -Subtitle "$statusName · $chargePercent%"
                    Play-NotificationSound
                    Write-Log "INFO  [$Trigger] -> PRESTAZIONI ELEVATE"
                }
                else {
                    Write-Log "DEBUG [$Trigger] Nessun cambio: gia' in Prestazioni Elevate"
                }
            }
            elseif ((-not $isOnAC) -or ($chargePercent -lt ($chargeLimit - $script:hysteresisMargin))) {
                if ($currentMode -ne $script:MODE_OPTIMIZED) {
                    Set-PerformanceMode -Mode $script:MODE_OPTIMIZED
                    Show-ModeNotification -ModeName "Ottimizzata" -IconGlyph ([char]0xE946) -AccentColor "#60CDFF" -Subtitle "$statusName · $chargePercent%"
                    Play-NotificationSound
                    Write-Log "INFO  [$Trigger] -> OTTIMIZZATA"
                }
                else {
                    Write-Log "DEBUG [$Trigger] Nessun cambio: gia' in Ottimizzata"
                }
            }
            else {
                Write-Log "DEBUG [$Trigger] Zona isteresi"
            }
        }
    }

    BeforeEach {
        $script:trayState.IsPaused      = $false
        $script:trayState.IsOnAC        = $false
        $script:trayState.CurrentMode   = 'Ottimizzata'
        $script:trayState.ChargePercent = 0

        Mock Set-PerformanceMode    {}
        Mock Show-ModeNotification  {}
        Mock Play-NotificationSound {}
        Mock Write-Log              {}
        Mock Get-BatteryProtectionLimit { return 80 }
    }

    # =========================================================================
    Context 'Batteria non rilevata' {

        It 'Scenario 1: Get-CimInstance=$null -> return immediato, nessun Set-PerformanceMode' {
            Mock Get-CimInstance { return $null } -ParameterFilter { $ClassName -eq 'Win32_Battery' }

            Update-PerformanceMode

            Should -Invoke Set-PerformanceMode -Times 0 -Exactly
        }
    }

    # =========================================================================
    Context 'Aggiornamento trayState' {

        It 'Scenario 2: trayState.CurrentMode viene impostato al nome della modalita corrente (2 Ottimizzata)' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=50; BatteryStatus=1 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 2 }

            Update-PerformanceMode

            $script:trayState.CurrentMode | Should -Be 'Ottimizzata'
        }

        It 'Scenario 2b: trayState.CurrentMode mappa 0 a Nessun rumore' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=50; BatteryStatus=1 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 0 }

            Update-PerformanceMode

            $script:trayState.CurrentMode | Should -Be 'Nessun rumore'
        }

        It 'Scenario 2c: trayState.CurrentMode mappa 1 a Silenzioso' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=50; BatteryStatus=1 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 1 }

            Update-PerformanceMode

            $script:trayState.CurrentMode | Should -Be 'Silenzioso'
        }

        It 'Scenario 3: trayState.ChargePercent viene impostato alla percentuale rilevata' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=65; BatteryStatus=1 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 2 }

            Update-PerformanceMode

            $script:trayState.ChargePercent | Should -Be 65
        }

        It 'Scenario 4: trayState.IsOnAC = $true quando batteryStatus=6 (membro AC_STATUSES)' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=50; BatteryStatus=6 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 2 }

            Update-PerformanceMode

            $script:trayState.IsOnAC | Should -BeTrue
        }

        It 'Scenario 5: trayState.IsOnAC = $false quando batteryStatus=1 (non in AC_STATUSES)' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=50; BatteryStatus=1 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 2 }

            Update-PerformanceMode

            $script:trayState.IsOnAC | Should -BeFalse
        }
    }

    # =========================================================================
    Context 'Automatismo sospeso (IsPaused = $true)' {

        It 'Scenario 6: IsPaused=$true -> nessun Set-PerformanceMode anche se condizioni lo richiederebbero' {
            $script:trayState.IsPaused = $true
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=80; BatteryStatus=6 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 2 }

            Update-PerformanceMode

            Should -Invoke Set-PerformanceMode -Times 0 -Exactly
        }
    }

    # =========================================================================
    Context 'Logica - cambio a Prestazioni Elevate (Mode=3)' {

        It 'Scenario 7: AC=true, carica=79%, limite=80%, tolleranza=1% -> 79>=(80-1)=79 -> Mode=3' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=79; BatteryStatus=6 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 2 }

            Update-PerformanceMode

            Should -Invoke Set-PerformanceMode -Times 1 -Exactly -ParameterFilter { $Mode -eq 3 }
        }

        It 'Scenario 8: AC=true, carica=80%, limite=80% -> 80>=(80-1) -> Mode=3' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=80; BatteryStatus=2 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 2 }

            Update-PerformanceMode

            Should -Invoke Set-PerformanceMode -Times 1 -Exactly -ParameterFilter { $Mode -eq 3 }
        }

        It 'Scenario 9: AC=true, gia in Mode=3 -> Set-PerformanceMode NON viene chiamato' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=80; BatteryStatus=6 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 3 }

            Update-PerformanceMode

            Should -Invoke Set-PerformanceMode -Times 0 -Exactly
        }

        It 'Scenario 10: AC=true, carica=78%, limite=80% -> 78 lt 79 -> ramo Prestazioni Elevate non scatta' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=78; BatteryStatus=6 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 2 }

            Update-PerformanceMode

            Should -Invoke Set-PerformanceMode -Times 0 -ParameterFilter { $Mode -eq 3 }
        }
    }

    # =========================================================================
    Context 'Logica - cambio a Ottimizzata (Mode=2)' {

        It 'Scenario 11: AC=false (batteryStatus=1), Mode corrente=3 -> Set-PerformanceMode Mode=2' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=50; BatteryStatus=1 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 3 }

            Update-PerformanceMode

            Should -Invoke Set-PerformanceMode -Times 1 -Exactly -ParameterFilter { $Mode -eq 2 }
        }

        It 'Scenario 12: AC=true, carica=76%, limite=80%, isteresi=3% -> 76 lt (80-3)=77 -> Mode=2' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=76; BatteryStatus=6 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 3 }

            Update-PerformanceMode

            Should -Invoke Set-PerformanceMode -Times 1 -Exactly -ParameterFilter { $Mode -eq 2 }
        }

        It 'Scenario 13: AC=false, gia in Mode=2 -> Set-PerformanceMode NON viene chiamato' {
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=50; BatteryStatus=1 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 2 }

            Update-PerformanceMode

            Should -Invoke Set-PerformanceMode -Times 0 -Exactly
        }
    }

    # =========================================================================
    Context 'Zona isteresi - nessun cambio' {

        It 'Scenario 14: AC=true, carica=78%, limite=80% -> zona isteresi [77-79] -> nessun Set-PerformanceMode' {
            # 78 >= (80-1)=79 ? NO  (non entra in Prestazioni Elevate)
            # 78 < (80-3)=77 ? NO   (non entra in Ottimizzata)
            # -> zona isteresi -> nessun cambio
            Mock Get-CimInstance {
                return [PSCustomObject]@{ EstimatedChargeRemaining=78; BatteryStatus=6 }
            } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
            Mock Get-CurrentPerformanceMode { return 2 }

            Update-PerformanceMode

            Should -Invoke Set-PerformanceMode -Times 0 -Exactly
        }
    }
}