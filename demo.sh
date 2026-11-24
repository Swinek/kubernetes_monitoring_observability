#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=demo
NS=demo
IMAGE=demo-app:1.0
K6_IMAGE=grafana/k6:0.54.0

usage() {
  cat <<'EOF'
Użycie: ./demo.sh <polecenie>

  up                     tworzy klaster k3d (1 server + 2 agenty), buduje obraz i wdraża aplikację
  build                  przebudowuje obraz, importuje go do klastra i restartuje pody
  deploy                 stosuje manifesty z k8s/ (kubectl apply -k)
  load cpu|memory [RATE] [DURATION]
                         uruchamia obciążenie k6 w klastrze (domyślnie cpu: 15 req/s, memory: 2 req/s, 4m)
  stop                   zatrzymuje obciążenie (usuwa Joby k6)
  watch                  co 5 s: HPA, pody i ich zużycie CPU/pamięci
  status                 jednorazowy podgląd HPA, podów i zużycia
  logs                   wynik k6 z ostatniego obciążenia
  down                   usuwa klaster

Aplikacja z laptopa: http://localhost:8080  (Swagger: http://localhost:8080/docs)
EOF
}

need() { command -v "$1" >/dev/null || { echo "Brak polecenia: $1" >&2; exit 1; }; }

cmd_build() {
  need docker; need k3d
  docker build -t "$IMAGE" app
  k3d image import "$IMAGE" -c "$CLUSTER"
  if kubectl -n "$NS" get deploy demo-app >/dev/null 2>&1; then
    kubectl -n "$NS" rollout restart deploy/demo-app
    kubectl -n "$NS" rollout status deploy/demo-app --timeout=120s
  fi
}

cmd_deploy() {
  need kubectl
  kubectl apply -k k8s
  kubectl -n "$NS" rollout status deploy/demo-app --timeout=120s
}

cmd_up() {
  need docker; need k3d; need kubectl
  if ! k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
    k3d cluster create "$CLUSTER" --agents 2 -p "8080:80@loadbalancer" --wait
  fi
  echo "Czekam na metrics-server (źródło metryk dla HPA)..."
  kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s
  cmd_build
  cmd_deploy
  echo "Gotowe. Aplikacja: http://localhost:8080"
}

cmd_load() {
  need kubectl
  local scenario="${1:-}"
  case "$scenario" in cpu|memory) ;; *) echo "Podaj scenariusz: cpu albo memory" >&2; exit 1 ;; esac
  local rate="${2:-}" duration="${3:-4m}"
  if [[ -z "$rate" ]]; then [[ "$scenario" == cpu ]] && rate=15 || rate=2; fi
  local job="k6-$scenario"

  kubectl -n "$NS" create configmap k6-script --from-file=load/k6-script.js \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NS" delete job "$job" --ignore-not-found
  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: $NS
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
          image: $K6_IMAGE
          args: ["run", "--quiet", "/scripts/k6-script.js"]
          env:
            - { name: SCENARIO, value: "$scenario" }
            - { name: RATE, value: "$rate" }
            - { name: DURATION, value: "$duration" }
          volumeMounts:
            - { name: script, mountPath: /scripts }
      volumes:
        - name: script
          configMap:
            name: k6-script
EOF
  echo "Obciążenie '$scenario' uruchomione: $rate req/s, narastanie 1m + $duration. Podgląd: ./demo.sh watch"
}

cmd_stop() {
  kubectl -n "$NS" delete job -l app=k6 --ignore-not-found
}

cmd_status() {
  kubectl -n "$NS" get hpa demo-app
  echo
  kubectl -n "$NS" get pods -l app=demo-app -o wide
  echo
  kubectl -n "$NS" top pods -l app=demo-app 2>/dev/null || echo "(metryki podów jeszcze niedostępne)"
}

cmd_watch() {
  while true; do
    clear
    date '+%H:%M:%S'
    cmd_status
    echo
    kubectl -n "$NS" get jobs -l app=k6 2>/dev/null || true
    sleep 5
  done
}

cmd_logs() {
  local pod
  pod=$(kubectl -n "$NS" get pods -l app=k6 --sort-by=.metadata.creationTimestamp -o name | tail -1)
  [[ -n "$pod" ]] || { echo "Brak podów k6" >&2; exit 1; }
  kubectl -n "$NS" logs "$pod"
}

cmd_down() {
  k3d cluster delete "$CLUSTER"
}

case "${1:-}" in
  up) cmd_up ;;
  build) cmd_build ;;
  deploy) cmd_deploy ;;
  load) shift; cmd_load "$@" ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  watch) cmd_watch ;;
  logs) cmd_logs ;;
  down) cmd_down ;;
  *) usage ;;
esac
