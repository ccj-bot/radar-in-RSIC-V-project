param(
    [string]$VivadoRoot = "D:\Xilinx\Vivado\2024.2",
    [ValidateSet("bd", "synth", "impl")]
    [string]$BuildStep = "impl",
    [ValidateRange(1, 2)]
    [int]$Jobs = 1,
    [ValidateRange(1, 32832)]
    [int]$QScale = 26564
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$vivado = Join-Path $VivadoRoot "bin\vivado.bat"
if (-not (Test-Path -LiteralPath $vivado)) { throw "Vivado not found: $vivado" }
$logDir = Join-Path $projectRoot "output\logs"
$null = New-Item -ItemType Directory -Path $logDir -Force

Push-Location $projectRoot
try {
    & $vivado -mode batch -nojournal -notrace `
        -log (Join-Path $logDir "01_package_ip.log") `
        -source ".\script\vivado\package_sar_imaging_ip.tcl" `
        -tclargs -part xc7z020clg484-1
    if ($LASTEXITCODE -ne 0) { throw "v1.1 IP packaging failed: $LASTEXITCODE" }

    # Check the source actually imported into the IP, not just the loose RTL.
    $sourceRtl = Join-Path $projectRoot "rtl\pl_iw\sar_pl_iw_generator.v"
    $packagedRtl = Join-Path $projectRoot "output\ip_repo\sar_imaging_top\src\sar_pl_iw_generator.v"
    if ((Get-FileHash -LiteralPath $sourceRtl).Hash -ne (Get-FileHash -LiteralPath $packagedRtl).Hash) {
        throw "Packaged PL generator differs from the source"
    }
    $packagedTop = Join-Path $projectRoot "output\ip_repo\sar_imaging_top\src\sar_imaging_top.v"
    if (-not (Select-String -LiteralPath $packagedTop -SimpleMatch "u_pl_iw_generator" -Quiet)) {
        throw "Packaged SAR top has no PL descriptor-generator instance"
    }

    & $vivado -mode batch -nojournal -notrace `
        -log (Join-Path $logDir "02_build_hw.log") `
        -source ".\script\vivado\build_sar_system.tcl" `
        -tclargs -part xc7z020clg484-1 -project_name v11 `
        -fclk_mhz 100 -common_sram_clock 1 -enable_hdmi_preview 1 `
        -range_ifft_mode 0 -pl_iw_q_scale $QScale -build_step $BuildStep `
        -ps_init_tcl ".\script\vivado\ps7_smart_zynq_sl_ref.tcl" -jobs $Jobs
    if ($LASTEXITCODE -ne 0) { throw "v1.1 $BuildStep build failed: $LASTEXITCODE" }

    if ($BuildStep -eq "impl") {
        $exportDir = Join-Path $projectRoot "output\export\v11"
        $manifest = [ordered]@{
            version = "v1.1"
            part = "xc7z020clg484-1"
            fclk_mhz = 100
            nr = 1024
            na = 512
            descriptor_format = 1
            q_scale_per_vq4_q14 = $QScale
            bit_sha256 = (Get-FileHash -LiteralPath (Join-Path $exportDir "system.bit")).Hash
            xsa_sha256 = (Get-FileHash -LiteralPath (Join-Path $exportDir "system.xsa")).Hash
            generator_sha256 = (Get-FileHash -LiteralPath $sourceRtl).Hash
            top_sha256 = (Get-FileHash -LiteralPath (Join-Path $projectRoot "rtl\system\sar_imaging_top.v")).Hash
        }
        $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $exportDir "manifest.json") -Encoding UTF8
        Write-Output "v1.1 bit/XSA and reports: $exportDir"
    }
} finally {
    Pop-Location
}
