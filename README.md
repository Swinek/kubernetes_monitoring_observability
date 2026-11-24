# Demo: skalowanie horyzontalne w Kubernetesie (k3d + HPA)

Część praktyczna prezentacji „Monitorowanie aplikacji w środowisku zwirtualizowanym” –
aplikacja FastAPI w klastrze k3d, skalowana automatycznie od **1 do 10 podów**
przez HorizontalPodAutoscaler na podstawie **dwóch niezależnych metryk: CPU i pamięci**.
Monitoring/observability (Prometheus, Grafana, Loki) dokłada osobna część – aplikacja
już wystawia `/metrics`.

## Struktura

```
app/            aplikacja FastAPI + Dockerfile
  main.py         /load/cpu, /load/memory, /healthz, /metrics
k8s/            manifesty (kubectl apply -k k8s)
  deployment.yaml requests: 200m CPU / 128Mi, limits: 500m / 512Mi
  service.yaml    ClusterIP, port 80
  hpa.yaml        min 1, max 10; cel: CPU 50%, pamięć 70% (względem requests)
  ingress.yaml    Traefik → http://localhost:8080
load/k6-script.js generator obciążenia (uruchamiany jako Job w klastrze)
demo.sh         sterowanie całym demem
```

## Wymagania (WSL / Linux)

Docker, [k3d](https://k3d.io) i kubectl w `PATH`. Metrics-server jest wbudowany w k3s,
więc HPA działa bez dodatkowej instalacji.

## Uruchomienie

```bash
./demo.sh up              # klaster k3d (1 server + 2 agenty), obraz, wdrożenie
./demo.sh watch           # w drugim terminalu: HPA, pody, zużycie (co 5 s)
./demo.sh load cpu        # obciążenie CPU: 15 req/s × 100 ms CPU
./demo.sh load memory     # obciążenie pamięci: 2 req/s × 20 MB trzymane 15 s
./demo.sh stop            # przerwanie obciążenia
./demo.sh logs            # podsumowanie k6
./demo.sh down            # usunięcie klastra
```

Parametry obciążenia: `./demo.sh load cpu 20 5m` (20 req/s, 5 min po 1 min narastania).
Aplikacja z laptopa: http://localhost:8080, Swagger: http://localhost:8080/docs.

## Jak to działa

- **`/load/cpu?ms=100`** – każde żądanie zużywa 100 ms czasu procesora (stała praca).
- **`/load/memory?mb=20&seconds=15`** – każde żądanie zajmuje 20 MB na 15 s i zwalnia
  je; pod odrzuca żądanie (503), gdy trzyma już `MAX_HELD_MB` (300 MB), żeby nie zginąć
  przez OOM.
- Obciążenie jest generowane **żądaniami HTTP**, więc Service rozkłada je na wszystkie
  repliki i nowe pody naprawdę odciążają stare.
- k6 działa **w klastrze** z `noConnectionReuse` – każde żądanie to nowe połączenie TCP,
  dzięki czemu kube-proxy kieruje ruch także do nowo dodanych podów
  (`kubectl port-forward` wysyłałby wszystko do jednego poda).
- HPA liczy potrzebną liczbę replik osobno dla CPU i dla pamięci i wybiera większą.
- Zwijanie replik: okno stabilizacji skrócone z domyślnych 300 s do 60 s.
- Deployment nie ma pola `replicas` – liczbą replik zarządza wyłącznie HPA.

## Wyniki testu (24.11.2026, WSL, 16 rdzeni)

| Scenariusz | Przebieg replik | Szczyt metryki | Błędy |
|---|---|---|---|
| CPU, 15 req/s | 1 → 4 → 5 → 6 → 10 w ~1,5 min, po obciążeniu 10 → 4 → 2 → 1 | CPU 250% przy 1 podzie, ~77% przy 10 | 0 / 3179 |
| Pamięć, 2 req/s | 1 → 2 → 5 → 8 → 10 w ~1 min, po obciążeniu 10 → 5 → 3 → 1 (~5 min) | pamięć 167% przy 1–2 podach, ~85% przy 10 | 4 / 449 (503 na starcie) |

Przy 10 podach metryki zostają powyżej celu, bo `maxReplicas: 10` ogranicza dalsze
skalowanie – to też warto pokazać (nasycenie przy górnej granicy).
# kubernetes_monitoring_observability
