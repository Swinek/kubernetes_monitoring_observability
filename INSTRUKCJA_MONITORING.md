# Instrukcja monitoringu i observability (k3d + Prometheus + Grafana + Loki + Alloy)

Dokumentacja części praktycznej projektu **„Monitorowanie aplikacji w środowisku zwirtualizowanym”**.
Cały stos monitoringu wdrożono w osobnym namespace `monitoring` bez modyfikowania istniejących plików grupy (`app/`, `k8s/`, `load/`, `demo.sh`).

---

## 1. Architektura wdrożonego stanowiska

- **Klaster wielowęzłowy `k3d` (`demo`)**: `1` węzeł control-plane (`k3d-demo-server-0`) + `2` węzły robocze (`k3d-demo-agent-0`, `k3d-demo-agent-1`).
- **Aplikacja (`namespace: demo`)**: serwis FastAPI `demo-app` z endpointem `/metrics` (`prometheus-fastapi-instrumentator`), skalowany przez HPA (`1`–`10` replik na podstawie CPU `50%` i pamięci `70%`) oraz wystawiony lokalnie przez Traefik na `http://localhost:8080`.
- **Metryki i alerty (`namespace: monitoring`, chart `prometheus-community/kube-prometheus-stack` `94.2.0`)**:
  - **Prometheus Operator** + **Prometheus** (interwał scrapowania i ewaluacji `15s`, wykrywanie `ServiceMonitor` i `PrometheusRule` ze wszystkich namespace'ów),
  - **node_exporter** (DaemonSet na wszystkich 3 węzłach – metryki CPU, RAM, dysku, sieci, `CPU steal time`),
  - **cAdvisor** (wbudowany w `kubelet` – zużycie CPU, pamięci i throttling kontenerów),
  - **kube-state-metrics** (stan obiektów Kubernetesa: repliki, HPA, restarty),
  - **Alertmanager** (skonfigurowany wyłącznie pod panele Prometheus / Alertmanager / Grafana z odbiornikiem `null` – bez zewnętrznych powiadomień e-mail/Slack/Discord),
  - **Grafana** (z automatycznie skonfigurowanymi źródłami danych `Prometheus`, `Loki`, `Alertmanager` oraz dashboardami w folderze `Demo Observability`).
- **Logi (`namespace: monitoring`)**:
  - **Loki** (`grafana/loki` `7.7.0`, tryb `SingleBinary` z lokalnym PVC `2Gi` na `local-path`),
  - **Grafana Alloy** (`grafana/alloy` `1.16.0`, DaemonSet na każdym węźle zamiast wycofanego Promtaila – zbiera logi podów z bieżącego węzła przez `loki.source.kubernetes` i przekazuje je z etykietami `namespace`, `pod`, `container`, `node`, `app`, `job` do Loki).

---

## 2. Dodane pliki i katalogi

```text
monitoring/
├── values/
│   ├── kube-prometheus-stack-values.yaml   # Konfiguracja Helm dla Prometheus, Alertmanager, Grafana, node_exporter, kube-state-metrics + źródło Loki
│   ├── loki-values.yaml                    # Konfiguracja Helm dla Loki (SingleBinary, filesystem + PVC 2Gi)
│   └── alloy-values.yaml                   # Konfiguracja Helm dla Grafana Alloy (DaemonSet, pipeline River do Loki)
├── manifests/
│   ├── servicemonitor-demo-app.yaml        # Deklaratywne podpięcie endpointu /metrics serwisu demo-app (namespace demo)
│   └── prometheusrule-demo-app.yaml        # Reguły alertów: wysokie CPU, restarty poda, błędy HTTP 5xx, wysoka pamięć
├── dashboards/
│   ├── kustomization.yaml                  # Generuje ConfigMapy z etykietą grafana_dashboard="1" (folder "Demo Observability")
│   ├── use-cluster-nodes-pods.json         # Dashboard USE (węzły i pody)
│   ├── red-demo-app.json                   # Dashboard RED (Rate, Errors, Duration + HPA)
│   └── correlation-pod-metrics-logs.json   # Korelacja metryk Prometheus + logów Loki dla konkretnego poda
└── load-tests/
    └── stress-ng-job.yaml                  # Job stress-ng (2 wątki CPU przez 90s) do symulacji obciążenia / noisy neighbor
scripts/
├── setup-monitoring.ps1                    # Pełne uruchomienie klastra, demo-app i stosu monitoringu na Windows
├── port-forward.ps1                        # Przekierowanie portów do Grafany, Prometheusa, Alertmanagera, Loki i Alloy
└── load-k6.ps1                             # Uruchamianie scenariuszy obciążenia (k6, stress-ng) z Windows PowerShell
INSTRUKCJA_MONITORING.md                    # Niniejsza instrukcja
```

---

## 3. Wymagania i komendy uruchomienia (Windows PowerShell)

Zainstalowane narzędzia na Twoim komputerze: `docker`, `kubectl`, `helm`, `k3d`, `k6`.

### Krok 1 – Pełne wdrożenie środowiska (klaster + aplikacja + monitoring)

W PowerShell w katalogu głównym repozytorium:

```powershell
.\scripts\setup-monitoring.ps1
```

Co robi skrypt:
1. Tworzy klaster `k3d` o nazwie `demo` (`1` serwer + `2` agenty, port `8080:80@loadbalancer`), jeśli jeszcze nie istnieje.
2. Naprawia w `kubeconfig` znany problem `k3d` pod Docker Desktop na Windowsie (zamienia `https://host.docker.internal:<port>` na `https://127.0.0.1:<port>`).
3. Buduje obraz `demo-app:1.0`, importuje go do `k3d` i stosuje manifesty z `k8s/`.
4. Instaluje/aktualizuje charty Helm `kube-prometheus-stack`, `loki` i `alloy` w namespace `monitoring`.
5. Wdraża `ServiceMonitor`, `PrometheusRule` oraz 3 dashboardy Grafany.

> **Wskazówka:** Jeśli klaster został wcześniej utworzony przez `./demo.sh up` w Git Bash / WSL i `kubectl` na Windowsie zgłasza timeout na `host.docker.internal`, uruchom jednorazowo:
> `.\scripts\setup-monitoring.ps1 -SkipAppBuild`

### Krok 2 – Otwarcie paneli w przeglądarce (`port-forward`)

W osobnym oknie PowerShell:

```powershell
.\scripts\port-forward.ps1
```

Dostępne panele:
- **Grafana**: `http://localhost:3000` (login: `admin`, hasło: `admin`)
  - Folder **Dashboards → Demo Observability**:
    - `USE: Zasoby węzłów i podów`
    - `RED: Metryki aplikacji demo-app`
    - `Korelacja metryk i logów (Prometheus + Loki)`
- **Prometheus**: `http://localhost:9090` (`Status → Targets`, `Alerts`)
- **Alertmanager**: `http://localhost:9093`
- **Aplikacja demo**: `http://localhost:8080` (`http://localhost:8080/docs`, `http://localhost:8080/metrics`)
- **Loki API**: `http://localhost:3100/ready`
- **Grafana Alloy UI**: `http://localhost:12345`

### Krok 3 – Sprawdzenie podstawowe z terminala

```powershell
kubectl get nodes -o wide
kubectl -n monitoring get pods -o wide
kubectl -n demo get pods,svc,hpa,servicemonitor
```

---

## 4. Scenariusz pokazu na obronę (krok po kroku)

Przed prezentacją upewnij się, że działa `.\scripts\port-forward.ps1` i masz otwarte w przeglądarce:
1. Grafana (`http://localhost:3000`)
2. Prometheus (`http://localhost:9090/targets` oraz `http://localhost:9090/alerts`)
3. Alertmanager (`http://localhost:9093`)

### Część A – Architektura i automatyczne zbieranie danych (1–2 min)
1. Pokaż węzły i pody:
   ```powershell
   kubectl get nodes -o wide
   kubectl -n monitoring get pods -o wide
   ```
   Wyjaśnij: klaster ma `1` control-plane i `2` workery; `node_exporter` i `Grafana Alloy` działają jako **DaemonSet** (po 1 podzie na każdym węźle).
2. W Prometheusie (`Status → Targets`) pokaż aktywne pule `UP`, w tym `serviceMonitor/demo/demo-app/0` oraz `node-exporter`, `kubelet` (cAdvisor) i `kube-state-metrics`.
3. Pokaż deklaratywne pliki [servicemonitor-demo-app.yaml](monitoring/manifests/servicemonitor-demo-app.yaml) i [prometheusrule-demo-app.yaml](monitoring/manifests/prometheusrule-demo-app.yaml) – brak ręcznego wpisywania adresów IP.

### Część B – Dashboardy USE i RED w stanie spoczynku (1 min)
1. Otwórz w Grafanie **`USE: Zasoby węzłów i podów`** – omów Utilization, Saturation (`Load1 / rdzenie`, CPU throttling), `CPU steal time` oraz Errors na węzłach i podach.
2. Otwórz **`RED: Metryki aplikacji demo-app`** – omów **R**ate (żądania/s), **E**rrors (5xx %), **D**uration (p50/p90/p95/p99) oraz aktualną liczbę replik HPA (`1`).

### Część C – Obciążenie CPU, autoskalowanie HPA, `stress-ng` i alert CPU (3 min)
1. Uruchom obciążenie CPU przez `k6` (oraz opcjonalnie `stress-ng`):
   ```powershell
   .\scripts\load-k6.ps1 -Action cpu -Rate 25 -Duration 3m
   .\scripts\load-k6.ps1 -Action stress-ng
   ```
2. W drugim terminalu podglądaj skalowanie HPA i rozmieszczenie podów na węzłach:
   ```powershell
   .\scripts\load-k6.ps1 -Action status
   ```
3. Pokaż w Grafanie:
   - Na dashboardzie **RED**: wzrost `Rate`, skok latencji, wzrost liczby replik HPA (`1 → ... → 10`) i rozłożenie ruchu HTTP między nowe pody.
   - Na dashboardzie **USE**: skok obciążenia CPU na węzłach (`k3d-demo-server-0`, `agent-0`, `agent-1`) oraz throttling podów.
4. Po ok. 60–90 s pokaż w Prometheusie (`/alerts`) i Alertmanagerze (`http://localhost:9093`) zapalony alert **`DemoAppHighCPUUsage`** (a przy bardzo dużym nasyceniu także `DemoAppPodRestarting`).
5. Zatrzymaj obciążenie CPU:
   ```powershell
   .\scripts\load-k6.ps1 -Action stop
   ```

### Część D – Błędy HTTP 5xx i korelacja metryk z logami (2 min)
1. Uruchom scenariusz wywołujący błędy HTTP `503` (przekroczenie limitu `MAX_HELD_MB=300` na `/load/memory`):
   ```powershell
   .\scripts\load-k6.ps1 -Action errors5xx -Rate 8 -Duration 2m
   ```
2. Na dashboardzie **RED** pokaż wzrost serii `status="5xx"` oraz `Errors 5xx (%)`.
3. Po ok. 45–60 s w Prometheusie i Alertmanagerze pokaż alert krytyczny **`DemoAppHigh5xxErrorRate`** (oraz ostrzeżenie **`DemoAppHighMemoryUsage`**).
4. Zatrzymaj obciążenie:
   ```powershell
   .\scripts\load-k6.ps1 -Action stop
   ```

### Część E – Test efemeryczności podów + korelacja z logami w Loki (2 min)
1. Sprawdź aktualne pody w `demo`:
   ```powershell
   kubectl -n demo get pods -l app=demo-app -o wide
   ```
2. Usuń jeden z podów (zapisz wcześniej jego nazwę i IP):
   ```powershell
   kubectl -n demo delete pod <NAZWA_PODA>
   ```
3. Po ok. 20 s pokaż:
   - Nowy pod ma **inną nazwę i nowy adres IP** (`kubectl -n demo get pods -l app=demo-app -o wide`).
   - W Prometheusie (`Status → Targets` → `serviceMonitor/demo/demo-app/0`) stary adres IP zniknął, a nowy pojawił się sam ze statusem **`UP`**.
   - W Grafanie na dashboardzie **`Korelacja metryk i logów (Prometheus + Loki)`** wybierz namespace `demo` (i nowy pod lub `All`): widać metryki zużycia CPU/RAM/HTTP **obok** logów startowych nowego poda (`Started server process`, `Application startup complete`) oraz logów pracy/błędów generatorów `k6` i `stress-ng` w tym samym oknie czasu.

---

## 5. Przydatne komendy porządkowe

- Podgląd wyników ostatniego Joba `k6`:
  ```powershell
  .\scripts\load-k6.ps1 -Action logs
  ```
- Zatrzymanie wszystkich obciążeń w `demo`:
  ```powershell
  .\scripts\load-k6.ps1 -Action stop
  ```
- Usunięcie całego klastra po obronie:
  ```powershell
  k3d cluster delete demo
  ```
