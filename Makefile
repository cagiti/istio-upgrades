# Environment context lists
eks_local_context=kind-istio-cluster

CS := \033[92m
CE := \033[0m

check_defined = \
        $(strip $(foreach 1,$1, \
        $(call __check_defined,$1,$(strip $(value 2)))))
__check_defined = \
        $(if $(value $1),, \
        $(error Undefined $1$(if $2, ($2))$(if $(value @), \
                required by target `$@')))

# Values
CHART := istio
CLUSTER_NAME := istio-cluster

# Commands and Environment Variables
KIND := kind
DOCKER_CONTENT_TRUST := DOCKER_CONTENT_TRUST=0
KIND_WIH_EXPORTS := $(DOCKER_CONTENT_TRUST) $(KIND)
KIND_CONFIG := kind-config.yaml


eks_env=$(env)

check-context: export target_context="$(eks_$(env)_context)"
check-context:
	@if [ "$(env)" == "" ]; then echo "$(CS)env$(CE) has not been set. Example $(CS)make deploy env=local$(CE)" && exit 1; fi 
	@if [ "$(target_context)" == "" ]; then echo "$(CS)eks_<env>_context$(CE) variable needs to be specified in the parent Makefile." && exit 2; fi
	@if [ "$(shell kubectl config view -o json --minify 2>/dev/null | jq -r '.contexts[].context.cluster')" != "$(target_context)" ]; then \
		echo "Current context is not pointing to $(CS)$(target_context)$(CE). Please change your kube context to target the correct cluster." && exit 3; \
	else \
		echo "Currently connected to $(CS)$(target_context)$(CE) in the $(CS)$(env)$(CE) environment"; \
	fi

set-helm-version:
	@asdf local helm 2.17.0

kind-cluster:
	@if [ $(shell $(KIND) get clusters | grep -c $(CLUSTER_NAME)) -eq 0 ]; then \
		$(KIND_WIH_EXPORTS) create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG); \
		kubectl create namespace istio-system; \
		kubectl apply -f ./kiali.yaml -n istio-system; \
	fi

rm-kind-cluster:
	@if [ $(shell $(KIND) get clusters | grep -c $(CLUSTER_NAME)) -eq 1 ]; then \
		$(KIND) delete cluster --name $(CLUSTER_NAME); \
	fi

install-bookinfo: export env=local
install-bookinfo: check-context
	kubectl label namespace default istio-injection=enabled --overwrite; \
	kubectl apply -f bookinfo/bookinfo.yaml -n default; \
	kubectl -n default wait --for=condition=available --timeout=240s deployment --all; \
	kubectl -n default wait --for=condition=initialized --timeout=120s pod --all; \
	kubectl -n default wait --for=condition=ready --timeout=120s pod --all; \
	kubectl apply -f bookinfo/networking/bookinfo-gateway.yaml -n default; \
	until $$(curl -s -o /dev/null --head --fail "http://127.0.0.1/productpage"); do \
		printf "."; \
		sleep 2; \
	done; \
	./istio/1.3.3/istioctl ps

install-istio-1.3.3: export env=local
install-istio-1.3.3: kind-cluster set-helm-version check-context
	kubectl apply -f istio/1.3.3/helm-service-account.yaml; \
	helm init --wait --service-account tiller; \
	helm repo add istio.io https://storage.googleapis.com/istio-release/releases/1.3.3/charts/; \
	helm install istio/1.3.3/istio-init --name istio-init --namespace istio-system; \
	kubectl -n istio-system wait --for=condition=complete job --all; \
	kubectl -n istio-system wait --for condition=established --timeout=60s crd/virtualservices.networking.istio.io; \
	kubectl get crds | grep 'istio.io' | wc -l; \
	helm install istio/1.3.3/istio --name istio --namespace istio-system --set grafana.enabled=true --set global.tracer.zipkin.address=jaeger-collector.observability:9411 --set kiali.enabled=true --set "kiali.dashboard.jaegerURL=http://jaeger-query.observability:16686" --set "kiali.dashboard.grafanaURL=http://grafana:3000"; \
	mkdir -p istio/1.3.3; \
	curl -sL https://github.com/istio/istio/releases/download/1.3.3/istio-1.3.3-osx.tar.gz | tar zxv --strip-components=2 -C istio/1.3.3 istio-1.3.3/bin/istioctl; \
	kubectl -n istio-system wait --for=condition=available --timeout=120s deployment --all; \
	./istio/1.3.3/istioctl ps

setup: export env=local
setup: install-istio-1.3.3 install-bookinfo
	./istio/1.3.3/istioctl version

upgrade-to-istio-1.4.10: export env=local
upgrade-to-istio-1.4.10: check-context
	helm upgrade --install istio-init istio/1.4.10/istio-init --namespace istio-system; \
	kubectl -n istio-system wait --for=condition=complete job --all; \
	helm upgrade --install istio istio/1.4.10/istio --namespace istio-system --set grafana.enabled=true --set global.tracer.zipkin.address=jaeger-collector.observability:9411 --set kiali.enabled=true --set "kiali.dashboard.jaegerURL=http://jaeger-query.observability:16686" --set "kiali.dashboard.grafanaURL=http://grafana:3000"; \
	mkdir -p istio/1.4.10; \
	curl -sL https://github.com/istio/istio/releases/download/1.4.10/istio-1.4.10-osx.tar.gz | tar zxv --strip-components=2 -C istio/1.4.10 istio-1.4.10/bin/istioctl; \
	kubectl rollout restart deployment --namespace default; \
	./istio/1.4.10/istioctl ps; \
	./istio/1.4.10/istioctl version

generate-istio-1.6.13-operator-cr: export env=local
generate-istio-1.6.13-operator-cr: check-context
	helm get values istio > istio-1.4.10.yaml; \
	./istio/1.6.13/istioctl manifest migrate istio-1.4.10.yaml > iop.yaml; \
	./istio/1.6.13/istioctl operator init; \
	echo "You may need to add a name to the IstioOperator crd manifest iop.yaml"

upgrade-to-istio-1.6.13: export env=local
upgrade-to-istio-1.6.13: check-context
	kubectl patch deployment istio-galley -n istio-system --type "json" -p '[{"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"--enable-validation=false"}]'; \
	kubectl delete validatingwebhookconfigurations.admissionregistration.k8s.io istio-galley -n istio-system 2>/dev/null || true ; \
	mkdir -p istio/1.6.13; \
	curl -sL https://github.com/istio/istio/releases/download/1.6.13/istio-1.6.13-osx.tar.gz | tar zxv --strip-components=2 -C istio/1.6.13 istio-1.6.13/bin/istioctl; \
	./istio/1.6.13/istioctl operator init; \
	kubectl -n istio-system wait --for condition=established --timeout=60s crd/istiooperators.install.istio.io; \
	kubectl apply -f istiocontrolplane-1-6-13.yaml; \
	kubectl label namespace default istio-injection- istio.io/rev=1-6-13; \
	kubectl -n istio-system scale deployment/istio-citadel --replicas=0; \
	kubectl -n istio-system scale deployment/istio-galley --replicas=0; \
	kubectl -n istio-system scale deployment/istio-pilot --replicas=0; \
	kubectl -n istio-system scale deployment/istio-policy --replicas=0; \
	kubectl -n istio-system scale deployment/istio-sidecar-injector --replicas=0; \
	kubectl -n istio-system scale deployment/istio-telemetry --replicas=0; \
	kubectl -n istio-system scale deployment/grafana --replicas=0; \
	kubectl -n istio-system scale deployment/kiali --replicas=0; \
	kubectl -n istio-system scale deployment/prometheus --replicas=0; \
	kubectl apply -f istiocontrolplane-1-6-13-addons.yaml; \
	kubectl rollout restart deployment --namespace default; \
	kubectl -n istio-system wait --for=condition=available --timeout=240s deployment --all; \
	kubectl -n default wait --for=condition=available --timeout=240s deployment --all; \
	kubectl -n default wait --for=condition=ready --timeout=240s pod --all; \
	kubectl -n istio-system patch service istio-ingressgateway --type='json' -p '[{"op":"replace","path":"/spec/ports/1/nodePort","value":31380},{"op":"replace","path":"/spec/ports/2/nodePort","value":31390}]'; \
	./istio/1.6.13/istioctl version
