#requires -Version 5.1
<#
.SYNOPSIS
  Wdraza pelny stos monitoringu (kube-prometheus-stack, Loki, Grafana Alloy,
  ServiceMonitor, PrometheusRule, dashboardy Grafany) w klastrze k3d 'demo'.
#>
[CmdletBinding()]
param(
    [string]$ClusterName = "demo",
    [switch]$SkipAppBuild
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Brak wymaganego narzedzia w PATH: $Name"
    }
}

foreach ($tool in @("docker", "kubectl", "helm", "k3d")) {
    Assert-Command $tool
}

Write-Host "==> [1/6] Sprawdzanie klastra k3d '$ClusterName'..." -ForegroundColor Cyan
$clusters = k3d cluster list -o json | ConvertFrom-Json
if (-not ($clusters | Where-Object { $_.name -eq $ClusterName })) {
    Write-Host "Tworze wielowezlowy klaster k3d '$ClusterName' (1 server + 2 agents)..."
    k3d cluster create $ClusterName --agents 2 -p "8080:80@loadbalancer" --wait
} else {
    Write-Host "Klaster '$ClusterName' juz istnieje."
}

# Naprawa typowego problemu k3d na Docker Desktop (Windows):
# k3d ustawia server na https://host.docker.internal:<port>, ktory na Windowsie bywa niedostepny z hosta.
$currentServer = (kubectl config view --minify -o jsonpath="{.clusters[0].cluster.server}" 2>$null)
if ($currentServer -match "^https://host\.docker\.internal:(\d+)$") {
    $apiPort = $Matches[1]
    $fixedServer = "https://127.0.0.1:$apiPort"
    Write-Host "Aktualizuje adres API w kubeconfig na $fixedServer (obejscie Docker Desktop Windows)..." -ForegroundColor Yellow
    kubectl config set-cluster "k3d-$ClusterName" --server=$fixedServer | Out-Null
}

Write-Host "==> [2/6] Oczekiwanie na metrics-server i wdrozenie aplikacji demo-app..." -ForegroundColor Cyan
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s

if (-not $SkipAppBuild) {
    docker build -t demo-app:1.0 app
    k3d image import demo-app:1.0 -c $ClusterName
}
kubectl apply -k k8s
kubectl -n demo rollout status deploy/demo-app --timeout=180s

Write-Host "==> [3/6] Dodawanie i aktualizacja repozytoriow Helm..." -ForegroundColor Cyan
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update | Out-Null
helm repo add grafana https://grafana.github.io/helm-charts --force-update | Out-Null
helm repo update

Write-Host "==> [4/6] Instalacja stosu w namespace 'monitoring'..." -ForegroundColor Cyan
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

Write-Host " -> Instalacja/aktualizacja kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack `
    --namespace monitoring `
    --version 94.2.0 `
    -f monitoring/values/kube-prometheus-stack-values.yaml `
    --wait --timeout 10m

Write-Host " -> Instalacja/aktualizacja Loki..."
helm upgrade --install loki grafana/loki `
    --namespace monitoring `
    --version 7.7.0 `
    -f monitoring/values/loki-values.yaml `
    --wait --timeout 10m

Write-Host " -> Instalacja/aktualizacja Grafana Alloy..."
helm upgrade --install alloy grafana/alloy `
    --namespace monitoring `
    --version 1.16.0 `
    -f monitoring/values/alloy-values.yaml `
    --wait --timeout 5m

Write-Host "==> [5/6] Wdrazanie ServiceMonitor, PrometheusRule i dashboardow Grafany..." -ForegroundColor Cyan
kubectl apply -f monitoring/manifests/servicemonitor-demo-app.yaml
kubectl apply -f monitoring/manifests/prometheusrule-demo-app.yaml
kubectl apply -k monitoring/dashboards

Write-Host "==> [6/6] Status koncowy..." -ForegroundColor Cyan
kubectl get nodes -o wide
kubectl -n monitoring get pods -o wide
kubectl -n demo get pods,svc,hpa,servicemonitor -o wide

Write-Host ""
Write-Host "Gotowe! Uruchom .\scripts\port-forward.ps1 aby otworzyc panele:" -ForegroundColor Green
Write-Host "  Grafana:      http://localhost:3000  (admin / admin)"
Write-Host "  Prometheus:   http://localhost:9090"
Write-Host "  Alertmanager: http://localhost:9093"
Write-Host "  Demo App:     http://localhost:8080"
