# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

default: rebuild

# Make will use bash instead of sh
SHELL := /usr/bin/env bash
PROJECT_ID = el-stig-builder
PROJECT_NUMBER = 917800312724
ZONE = us-central1-c
BUILDER_SA = packer@el-stig-builder.iam.gserviceaccount.com
BUCKET = el-stig-builder-artifacts


# create packer builder
#  This has to be done only once per project
.PHONY: builder
builder:
	gcloud config set project ${PROJECT_ID}
	gcloud builds submit --config=packer-cloud-builder/cloudbuild.yaml packer-cloud-builder/

# generate-lockdown-script
.PHONY: generate-lockdown-script
generate-lockdown-script:
	$(eval DATE := $(shell date "+%Y-%m-%d-%H%M%S"))
	$(eval IMAGE_NAME := rhel8-stig-${DATE})
	gcloud config set project ${PROJECT_ID}
	gcloud builds submit --config=generate-lockdown-script/cloudbuild.yaml \
	  --substitutions=_IMAGE_NAME="${IMAGE_NAME}",_PROJECT_ID="${PROJECT_ID}",_ZONE="${ZONE}",_INSTANCE_NAME="lockdown-generate-${DATE}",_BUCKET="${BUCKET}",_PROJECT_NUMBER="${PROJECT_NUMBER}" \
	  generate-lockdown-script/
	@echo "${IMAGE_NAME}" > .last-image-name

# build
.PHONY: build
build:
	$(eval IMAGE_NAME := $(shell cat .last-image-name))
	gcloud config set project ${PROJECT_ID}
	gcloud builds submit --config=build-image/cloudbuild.yaml \
	  --substitutions=_IMAGE_NAME="${IMAGE_NAME}",_PROJECT_ID="${PROJECT_ID}",_ZONE="${ZONE}",_BUILDER_SA="${BUILDER_SA}",_BUCKET="${BUCKET}" \
	  build-image/

# evaluate
.PHONY: evaluate
evaluate:
	$(eval IMAGE_NAME := $(shell cat .last-image-name))
	$(eval DATE := $(shell date "+%Y-%m-%d-%H%M%S"))
	gcloud config set project ${PROJECT_ID}
	gcloud builds submit --config=evaluate-image/cloudbuild.yaml \
	  --substitutions=_IMAGE_NAME="${IMAGE_NAME}",_PROJECT_ID="${PROJECT_ID}",_ZONE="${ZONE}",_PROJECT_NUMBER="${PROJECT_NUMBER}",_INSTANCE_NAME="rhel-eval-${DATE}",_BUCKET="${BUCKET}" \
	  evaluate-image/

# build and evaluate
.PHONY: rebuild
rebuild: generate-lockdown-script build evaluate

# create builder, build, evaluate
.PHONY: all
all: builder generate-lockdown-script build evaluate

