#requires -Version 5.1
<#
.SYNOPSIS
  Uruchamia port-forwarding do Grafany, Prometheusa, Alertmanagera, Loki i Alloy.
  Zatrzymanie przez Ctrl+C zamyka wszystkie procesy w tle.
#>
$ErrorActionPreference = "Stop"

$forwards = @(
    @{ Name = "Grafana";      Namespace = "monitoring"; Target = "svc/kube-prometheus-stack-grafana";       Ports = "3000:80";     Url = "http://localhost:3000  (admin / admin)" },
    @{ Name = "Prometheus";   Namespace = "monitoring"; Target = "svc/kube-prometheus-stack-prometheus";    Ports = "9090:9090";   Url = "http://localhost:9090" },
    @{ Name = "Alertmanager"; Namespace = "monitoring"; Target = "svc/kube-prometheus-stack-alertmanager";  Ports = "9093:9093";   Url = "http://localhost:9093" },
    @{ Name = "Loki";         Namespace = "monitoring"; Target = "svc/loki";                                Ports = "3100:3100";   Url = "http://localhost:3100/ready" },
    @{ Name = "Alloy";        Namespace = "monitoring"; Target = "svc/alloy";                               Ports = "12345:12345"; Url = "http://localhost:12345" }
)

$procs = @()
try {
    foreach ($f in $forwards) {
        $p = Start-Process -FilePath "kubectl" -ArgumentList @("-n", $f.Namespace, "port-forward", $f.Target, $f.Ports) -PassThru -WindowStyle Hidden
        $procs += $p
        Write-Host ("{0,-14} -> {1}" -f $f.Name, $f.Url) -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "Port-forward aktywny. Nacisnij Ctrl+C lub zamknij okno, aby zatrzymac..." -ForegroundColor Yellow
    while ($true) {
        Start-Sleep -Seconds 2
        foreach ($p in $procs) {
            if ($p.HasExited) {
                Write-Warning "Proces port-forward PID $($p.Id) zakonczyl sie nieoczekiwanie."
            }
        }
    }
}
finally {
    Write-Host "Zatrzymywanie port-forward..." -ForegroundColor Cyan
    foreach ($p in $procs) {
        if ($p -and -not $p.HasExited) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
