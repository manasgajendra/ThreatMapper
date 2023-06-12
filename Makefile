PWD=$(shell pwd)

DEEPFENCE_AGENT_DIR=$(PWD)/deepfence_agent
DEEPFENCE_ROUTER_DIR=$(PWD)/haproxy
DEEPFENCE_FILE_SERVER_DIR=$(PWD)/deepfence_file_server
DEEPFENCE_FRONTEND_DIR=$(PWD)/deepfence_frontend
SECRET_SCANNER_DIR=$(DEEPFENCE_AGENT_DIR)/plugins/SecretScanner
MALWARE_SCANNER_DIR=$(DEEPFENCE_AGENT_DIR)/plugins/YaraHunter/
PACKAGE_SCANNER_DIR=$(DEEPFENCE_AGENT_DIR)/plugins/package-scanner
DEEPFENCE_CTL=$(PWD)/deepfence_ctl
IMAGE_REPOSITORY?=deepfenceio
DF_IMG_TAG?=latest
IS_DEV_BUILD?=false
VERSION?="2.0.0"

default: bootstrap console_plugins agent console

.PHONY: console_plugins agent console
console: redis postgres kafka-broker router server worker ui console_plugins file-server graphdb

console_plugins: secretscanner malwarescanner packagescanner

.PHONY: bootstrap
bootstrap:
	./bootstrap.sh

.PHONY: bootstrap-agent-plugins
bootstrap-agent-plugins:
	(cd $(DEEPFENCE_AGENT_DIR)/plugins && bash bootstrap.sh)
	(cd $(SECRET_SCANNER_DIR) && bash bootstrap.sh)
	(cd $(MALWARE_SCANNER_DIR) && bash bootstrap.sh)

.PHONY: agent
agent:
	(cd $(DEEPFENCE_AGENT_DIR) &&\
	IMAGE_REPOSITORY="$(IMAGE_REPOSITORY)" DF_IMG_TAG="$(DF_IMG_TAG)" bash build.sh)

.PHONY: deepfenced
deepfenced:
	(cd ./deepfence_bootstrapper && make)
	cp ./deepfence_bootstrapper/deepfence_bootstrapper ./deepfence_agent

.PHONY: redis
redis:
	docker build --tag=$(IMAGE_REPOSITORY)/deepfence_redis_ce:$(DF_IMG_TAG) -f deepfence_redis/redis-Dockerfile ./deepfence_redis

.PHONY: postgres
postgres:
	docker build --tag=$(IMAGE_REPOSITORY)/deepfence_postgres_ce:$(DF_IMG_TAG) -f deepfence_postgres/Dockerfile ./deepfence_postgres

.PHONY: kafka-broker
kafka-broker:
	docker build -t $(IMAGE_REPOSITORY)/deepfence_kafka_broker_ce:$(DF_IMG_TAG) -f ./deepfence_kafka/kafka-broker-Dockerfile ./deepfence_kafka

.PHONY: router
router:
	docker build --build-arg is_dev_build=$(IS_DEV_BUILD) -t $(IMAGE_REPOSITORY)/deepfence_router_ce:$(DF_IMG_TAG) $(DEEPFENCE_ROUTER_DIR)

.PHONY: file-server
file-server:
	docker build -t $(IMAGE_REPOSITORY)/deepfence_file_server_ce:$(DF_IMG_TAG) $(DEEPFENCE_FILE_SERVER_DIR)

.PHONY: server
server:
	(cd ./deepfence_server && make vendor)
	docker build -f ./deepfence_server/Dockerfile -t $(IMAGE_REPOSITORY)/deepfence_server_ce:$(DF_IMG_TAG) .

.PHONY: worker
worker:
	(cd ./deepfence_worker && make vendor)
	docker build -f ./deepfence_worker/Dockerfile --build-arg IMAGE_REPOSITORY=$(IMAGE_REPOSITORY) --build-arg DF_IMG_TAG=$(DF_IMG_TAG) -t $(IMAGE_REPOSITORY)/deepfence_worker_ce:$(DF_IMG_TAG) .

.PHONY: graphdb
graphdb:
	docker build -f ./deepfence_neo4j/Dockerfile --build-arg IMAGE_REPOSITORY=$(IMAGE_REPOSITORY) --build-arg DF_IMG_TAG=$(DF_IMG_TAG) -t $(IMAGE_REPOSITORY)/deepfence_neo4j_ce:$(DF_IMG_TAG) .

.PHONY: ui
ui:
	git log --format="%h" -n 1 > $(DEEPFENCE_FRONTEND_DIR)/console_version.txt && \
	echo $(VERSION) > $(DEEPFENCE_FRONTEND_DIR)/product_version.txt && \
	docker run -it --rm --entrypoint=bash -v $(DEEPFENCE_FRONTEND_DIR):/app node:18-bullseye-slim -c "cd /app && corepack enable && corepack prepare pnpm@7.17.1 --activate && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=true pnpm install --frozen-lockfile --prefer-offline && pnpm run build" && \
	docker build -f $(DEEPFENCE_FRONTEND_DIR)/Dockerfile -t $(IMAGE_REPOSITORY)/deepfence_ui_ce:$(DF_IMG_TAG) $(DEEPFENCE_FRONTEND_DIR) && \
	rm -rf $(DEEPFENCE_FRONTEND_DIR)/console_version.txt $(DEEPFENCE_FRONTEND_DIR)/product_version.txt

.PHONY: secretscanner
secretscanner: bootstrap-agent-plugins
	docker build --tag=$(IMAGE_REPOSITORY)/deepfence_secret_scanner_ce:$(DF_IMG_TAG) -f $(SECRET_SCANNER_DIR)/Dockerfile $(SECRET_SCANNER_DIR)

.PHONY: malwarescanner
malwarescanner: bootstrap-agent-plugins
	docker build --tag=$(IMAGE_REPOSITORY)/deepfence_malware_scanner_ce:$(DF_IMG_TAG) -f $(MALWARE_SCANNER_DIR)/Dockerfile $(MALWARE_SCANNER_DIR)

.PHONY: packagescanner
packagescanner:
	(cd $(PACKAGE_SCANNER_DIR) && make tools)
	docker build --tag=$(IMAGE_REPOSITORY)/deepfence_package_scanner_ce:$(DF_IMG_TAG) -f $(PACKAGE_SCANNER_DIR)/Dockerfile $(PACKAGE_SCANNER_DIR)

.PHONY: openapi
openapi: server
	docker run --rm -it \
	--entrypoint=/usr/local/bin/deepfence_server \
	-v $(PWD):/app $(IMAGE_REPOSITORY)/deepfence_server_ce:$(DF_IMG_TAG) \
	--export-api-docs-path /app/openapi.yaml

	rm -rf golang_deepfence_sdk/client/*

	docker pull openapitools/openapi-generator-cli:latest
	docker run --rm \
	-v $(PWD):/local openapitools/openapi-generator-cli:latest generate \
	-i /local/openapi.yaml \
	-g go \
	-o /local/golang_deepfence_sdk/client \
	-p isGoSubmodule=true \
	-p packageName=client \
	--git-repo-id golang_deepfence_sdk \
	--git-user-id deepfence

	rm openapi.yaml
	cd $(PWD)/golang_deepfence_sdk/client && rm -rf ./test && sed -i 's/go 1.13/go 1.19/g' go.mod && go mod tidy -v && cd -

.PHONY: cli
cli:
	(cd $(DEEPFENCE_CTL) && make clean && make all)

.PHONY: discovery
discovery:
	cd $(DEEPFENCE_AGENT_DIR)/tools/apache/scope &&\
	make realclean && go mod vendor && make scope.tar
	docker tag weaveworks/scope $(IMAGE_REPOSITORY)/deepfence_discovery_ce:$(DF_IMG_TAG)

.PHONY: publish
publish:
	docker push $(IMAGE_REPOSITORY)/deepfence_redis_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_postgres_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_kafka_broker_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_router_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_file_server_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_server_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_worker_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_ui_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_agent_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_discovery_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_package_scanner_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_malware_scanner_ce:$(DF_IMG_TAG)
	docker push $(IMAGE_REPOSITORY)/deepfence_secret_scanner_ce:$(DF_IMG_TAG)
