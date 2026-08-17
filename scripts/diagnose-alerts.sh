#!/usr/bin/env bash
# Quick checks for the PVC alert pipeline (Prometheus → Alertmanager → fault-injector webhook).
set -euo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-default}"
HELM_NAMESPACE="${HELM_NAMESPACE:-monitoring}"
HELM_RELEASE="${HELM_RELEASE:-kube-prometheus}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"

kubectl_cmd=(kubectl)
if [ -n "$KUBE_CONTEXT" ]; then
  kubectl_cmd+=(--context "$KUBE_CONTEXT")
fi

section() {
  echo ""
  echo "=== $1 ==="
}

# Resolve Prometheus ClusterIP service (label scheme varies by chart version).
prom_service() {
  local svc
  svc=$("${kubectl_cmd[@]}" get svc prometheus-operated -n "$HELM_NAMESPACE" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || true)
  if [ -n "$svc" ]; then
    echo "$svc"
    return 0
  fi
  svc=$("${kubectl_cmd[@]}" get svc -n "$HELM_NAMESPACE" -l "app=kube-prometheus-stack-prometheus" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$svc" ]; then
    echo "$svc"
    return 0
  fi
  svc=$("${kubectl_cmd[@]}" get svc -n "$HELM_NAMESPACE" -o name 2>/dev/null \
    | grep -E 'kube-prome-prometheus' | grep -v alertmanager | head -1 | sed 's|service/||' || true)
  echo "$svc"
}

# Query Prometheus HTTP API from inside the cluster (Prometheus v3 image is distroless - no wget/curl).
prom_query() {
  local path="$1"
  local prom_svc="${2:-}"
  if [ -z "$prom_svc" ]; then
    prom_svc=$(prom_service)
  fi
  if [ -z "$prom_svc" ]; then
    echo ""
    return 1
  fi
  local url="http://${prom_svc}.${HELM_NAMESPACE}.svc.cluster.local:9090${path}"
  local pod="prom-diagnose-$$-${RANDOM}"
  local raw
  raw=$("${kubectl_cmd[@]}" run "$pod" --rm -i --restart=Never --quiet -n "$HELM_NAMESPACE" \
    --image=curlimages/curl:8.5.0 \
    --command -- curl -sf --max-time 15 "$url" 2>/dev/null || true)
  # Strip any non-JSON lines kubectl may print before the response body.
  echo "$raw" | sed -n '/^{/,$p' | head -1
}

section "Fault injector pod & service ($APP_NAMESPACE)"
"${kubectl_cmd[@]}" get deploy,svc,pods -n "$APP_NAMESPACE" -l app=fault-injector 2>/dev/null || echo "Not found"

section "Monitoring CRs"
"${kubectl_cmd[@]}" get servicemonitor fault-injector -n "$APP_NAMESPACE" -o wide 2>/dev/null \
  || echo "ServiceMonitor missing in ${APP_NAMESPACE} (run: make deploy-monitoring-cr)"
"${kubectl_cmd[@]}" get prometheusrule pvc-integrity-alerts -n "$HELM_NAMESPACE" 2>/dev/null \
  || echo "PrometheusRule missing"

section "Prometheus CR selectors (must allow fault-injector ServiceMonitor)"
PROM_CR=$("${kubectl_cmd[@]}" get prometheus -n "$HELM_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$PROM_CR" ]; then
  echo "Prometheus CR not found in $HELM_NAMESPACE"
else
  echo "Prometheus CR: $PROM_CR"
  "${kubectl_cmd[@]}" get prometheus "$PROM_CR" -n "$HELM_NAMESPACE" -o jsonpath='  serviceMonitorSelector: {.spec.serviceMonitorSelector}{"\n"}  serviceMonitorNamespaceSelector: {.spec.serviceMonitorNamespaceSelector}{"\n"}' 2>/dev/null || true
  SM_LABELS=$("${kubectl_cmd[@]}" get servicemonitor fault-injector -n "$APP_NAMESPACE" -o jsonpath='{.metadata.labels}' 2>/dev/null || true)
  echo "  fault-injector ServiceMonitor labels: ${SM_LABELS:-missing}"
fi

section "Prometheus scrape target (fault-injector)"
PROM_SVC=$(prom_service)
if [ -z "$PROM_SVC" ]; then
  echo "Prometheus service not found (release=${HELM_RELEASE}, ns=${HELM_NAMESPACE})"
else
  echo "Prometheus service: $PROM_SVC"
  TARGETS=$(prom_query "/api/v1/targets" "$PROM_SVC" || true)
  if echo "$TARGETS" | grep -qi fault-injector; then
    echo "$TARGETS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in data.get('data', {}).get('activeTargets', []):
    labels = t.get('labels', {})
    job = labels.get('job', '')
    svc = labels.get('service', '')
    if 'fault' in job.lower() or 'fault' in svc.lower() or 'injector' in job.lower():
        print(f\"  job={job} health={t.get('health')} scrapeUrl={t.get('scrapeUrl', '')}\")
        if t.get('lastError'):
            print(f\"  lastError={t['lastError']}\")
" 2>/dev/null || echo "$TARGETS" | grep -oiE '"job":"[^"]*fault[^"]*"' | head -3
  else
    echo "No fault-injector target in Prometheus"
    echo "  (re-run: make deploy-monitoring APP_NAMESPACE=${APP_NAMESPACE} for additionalScrapeConfigs fallback)"
  fi
fi

section "Canary metric in Prometheus"
METRIC=$(prom_query "/api/v1/query?query=pvc_canary_write_success" "${PROM_SVC:-}" || true)
if echo "$METRIC" | grep -q '"status":"success"' && ! echo "$METRIC" | grep -q '"result":\[\]'; then
  SERIES=$(echo "$METRIC" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['data']['result']))" 2>/dev/null || echo "?")
  echo "pvc_canary_write_success: ${SERIES} series found"
  echo "$METRIC" | head -c 400
else
  echo "Metric not found - run: make deploy-monitoring APP_NAMESPACE=${APP_NAMESPACE}"
fi
echo ""

section "Firing alerts in Prometheus"
ALERTS=$(prom_query "/api/v1/alerts" "${PROM_SVC:-}" || true)
if echo "$ALERTS" | grep -q '"alertname":"PVC'; then
  echo "$ALERTS" | grep -o '"alertname":"PVC[^"]*"' | sort -u
else
  echo "No PVC alerts currently firing/pending"
fi

section "Alertmanager webhook URL (from secret)"
AM_SECRET=$("${kubectl_cmd[@]}" get secrets -n "$HELM_NAMESPACE" -o name 2>/dev/null \
  | grep -i alertmanager | grep -v token | head -1 | sed 's|secret/||' || true)
if [ -z "$AM_SECRET" ]; then
  AM_SECRET=$("${kubectl_cmd[@]}" get secret -n "$HELM_NAMESPACE" -l "app.kubernetes.io/name=alertmanager" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [ -n "$AM_SECRET" ]; then
  echo "Secret: $AM_SECRET"
  "${kubectl_cmd[@]}" get secret "$AM_SECRET" -n "$HELM_NAMESPACE" -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null \
    | base64 -d 2>/dev/null | grep -A3 "pvc-alerts" || echo "Could not read alertmanager config (key may differ)"
else
  echo "Alertmanager secret not found - is alertmanager enabled? (helm release: ${HELM_RELEASE})"
fi

section "Webhook reachability from monitoring namespace"
if "${kubectl_cmd[@]}" run am-webhook-test --rm -i --restart=Never -n "$HELM_NAMESPACE" \
  --image=curlimages/curl:8.5.0 \
  --command -- curl -sf -o /dev/null -w "HTTP %{http_code}\n" \
  "http://fault-injector.${APP_NAMESPACE}.svc.cluster.local:8080/health" 2>&1; then
  :
else
  echo "curl test failed (network policy or fault-injector not reachable from ${HELM_NAMESPACE})"
fi

section "Alert history in fault-injector (requires port-forward or in-cluster curl)"
echo "Run: curl -s http://localhost:8080/alerts/history  (after make port-forward)"
echo ""
echo "Fix checklist:"
echo "  1. make deploy-monitoring APP_NAMESPACE=${APP_NAMESPACE}     # webhook + additionalScrapeConfigs"
echo "  2. make deploy-monitoring-cr APP_NAMESPACE=${APP_NAMESPACE}  # ServiceMonitor in app ns + rules"
echo "  3. wait 1–2m, re-run: make diagnose-alerts APP_NAMESPACE=${APP_NAMESPACE}"
echo "  4. inject fault, wait for rule 'for:' duration (1–2m)"
