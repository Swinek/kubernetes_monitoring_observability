#requires -Version 5.1
<#
.SYNOPSIS
  Uruchamia scenariusze obciazenia i testowe z Windows PowerShell (k6, stress-ng, status, stop, logs).
  Nie modyfikuje load/k6-script.js ani demo.sh.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("cpu", "memory", "errors5xx", "stress-ng", "stop", "status", "logs")]
    [string]$Action,

    [int]$Rate = 0,
    [string]$Duration = "3m",
    [int]$MemMb = 120,
    [int]$MemSeconds = 20
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot
$Ns = "demo"

function Start-K6Job {
    param(
        [string]$JobName,
        [string]$Scenario,
        [int]$ReqRate,
        [string]$RunDuration,
        [int]$Mb,
        [int]$Seconds
    )

    $cmYaml = kubectl -n $Ns create configmap k6-script --from-file=load/k6-script.js --dry-run=client -o yaml
    $cmYaml | kubectl apply -f - | Out-Null

    kubectl -n $Ns delete job $JobName --ignore-not-found | Out-Null

    $jobYaml = @"
apiVersion: batch/v1
kind: Job
metadata:
  name: $JobName
  namespace: $Ns
  labels:
    app: k6
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: k6
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:0.54.0
          args: ["run", "--quiet", "/scripts/k6-script.js"]
          env:
            - name: SCENARIO
              value: "$Scenario"
            - name: RATE
              value: "$ReqRate"
            - name: DURATION
              value: "$RunDuration"
            - name: MEM_MB
              value: "$Mb"
            - name: MEM_SECONDS
              value: "$Seconds"
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: k6-script
"@
    $jobYaml | kubectl apply -f -
    Write-Host "Uruchomiono Job '$JobName' (scenario=$Scenario, rate=$ReqRate req/s, narastanie 1m + $RunDuration)." -ForegroundColor Green
}

switch ($Action) {
    "cpu" {
        $r = if ($Rate -gt 0) { $Rate } else { 20 }
        Start-K6Job -JobName "k6-cpu" -Scenario "cpu" -ReqRate $r -RunDuration $Duration -Mb 20 -Seconds 15
    }
    "memory" {
        $r = if ($Rate -gt 0) { $Rate } else { 3 }
        Start-K6Job -JobName "k6-memory" -Scenario "memory" -ReqRate $r -RunDuration $Duration -Mb 25 -Seconds 15
    }
    "errors5xx" {
        # Przekracza MAX_HELD_MB=300 na podzie, wywolujac HTTP 503 oraz wysoka pamiec -> HPA + DemoAppHigh5xxErrorRate
        $r = if ($Rate -gt 0) { $Rate } else { 8 }
        Start-K6Job -JobName "k6-errors5xx" -Scenario "memory" -ReqRate $r -RunDuration $Duration -Mb $MemMb -Seconds $MemSeconds
    }
    "stress-ng" {
        kubectl -n $Ns delete job stress-ng-cpu --ignore-not-found | Out-Null
        kubectl apply -f monitoring/load-tests/stress-ng-job.yaml
        Write-Host "Uruchomiono Job 'stress-ng-cpu' w namespace '$Ns'." -ForegroundColor Green
    }
    "stop" {
        kubectl -n $Ns delete job -l app=k6 --ignore-not-found
        kubectl -n $Ns delete job stress-ng-cpu --ignore-not-found
        Write-Host "Usunieto wszystkie Joby obciazeniowe w namespace '$Ns'." -ForegroundColor Yellow
    }
    "status" {
        kubectl -n $Ns get hpa demo-app
        Write-Host ""
        kubectl -n $Ns get pods -o wide
        Write-Host ""
        kubectl -n $Ns top pods 2>$null
    }
    "logs" {
        $pod = kubectl -n $Ns get pods -l app=k6 --sort-by=.metadata.creationTimestamp -o name | Select-Object -Last 1
        if (-not $pod) { throw "Brak podow k6 w namespace '$Ns'." }
        kubectl -n $Ns logs $pod
    }
}
