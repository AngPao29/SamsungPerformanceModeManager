# =============================================================================
# Pester v5 - Test statici per PerformanceManagerGB.ps1 (nuove modalità tray)
# Obiettivo: validare che i codici 0/1 e le nuove voci del tray esistano nel file
# senza avviare realmente la UI/tray e senza alterare lo stato del PC.
# =============================================================================

Describe 'PerformanceManagerGB - Tray menu nuove modalita' {

    BeforeAll {
        $script:scriptPath = Join-Path $PSScriptRoot '..\PerformanceManagerGB.ps1'
        if (-not (Test-Path $script:scriptPath)) {
            throw "File non trovato: $script:scriptPath"
        }

        $script:source = Get-Content -Path $script:scriptPath -Raw
    }

    Context 'Codici e mappe modalita' {

        It 'definisce MODE_NO_NOISE=0 e MODE_SILENT=1' {
            $script:source | Should -Match '\$MODE_NO_NOISE\s*=\s*0'
            $script:source | Should -Match '\$MODE_SILENT\s*=\s*1'
        }

        It 'MODE_NAMES include 0 Nessun rumore e 1 Silenzioso' {
            $script:source | Should -Match '\$MODE_NAMES\s*=\s*@\{[\s\S]*\$MODE_NO_NOISE\s*=\s*''Nessun rumore''[\s\S]*\$MODE_SILENT\s*=\s*''Silenzioso''[\s\S]*\}'
        }
    }

    Context 'Voci menu tray' {

        It 'contiene la voce Forza Nessun rumore' {
            $script:source | Should -Match ([regex]::Escape('Forza Nessun rumore'))
        }

        It 'contiene la voce Forza Silenzioso' {
            $script:source | Should -Match ([regex]::Escape('Forza Silenzioso'))
        }

        It 'handler Nessun rumore imposta RequestedMode=0 e sveglia WakeSignal' {
            $idx = $script:source.IndexOf('Forza Nessun rumore')
            $idx | Should -BeGreaterThan -1

            $window = $script:source.Substring($idx, [Math]::Min(600, $script:source.Length - $idx))
            $window | Should -Match 'ManualOverrideMode\s*-eq\s*0'
            $window | Should -Match 'ResumeAutomaticRequested\s*=\s*\$true'
            $window | Should -Match 'RequestedMode\s*=\s*0'
            $window | Should -Match 'WakeSignal\.Set\(\)'
        }

        It 'handler Silenzioso imposta RequestedMode=1 e sveglia WakeSignal' {
            $idx = $script:source.IndexOf('Forza Silenzioso')
            $idx | Should -BeGreaterThan -1

            $window = $script:source.Substring($idx, [Math]::Min(600, $script:source.Length - $idx))
            $window | Should -Match 'ManualOverrideMode\s*-eq\s*1'
            $window | Should -Match 'ResumeAutomaticRequested\s*=\s*\$true'
            $window | Should -Match 'RequestedMode\s*=\s*1'
            $window | Should -Match 'WakeSignal\.Set\(\)'
        }

        It 'contiene la voce Riprendi automatico' {
            $script:source | Should -Match ([regex]::Escape('Riprendi automatico'))
        }

        It 'handler Riprendi automatico imposta ResumeAutomaticRequested e sveglia WakeSignal' {
            $idx = $script:source.IndexOf('Riprendi automatico')
            $idx | Should -BeGreaterThan -1

            $window = $script:source.Substring($idx, [Math]::Min(600, $script:source.Length - $idx))
            $window | Should -Match 'ResumeAutomaticRequested\s*=\s*\$true'
            $window | Should -Match 'WakeSignal\.Set\(\)'
        }
    }

    Context 'Abilitazione voce Riprendi automatico' {

        It 'abilita il menu quando ControlMode e Manual e ManualOverrideMode non e null' {
            $script:source | Should -Match 'resumeAutoItem\.Enabled\s*=\s*\(\$controlMode\s*-eq\s*''Manual''\s*-and\s*\$null\s*-ne\s*\$State\.ManualOverrideMode\)'
        }
    }
}
