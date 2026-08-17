CLUSTER_NAME := pvc-monitoring-poc
KIND_KUBE_CONTEXT := kind-$(CLUSTER_NAME)
KIND_CONFIG := kind-config.yaml
# Empty KUBE_CONTEXT = use current kubectl context. For kind: KUBE_CONTEXT=$(KIND_KUBE_CONTEXT)
KUBE_CONTEXT ?=
HELM_RELEASE := kube-prometheus
HELM_NAMESPACE := monitoring
CHAOS_HELM_RELEASE := chaos-mesh
CHAOS_HELM_NAMESPACE := chaos-mesh
CHAOS_MESH_VERSION := 2.8.2
KIND_NODE_IMAGE := kindest/node:v1.35.0
HOST_ARCH := $(shell uname -m)
KIND_AMD64_IMAGE := kindest/node:v1.35.0
FAULT_INJECTOR_IMAGE := fault-injector:local
FAULT_INJECTOR_URL := http://localhost:8080
# Remote cluster: storage class for dynamic PVCs (required for deploy-remote).
STORAGE_CLASS ?= standard
# Remote cluster: full image ref pushed to your registry, e.g. ghcr.io/you/fault-injector:latest
REMOTE_IMAGE ?=
# Remote clusters are usually amd64; cross-build from Apple Silicon with buildx.
REMOTE_BUILD_PLATFORM ?= linux/amd64
# Optional: name of docker-registry secret on the deployment (create with make create-pull-secret)
IMAGE_PULL_SECRET ?=
IMAGE_PULL_SECRET_NAME ?= fault-injector-pull
APP_NAMESPACE ?= default
REGISTRY_ENV_FILE ?= fault-injector/k8s/registry-credentials.env

KUBECTL := kubectl $(if $(KUBE_CONTEXT),--context $(KUBE_CONTEXT),)
HELM_KUBE := $(if $(KUBE_CONTEXT),--kube-context $(KUBE_CONTEXT),)

.PHONY: help cluster-up cluster-up-amd64 setup-storage-paths deploy deploy-remote deploy-storage deploy-storage-remote deploy-monitoring deploy-monitoring-cr deploy-chaos deploy-app deploy-app-rbac deploy-app-remote build build-amd64 load push create-pull-secret port-forward teardown teardown-remote diagnose-alerts demo-fill demo-readonly demo-io-fault demo-io-latency demo-io-reset demo-inodes demo-unbound demo-reset status verify-iochaos

help:
	@echo "PVC Monitoring POC - available targets:"
	@echo ""
	@echo "Kind (local - set KUBE_CONTEXT=$(KIND_KUBE_CONTEXT) if not your current context):"
	@echo "  cluster-up          Create kind cluster (native arch; recommended on Apple Silicon)"
	@echo "  cluster-up-amd64    Create amd64 kind cluster (experimental; needed for IOChaos on Mac)"
	@echo "  deploy              Full deploy on kind (cluster + stack; switches kubectl context)"
	@echo "  load                  Load fault-injector image into kind"
	@echo ""
	@echo "Remote / any cluster (default: current kubectl context):"
	@echo "  deploy-remote       Deploy stack without kind (needs STORAGE_CLASS, REMOTE_IMAGE)"
	@echo "  push                Cross-build ($(REMOTE_BUILD_PLATFORM)) and push to REMOTE_IMAGE"
	@echo "  build-remote        Build fault-injector for remote arch (loads locally)"
	@echo "  create-pull-secret  Create registry pull secret (see registry-credentials.env.example)"
	@echo "  teardown-remote     Remove workloads only (does not delete the cluster)"
	@echo ""
	@echo "Shared:"
	@echo "  deploy-monitoring     Install kube-prometheus-stack via Helm"
	@echo "  deploy-monitoring-cr  Apply PrometheusRules, ServiceMonitor, Grafana dashboard"
	@echo "  diagnose-alerts       Debug Prometheus → Alertmanager → webhook pipeline"
	@echo "  deploy-chaos          Install Chaos Mesh (IOChaos for real I/O faults)"
	@echo "  build                 Build fault-injector Docker image"
	@echo "  port-forward          Forward fault-injector, Grafana, Prometheus, Alertmanager, Chaos Dashboard"
	@echo "  demo-*                Fault injection scenarios"
	@echo "  status                Show cluster and pod status"
	@echo "  teardown              Remove everything including kind cluster"

cluster-up:
	mkdir -p /tmp/pvc-poc/vol1 /tmp/pvc-poc/vol2 /tmp/pvc-poc/vol3
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Cluster $(CLUSTER_NAME) already exists, skipping create"; \
	else \
		if [ "$(HOST_ARCH)" = "arm64" ]; then \
			echo "Ensuring native arm64 kind node (clears amd64 image cache from IOChaos experiments)"; \
			docker pull $(KIND_NODE_IMAGE); \
		fi; \
		kind create cluster --config $(KIND_CONFIG) --image $(KIND_NODE_IMAGE); \
	fi
	$(MAKE) setup-storage-paths
	$(KUBECTL) cluster-info

cluster-up-amd64:
	mkdir -p /tmp/pvc-poc/vol1 /tmp/pvc-poc/vol2 /tmp/pvc-poc/vol3
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Cluster $(CLUSTER_NAME) already exists - delete it first: kind delete cluster --name $(CLUSTER_NAME)"; \
		exit 1; \
	fi
	@echo "Pulling amd64 kind node (IOChaos/toda requires x86_64; needs ~8GiB Docker RAM)"
	docker pull --platform linux/amd64 $(KIND_AMD64_IMAGE)
	kind create cluster --config $(KIND_CONFIG) --image $(KIND_AMD64_IMAGE)
	$(MAKE) setup-storage-paths
	$(KUBECTL) cluster-info

setup-storage-paths:
	docker exec $(CLUSTER_NAME)-control-plane mkdir -p /var/local-pvc/vol1 /var/local-pvc/vol2
	docker exec $(CLUSTER_NAME)-control-plane sh -c '\
		if mountpoint -q /var/local-pvc/vol3 2>/dev/null; then \
			echo "vol3 tmpfs already mounted"; \
		else \
			mkdir -p /var/local-pvc/vol3 && \
			mount -t tmpfs -o size=16m,nr_inodes=2048,mode=755 tmpfs /var/local-pvc/vol3; \
		fi'

deploy-storage: setup-storage-paths
	$(KUBECTL) apply -f storage/
	$(KUBECTL) wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-healthy -n default --timeout=60s
	$(KUBECTL) wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-filling -n default --timeout=60s
	$(KUBECTL) wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-fault -n default --timeout=60s

deploy-storage-remote:
	@test -n "$(STORAGE_CLASS)" || (echo "STORAGE_CLASS is required (e.g. STORAGE_CLASS=gp3 make deploy-remote)" && exit 1)
	sed -e 's|__STORAGE_CLASS__|$(STORAGE_CLASS)|g' -e 's|__APP_NAMESPACE__|$(APP_NAMESPACE)|g' \
		storage/remote/pvcs.yaml | $(KUBECTL) apply -f -
	$(KUBECTL) wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-healthy -n $(APP_NAMESPACE) --timeout=120s
	$(KUBECTL) wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-filling -n $(APP_NAMESPACE) --timeout=120s
	$(KUBECTL) wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-fault -n $(APP_NAMESPACE) --timeout=120s

deploy-monitoring:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo update
	sed -e 's|__APP_NAMESPACE__|$(APP_NAMESPACE)|g' \
		-e 's|__CHAOS_HELM_NAMESPACE__|$(CHAOS_HELM_NAMESPACE)|g' \
		helm/kube-prometheus-values.yaml > /tmp/kube-prometheus-values-$(APP_NAMESPACE).yaml
	helm upgrade --install $(HELM_RELEASE) prometheus-community/kube-prometheus-stack \
		--namespace $(HELM_NAMESPACE) \
		--create-namespace \
		--values /tmp/kube-prometheus-values-$(APP_NAMESPACE).yaml \
		$(HELM_KUBE) \
		--wait --timeout 10m
	@echo "Alertmanager webhook → http://fault-injector.$(APP_NAMESPACE).svc.cluster.local:8080/alerts"
	@echo "Grafana Chaos Mesh datasource → http://chaos-dashboard.$(CHAOS_HELM_NAMESPACE).svc.cluster.local:2333 (after make deploy-chaos)"

deploy-monitoring-cr:
	$(KUBECTL) delete servicemonitor fault-injector -n $(HELM_NAMESPACE) --ignore-not-found
	sed -e 's|__HELM_RELEASE__|$(HELM_RELEASE)|g' monitoring/pvc-alert-rules.yaml | $(KUBECTL) apply -f -
	sed -e 's|__APP_NAMESPACE__|$(APP_NAMESPACE)|g' -e 's|__HELM_RELEASE__|$(HELM_RELEASE)|g' \
		monitoring/fault-injector-servicemonitor.yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f monitoring/grafana-dashboard-configmap.yaml
	$(KUBECTL) apply -f monitoring/grafana-chaos-dashboard-configmap.yaml

deploy-chaos:
	helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
	helm repo update
	helm upgrade --install $(CHAOS_HELM_RELEASE) chaos-mesh/chaos-mesh \
		--namespace $(CHAOS_HELM_NAMESPACE) \
		--create-namespace \
		--version $(CHAOS_MESH_VERSION) \
		--values helm/chaos-mesh-values.yaml \
		$(HELM_KUBE) \
		--wait --timeout 10m
	$(KUBECTL) wait --for=condition=Ready pods \
		-l app.kubernetes.io/component=controller-manager \
		-n $(CHAOS_HELM_NAMESPACE) --timeout=180s
	$(KUBECTL) wait --for=condition=Ready pods \
		-l app.kubernetes.io/component=chaos-daemon \
		-n $(CHAOS_HELM_NAMESPACE) --timeout=180s
	@$(MAKE) verify-iochaos
	@echo "Chaos Dashboard: kubectl port-forward -n $(CHAOS_HELM_NAMESPACE) svc/chaos-dashboard 2333:2333"
	@echo "  → http://localhost:2333 (auth disabled - dashboard.securityMode=false in helm/chaos-mesh-values.yaml)"

diagnose-alerts:
	chmod +x scripts/diagnose-alerts.sh
	APP_NAMESPACE=$(APP_NAMESPACE) HELM_NAMESPACE=$(HELM_NAMESPACE) HELM_RELEASE=$(HELM_RELEASE) \
		KUBE_CONTEXT=$(KUBE_CONTEXT) scripts/diagnose-alerts.sh

verify-iochaos:
	@DAEMON=$$($(KUBECTL) get pods -n $(CHAOS_HELM_NAMESPACE) -l app.kubernetes.io/component=chaos-daemon -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$DAEMON" ]; then \
		echo "No chaos-daemon pod found - run make deploy-chaos first"; \
		exit 1; \
	fi; \
	if $(KUBECTL) exec -n $(CHAOS_HELM_NAMESPACE) $$DAEMON -- \
		sh -c '/usr/local/bin/toda --help >/dev/null 2>&1'; then \
		echo "IOChaos/toda runtime OK"; \
	else \
		echo "WARNING: toda cannot run on this cluster (expected on arm64 kind nodes)."; \
		echo "  Use make demo-readonly for I/O failure demos, or recreate with make cluster-up-amd64."; \
		exit 1; \
	fi

build:
	docker build --load -t $(FAULT_INJECTOR_IMAGE) fault-injector/

build-amd64:
	$(MAKE) build-remote

build-remote:
	@echo "Building fault-injector for $(REMOTE_BUILD_PLATFORM) (host: $(HOST_ARCH))"
	docker buildx build --platform $(REMOTE_BUILD_PLATFORM) \
		-t $(FAULT_INJECTOR_IMAGE) \
		fault-injector/ \
		--provenance=false --sbom=false \
		--load

push:
	@test -n "$(REMOTE_IMAGE)" || (echo "REMOTE_IMAGE is required (e.g. REMOTE_IMAGE=ghcr.io/you/fault-injector:latest)" && exit 1)
	@echo "Building and pushing fault-injector for $(REMOTE_BUILD_PLATFORM) (host: $(HOST_ARCH)) -> $(REMOTE_IMAGE)"
	@echo "(npm/build runs on native arch; final image is copy-only - no QEMU apk/npm on target)"
	docker buildx build --platform $(REMOTE_BUILD_PLATFORM) \
		-t $(REMOTE_IMAGE) \
		fault-injector/ \
		--provenance=false --sbom=false \
		--push

create-pull-secret:
	@set -a; \
	if [ -f "$(REGISTRY_ENV_FILE)" ]; then . "$(REGISTRY_ENV_FILE)"; fi; \
	set +a; \
	test -n "$${REGISTRY_SERVER:-}" || (echo "REGISTRY_SERVER required (env var or $(REGISTRY_ENV_FILE))" && exit 1); \
	test -n "$${REGISTRY_USER:-}" || (echo "REGISTRY_USER required" && exit 1); \
	test -n "$${REGISTRY_PASSWORD:-}" || (echo "REGISTRY_PASSWORD required" && exit 1); \
	$(KUBECTL) create secret docker-registry $(IMAGE_PULL_SECRET_NAME) \
		--namespace=$(APP_NAMESPACE) \
		--docker-server="$$REGISTRY_SERVER" \
		--docker-username="$$REGISTRY_USER" \
		--docker-password="$$REGISTRY_PASSWORD" \
		--docker-email="$${REGISTRY_EMAIL:-you@example.com}" \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -
	@echo "Created/updated secret $(IMAGE_PULL_SECRET_NAME) in namespace $(APP_NAMESPACE)"
	@echo "Deploy with: IMAGE_PULL_SECRET=$(IMAGE_PULL_SECRET_NAME) make deploy-app-remote ..."

load:
	kind load docker-image $(FAULT_INJECTOR_IMAGE) --name $(CLUSTER_NAME)

deploy-app-rbac:
	sed 's|__APP_NAMESPACE__|$(APP_NAMESPACE)|g' fault-injector/k8s/rbac.yaml | $(KUBECTL) apply -f -

deploy-app: build load deploy-app-rbac
	$(KUBECTL) apply -f fault-injector/k8s/deployment.yaml
	$(KUBECTL) delete pod -n $(APP_NAMESPACE) -l app=fault-injector --wait=true
	$(KUBECTL) rollout status deployment/fault-injector -n $(APP_NAMESPACE) --timeout=120s

deploy-app-remote: deploy-app-rbac
	@test -n "$(REMOTE_IMAGE)" || (echo "REMOTE_IMAGE is required" && exit 1)
	chmod +x fault-injector/k8s/render-deployment-remote.sh
	fault-injector/k8s/render-deployment-remote.sh "$(REMOTE_IMAGE)" "$(IMAGE_PULL_SECRET)" \
		| sed 's|namespace: default|namespace: $(APP_NAMESPACE)|g' \
		| $(KUBECTL) apply -f -
	$(KUBECTL) delete pod -n $(APP_NAMESPACE) -l app=fault-injector --wait=true 2>/dev/null || true
	@if ! $(KUBECTL) rollout status deployment/fault-injector -n $(APP_NAMESPACE) --timeout=180s; then \
		echo ""; \
		echo "Rollout failed. Common causes on managed clusters:"; \
		echo "  - Pod Security blocked privileged pods (fixed in deployment-remote; re-run deploy-app-remote)"; \
		echo "  - ImagePullBackOff (check IMAGE_PULL_SECRET / REMOTE_IMAGE)"; \
		echo "  - PVCs on different nodes (3x RWO volumes must schedule together)"; \
		echo ""; \
		$(KUBECTL) get pods,rs -n $(APP_NAMESPACE) -l app=fault-injector; \
		$(KUBECTL) describe deployment fault-injector -n $(APP_NAMESPACE) | tail -20; \
		RS=$$($(KUBECTL) get rs -n $(APP_NAMESPACE) -l app=fault-injector -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null); \
		if [ -n "$$RS" ]; then $(KUBECTL) describe rs "$$RS" -n $(APP_NAMESPACE) | tail -25; fi; \
		exit 1; \
	fi

deploy: cluster-up deploy-storage deploy-monitoring build load deploy-app deploy-monitoring-cr
	@echo ""
	@echo "Deploy complete. Run 'make port-forward' then open http://localhost:8080"
	@echo "Optional IOChaos: make deploy-chaos  (requires amd64 nodes on Apple Silicon)"

deploy-remote: deploy-storage-remote deploy-monitoring deploy-app-remote deploy-monitoring-cr
	@echo ""
	@echo "Remote deploy complete on context: $(or $(KUBE_CONTEXT),current)"
	@echo "  kubectl port-forward -n default svc/fault-injector 8080:8080"
	@echo "  kubectl port-forward -n $(HELM_NAMESPACE) svc/$(HELM_RELEASE)-grafana 3000:80"
	@echo "Optional: make deploy-chaos"

port-forward:
	@echo "Starting port-forwards (Ctrl+C to stop)..."
	@echo "  Fault injector:  http://localhost:8080"
	@echo "  Grafana:         http://localhost:3000  (admin / poc-admin)"
	@echo "  Prometheus:      http://localhost:9090"
	@echo "  Alertmanager:    http://localhost:9093"
	@echo "  Chaos Dashboard: http://localhost:2333  (after make deploy-chaos)"
	$(KUBECTL) port-forward -n $(APP_NAMESPACE) svc/fault-injector 8080:8080 & \
	$(KUBECTL) port-forward -n $(HELM_NAMESPACE) svc/$(HELM_RELEASE)-grafana 3000:80 & \
	$(KUBECTL) port-forward -n $(HELM_NAMESPACE) svc/$(HELM_RELEASE)-kube-prome-prometheus 9090:9090 & \
	$(KUBECTL) port-forward -n $(HELM_NAMESPACE) svc/$(HELM_RELEASE)-kube-prome-alertmanager 9093:9093 & \
	$(KUBECTL) port-forward -n $(CHAOS_HELM_NAMESPACE) svc/chaos-dashboard 2333:2333 2>/dev/null & \
	wait

demo-fill:
	curl -sf -X POST $(FAULT_INJECTOR_URL)/fault/fill-disk \
		-H 'Content-Type: application/json' \
		-d '{"pvc":"pvc-filling","mountPath":"/data/filling","targetPercent":92}'
	@echo ""
	@echo "Fill fault injected. Expect PVCFillingUp within ~1m."

demo-readonly:
	curl -sf -X POST $(FAULT_INJECTOR_URL)/fault/read-only \
		-H 'Content-Type: application/json' \
		-d '{"pvc":"pvc-fault","mountPath":"/data/fault"}'
	@echo ""
	@echo "Simulated read-only fault injected. Expect PVCWriteCanaryFailed within ~1m."

demo-io-fault: verify-iochaos
	curl -sf -X DELETE $(FAULT_INJECTOR_URL)/fault/reset/pvc-fault 2>/dev/null || true
	$(KUBECTL) delete -f chaos/iochaos-write-latency.yaml --ignore-not-found
	$(KUBECTL) apply -f chaos/iochaos-write-fault.yaml
	@echo "IOChaos write fault (EIO) applied on /data/fault. Expect PVCWriteCanaryFailed within ~1m."

demo-io-latency:
	curl -sf -X DELETE $(FAULT_INJECTOR_URL)/fault/reset/pvc-fault 2>/dev/null || true
	$(KUBECTL) delete -f chaos/iochaos-write-fault.yaml --ignore-not-found
	$(KUBECTL) apply -f chaos/iochaos-write-latency.yaml
	@echo "IOChaos write latency (2s) applied on /data/fault. Canary writes should still succeed."

demo-io-reset:
	$(KUBECTL) delete -f chaos/iochaos-write-fault.yaml --ignore-not-found
	$(KUBECTL) delete -f chaos/iochaos-write-latency.yaml --ignore-not-found
	@echo "IOChaos experiments removed. Canary should recover on the next write cycle."

demo-inodes:
	curl -sf -X POST $(FAULT_INJECTOR_URL)/fault/inode-flood \
		-H 'Content-Type: application/json' \
		-d '{"pvc":"pvc-fault","mountPath":"/data/fault","targetPercent":86}'
	@echo ""
	@echo "Inode flood injected. Expect PVCInodesExhausted within ~2m."

demo-unbound:
	$(KUBECTL) apply -f monitoring/scenarios/pvc-unbound.yaml
	@echo "Unbound PVC created. Expect PVCNotBound after 2m."

demo-reset: demo-io-reset
	curl -sf -X DELETE $(FAULT_INJECTOR_URL)/fault/reset/pvc-fault 2>/dev/null || true
	curl -sf -X DELETE $(FAULT_INJECTOR_URL)/fault/reset/pvc-filling 2>/dev/null || true
	$(KUBECTL) delete -f monitoring/scenarios/pvc-unbound.yaml --ignore-not-found
	@echo "Faults reset."

status:
	@echo "=== PVCs ==="
	$(KUBECTL) get pvc -n default
	@echo ""
	@echo "=== Monitoring pods ==="
	$(KUBECTL) get pods -n $(HELM_NAMESPACE)
	@echo ""
	@echo "=== Fault injector ==="
	$(KUBECTL) get pods -l app=fault-injector -n default

teardown-remote:
	-$(KUBECTL) delete -f chaos/ --ignore-not-found
	-helm uninstall $(CHAOS_HELM_RELEASE) -n $(CHAOS_HELM_NAMESPACE) $(HELM_KUBE)
	-helm uninstall $(HELM_RELEASE) -n $(HELM_NAMESPACE) $(HELM_KUBE)
	-$(KUBECTL) delete -f monitoring/ --ignore-not-found
	-$(KUBECTL) delete deployment,svc/fault-injector -n $(APP_NAMESPACE) --ignore-not-found
	-sed 's|__APP_NAMESPACE__|$(APP_NAMESPACE)|g' fault-injector/k8s/rbac.yaml | $(KUBECTL) delete -f - --ignore-not-found
	-$(KUBECTL) delete -f monitoring/scenarios/ --ignore-not-found
	-sed -e 's|__STORAGE_CLASS__|$(STORAGE_CLASS)|g' -e 's|__APP_NAMESPACE__|$(APP_NAMESPACE)|g' \
		storage/remote/pvcs.yaml | $(KUBECTL) delete -f - --ignore-not-found

teardown:
	-$(KUBECTL) delete -f chaos/ --ignore-not-found
	-helm uninstall $(CHAOS_HELM_RELEASE) -n $(CHAOS_HELM_NAMESPACE) $(HELM_KUBE)
	-helm uninstall $(HELM_RELEASE) -n $(HELM_NAMESPACE) $(HELM_KUBE)
	-$(KUBECTL) delete -f monitoring/ --ignore-not-found
	-$(KUBECTL) delete deployment,svc/fault-injector -n $(APP_NAMESPACE) --ignore-not-found
	-sed 's|__APP_NAMESPACE__|$(APP_NAMESPACE)|g' fault-injector/k8s/rbac.yaml | $(KUBECTL) delete -f - --ignore-not-found
	-$(KUBECTL) delete -f storage/ --ignore-not-found
	-kind delete cluster --name $(CLUSTER_NAME)
	-rm -rf /tmp/pvc-poc
