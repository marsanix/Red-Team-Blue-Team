<#
.SYNOPSIS
    Streaming capture dari container nginx (tshark) ke Wireshark HOST secara
    realtime melalui Windows named pipe. Tanpa file, tanpa docker cp.

.DESCRIPTION
    Skrip ini (dijalankan di HOST, Windows/PowerShell):
      1. Membuat named pipe  \\.\pipe\uas_capture  (server).
      2. Membuka Wireshark host pada pipe tsb (client) secara OTOMATIS.
      3. Menjalankan tshark DI DALAM container nginx dan menyalurkan
         output pcap-nya ke named pipe -> Wireshark menampilkannya live.

    Catatan: `Wireshark.exe -i -` (streaming lewat stdin) TIDAK didukung di
    Windows; named pipe adalah pengganti native-nya. Jadi cukup jalankan skrip
    ini, Wireshark terbuka sendiri dan langsung menampilkan paket.

    Karena web server (nginx) adalah node tailnet, interface yang dicapture
    default = tailscale0 (tempat traffic attacker masuk). Sesuaikan dengan
    -Interface bila mode dev (mis. lo untuk uji dari localhost).

.PARAMETER Container
    Nama container web server. Default: uas-kelompok5dan9-nginx-1.

.PARAMETER Interface
    Interface di dalam container. Default: tailscale0 (jalur serangan Fase 2).
    Untuk uji cepat dari localhost (mode dev): -Interface lo.

.PARAMETER Filter
    Capture filter (BPF). Default: "tcp port 80".

.PARAMETER PipeName
    Nama named pipe di host. Default: uas_capture -> \\.\pipe\uas_capture.

.PARAMETER NoLaunch
    Jangan membuka Wireshark otomatis; biarkan pengguna membuka pipe secara
    manual (Capture -> Options -> Manage Interfaces -> "Named pipe").

.PARAMETER WiresharkArgs
    Argumen tambahan untuk Wireshark.exe (mis. "-a duration:10" agar capture
    otomatis berhenti setelah 10 detik; berguna untuk pengujian).

.EXAMPLE
    # Jalankan di HOST -> Wireshark terbuka otomatis & streaming live:
    powershell -ExecutionPolicy Bypass -File .\infrastructure\blue_team\live_capture.ps1

.EXAMPLE
    # Mode dev: capture loopback di dalam container, berhenti otomatis 10 dtk:
    powershell -ExecutionPolicy Bypass -File .\infrastructure\blue_team\live_capture.ps1 `
        -Interface lo -WiresharkArgs "-a duration:10"
#>
[CmdletBinding()]
param(
    [string]$Container    = "uas-kelompok5dan9-nginx-1",
    [string]$Interface    = "tailscale0",
    [string]$Filter       = "tcp port 80",
    [string]$PipeName     = "uas_capture",
    [switch]$NoLaunch,
    [string]$WiresharkArgs = ""
)

$ErrorActionPreference = "Stop"
$pipePath = "\\.\pipe\$PipeName"

Write-Host "[live-capture] Membuat named pipe  $pipePath"
$pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
    $PipeName,
    [System.IO.Pipes.PipeDirection]::Out,
    1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte)

# ---- Buka Wireshark otomatis (client) ----
if (-not $NoLaunch) {
    $ws = (Get-Command Wireshark.exe -ErrorAction SilentlyContinue).Source
    if (-not $ws) {
        $c = Get-ChildItem "$env:ProgramFiles\Wireshark\Wireshark.exe" -ErrorAction SilentlyContinue
        if ($c) { $ws = $c.FullName }
    }
    if (-not $ws) {
        Write-Warning "[live-capture] Wireshark.exe tidak ditemukan - buka pipe secara manual."
    } else {
        $launch = "-k -i `"$pipePath`" $WiresharkArgs"
        Write-Host "[live-capture] Membuka Wireshark:  $ws $launch"
        try { Start-Process -FilePath $ws -ArgumentList $launch } catch {
            Write-Warning "[live-capture] Gagal membuka Wireshark otomatis: $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "[live-capture] Mode manual: buka Wireshark pada $pipePath"
}

$proc = $null
try {
    Write-Host "[live-capture] Menunggu Wireshark terhubung ke pipe (Ctrl+C untuk batal) ..."
    $pipe.WaitForConnection()
    Write-Host "[live-capture] Wireshark terhubung. Streaming tshark dari container:"
    Write-Host "[live-capture]   docker exec -i $Container tshark -i $Interface -f `"$Filter`" -w -"

    # jalankan docker exec; stdout tshark = byte pcap -> disalin ke pipe.
    # gunakan cmd /c agar quoting argumen (spasi pada BPF filter) deterministik.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c docker exec -i $Container tshark -i $Interface -f `"$Filter`" -w -"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw "Gagal menjalankan docker exec." }

    $buffer = New-Object byte[] 65536
    while ($true) {
        $n = $proc.StandardOutput.BaseStream.Read($buffer, 0, $buffer.Length)
        if ($n -le 0) { break }
        $pipe.Write($buffer, 0, $n)
        $pipe.Flush()
    }
    Write-Host "[live-capture] Stream selesai (tshark/pipe ditutup)."
}
catch {
    # Named pipe terputus (Wireshark ditutup) -> hentikan tshark di container.
    Write-Host "[live-capture] Pipe terputus / berhenti: $($_.Exception.Message)"
}
finally {
    try { if ($proc -and -not $proc.HasExited) { $proc.Kill() } } catch {}
    try { $pipe.Dispose() } catch {}
    Write-Host "[live-capture] Selesai."
}
