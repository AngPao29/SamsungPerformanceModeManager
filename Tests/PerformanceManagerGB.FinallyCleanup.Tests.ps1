Describe 'PerformanceManagerGB - Cleanup notifiche nel finally' {
    BeforeAll {
        function script:Invoke-NotificationFinallyCleanup {
            try {
                if ($script:_notifPS) {
                    try { $script:_notifPS.Stop() } catch { }
                    try { $script:_notifPS.Dispose() } catch { }
                    $script:_notifPS = $null
                }
                if ($script:_notifRS) {
                    try { $script:_notifRS.Close() } catch { }
                    try { $script:_notifRS.Dispose() } catch { }
                    $script:_notifRS = $null
                }
            } catch { }
        }

        function script:New-NotifResourceProbe {
            param([switch]$ThrowOnCalls)
            $probe = [PSCustomObject]@{
                StopCalls    = 0
                CloseCalls   = 0
                DisposeCalls = 0
            }
            $probe | Add-Member -MemberType ScriptMethod -Name Stop -Value {
                $this.StopCalls++
                if ($ThrowOnCalls) { throw 'stop-fail' }
            } -Force
            $probe | Add-Member -MemberType ScriptMethod -Name Close -Value {
                $this.CloseCalls++
                if ($ThrowOnCalls) { throw 'close-fail' }
            } -Force
            $probe | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
                $this.DisposeCalls++
                if ($ThrowOnCalls) { throw 'dispose-fail' }
            } -Force
            return $probe
        }
    }

    BeforeEach {
        $script:_notifPS = $null
        $script:_notifRS = $null
    }

    It 'rilascia risorse notifica e azzera i riferimenti quando presenti' {
        $psProbe = New-NotifResourceProbe
        $rsProbe = New-NotifResourceProbe
        $script:_notifPS = $psProbe
        $script:_notifRS = $rsProbe

        Invoke-NotificationFinallyCleanup

        $psProbe.StopCalls | Should -Be 1
        $psProbe.DisposeCalls | Should -Be 1
        $rsProbe.CloseCalls | Should -Be 1
        $rsProbe.DisposeCalls | Should -Be 1
        $script:_notifPS | Should -BeNullOrEmpty
        $script:_notifRS | Should -BeNullOrEmpty
    }

    It 'gestisce eccezioni interne e completa comunque l azzeramento riferimenti' {
        $script:_notifPS = New-NotifResourceProbe -ThrowOnCalls
        $script:_notifRS = New-NotifResourceProbe -ThrowOnCalls

        { Invoke-NotificationFinallyCleanup } | Should -Not -Throw
        $script:_notifPS | Should -BeNullOrEmpty
        $script:_notifRS | Should -BeNullOrEmpty
    }
}
