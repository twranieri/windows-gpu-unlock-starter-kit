# SPDX-License-Identifier: GPL-2.0-only
# Synthetic NVIDIA rows and EFI log records only.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../desktop/Diagnostics.ps1')

function Assert-Report([string]$Report,[string[]]$Required,[string[]]$Forbidden) {
    foreach ($value in $Required) {
        if (!$Report.Contains($value)) { throw "Missing expected diagnostic field: $value" }
    }
    foreach ($value in $Forbidden) {
        if ($Report.Contains($value)) { throw 'Diagnostic report leaked a private fixture field.' }
    }
}

function Get-Command { [pscustomobject]@{Source='synthetic.exe'} }
function Read-RtxDiagnosticSmi([string]$Executable,[string[]]$Fields,[string]$Address) {
    switch ($Fields.Count) {
        10 { return }  # An older driver rejects the combined query.
        7 { 'NVIDIA GeForce RTX 4090, 00000001:2B:00.0, 0x268410DE, 0x51041462, 95.02.18.80.74, 617.70, 24576'; return }
        1 {
            if ($Address -cne '00000001:2B:00.0') { throw 'Optional telemetry must use the selected GPU BDF.' }
            if ($Fields[0] -eq 'memory.free') { '20480' }
            if ($Fields[0] -eq 'ecc.mode.current') { '[N/A]' }
        }
    }
}

$gpu = (Get-RtxDiagnosticGpu) -join "`n"
Assert-Report $gpu @('PCI 0001:2b:00.0','device 10de:2684','subsystem 51041462','95.02.18.80.74',
    'VRAM total: 24576 MiB','reserved: unavailable','free: 20480 MiB','ECC: unavailable') @('synthetic.exe')

$nonce = 'b5b7342532034317a98a53dc5721558e'
$privateId = '7f1541f6-7275-42c0-af8b-424ca2f4d4bc'
$fixture = @(
    "CHAIN-BOOT: Boot0010 hd(part=1,sig=$privateId) C:\Users\private",
    "[  12ms] INFO : loader: KIT-PROBE: $nonce matched 1",
    '[  17ms] INFO : loader::sample: SAMPLE: GPU 10de:2684 @ 0000:10:00.0',
    '[  18ms] INFO : loader::sample: SAMPLE FB_SIZE_MIB 0x1183a4 = 0x00006000 [ok]',
    '[  19ms] INFO : loader::sample: SAMPLE MMU_LOCK_HI 0x1fa830 = 0x02effff0 [ok]',
    'TX: ===== target 1/1: 10de:2684 @ 0000:10:00.0 =====',
    '[ 240ms] INFO : loader::tx_fwsec: layout inputs: fb_mib=0xbadf5040 vga=0xbadf1301 mmu_plm=0x0045cb8f mmu_lo=0x00100000 mmu_hi=0x02effff0 image=0x5053000 boot=0x6000',
    'FINAL: KIT-STOP: transaction failed: EIO. Attempting emergency reset.',
    'CHAIN: failed: C:\Users\private'
)
$log = (Get-RtxDiagnosticLogEvidence ($fixture -join "`r`n")) -join "`n"
Assert-Report $log @('read-only identity','24576 MiB','MMU_LOCK_HI: readable','inaccessible (0xbadf5040)',
    'lock bit 1','0000:10:00.0: EIO','Windows handoff failure') `
    @($nonce,$privateId,'C:\Users\private','02effff0','00100000','5053000','Attempting emergency reset')

Write-Output 'RTX diagnostic GPU fallback and EFI redaction checks passed.'
