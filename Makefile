.PHONY: all deploy build helm
.ONESHELL: test

SRC = $(shell find . -type f -name '*.go')

ifeq ($(K8S_VERSION),)
K8S_VERSION := v1.22.3
endif


help:   ## show this help
	@echo 'usage: make [target] ...'
	@echo ''
	@echo 'targets:'
	@grep -E '^(.+)\:\ .*##\ (.+)' ${MAKEFILE_LIST} | sort | sed 's/:.*##/#/' | column -t -c 2 -s '#'

build: $(SRC) ## build db-operator docker image
	@docker build -t my-db-operator:v1.0.0-dev .
	@docker save my-db-operator > my-image.tar

helm: ## install helm if not exist and install local chart using helm upgrade --install command
	@helm upgrade --install --create-namespace --namespace operator my-dboperator charts/db-operator -f charts/db-operator/values.yaml -f charts/db-operator/values-local.yaml

helm-lint: ## lint helm manifests
	@helm lint -f charts/db-operator/values.yaml -f charts/db-operator/ci/ci-1.yaml --strict ./charts/db-operator
	@helm lint -f charts/db-instances/values.yaml --strict ./charts/db-instances

addexamples: ## add examples via kubectl create -f examples/
	cd ./examples/; ls | while read line; do kubectl apply -f $$line; done

setup: build helm ## build db-operator image, install helm

deploy:
	@kubectl delete pod -l app=db-operator -n operator &
	watch -n0.2 -c 'kubectl logs -l app=db-operator --all-containers=true -n operator'

update: build deploy ## build db-operator image again and delete running pod

test: $(SRC) ## spin up mysql, postgres containers and run go unit test
	docker-compose down
	docker-compose up -d
	docker-compose restart sqladmin
	sleep 10
	go test -count=1 -tags tests ./... -v -cover
	docker-compose down

lint: $(SRC)
	@go mod tidy
	@gofumpt -l -w $^
	@golangci-lint run ./...

vet: $(SRC)
	@go vet ./...

k3s_mac_lima_create: 
	limactl start --tty=false ./resources/lima/k3s.yaml

k3s_mac_lima_start:
	limactl start k3s

k3s_mac_lima_helm:
	mkdir -p "$${HOME}/.lima/k3s/conf"
	limactl shell k3s sudo cat /etc/rancher/k3s/k3s.yaml >$${HOME}/.lima/k3s/conf/kubeconfig.yaml
	@helm upgrade --install --namespace operator --create-namespace my-dboperator charts/db-operator -f charts/db-operator/values.yaml -f charts/db-operator/values-local.yaml --kubeconfig $${HOME}/.lima/k3s/conf/kubeconfig.yaml
	echo "Don't forget to use k3s docker config \nexport KUBECONFIG=$${HOME}/.lima/k3s/conf/kubeconfig.yaml"

k3s_mac_deploy: build k3s_mac_image k3s_mac_lima_helm

k3s_mac_image:
	limactl copy my-image.tar k3s:/tmp/db.tar
	limactl shell k3s sudo k3s ctr images import /tmp/db.tar
	limactl shell k3s rm -f /tmp/db.tar

k3d_setup: k3d_install k3d_image helm ## create a k3d cluster locally and install db-operator

k3d_install:
	@curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
	@k3d cluster create myk3s -i rancher/k3s:$(K8S_VERSION)-k3s1
	@kubectl get pod

k3d_image: build ## rebuild the docker images and upload into your k3d cluster
	@k3d image import my-image.tar -c myk3s

## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
manifests: controller-gen ## generate custom resource definitions
	$(CONTROLLER_GEN) crd rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	$(CONTROLLER_GEN) crd webhook paths="./..." output:crd:artifacts:config=charts/db-operator/crds

## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
generate: controller-gen ## generate supporting code for custom resource types
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.7.0)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go get $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef
