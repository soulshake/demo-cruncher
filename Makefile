.DELETE_ON_ERROR:
SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

.DEFAULT_GOAL := help
# Don't delete .PRECIOUS targets when planning fails
.PRECIOUS: plan-output.txt

# Directories
ROOT := $(shell git rev-parse --show-toplevel)
UTILS = $(ROOT)/bin/utils.sh

###
### Env-specific changes
###

# allow targeting specific resources during plan/apply
TARGET ?=
ifneq ($(TARGET),)
	PLAN_TARGET = -target=$(TARGET)
else
	PLAN_TARGET =
endif

###
### Helpers
###

.PHONY: help
help: ## Displays help for each commented make recipe
	@echo "The following commands are available:"
	# When 'make help` is run, this parses the make recipes and prints the ones meeting the regex below (i.e. without leading dot) and contain a trailing comment starting with ##.
	# h/t @jessfraz: https://github.com/jessfraz/dotfiles/blob/fe9870b99c85e20025616936c9c2e9f18ba9d1f9/Makefile#L97
	x=$$(grep -Eh '^[0-9a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}')
	# bold everything following the last occurrence of ':' on each line
	echo "$${x}" | sed "s/\(.*\):/\1:`tput bold`/" | sed "s/$$/`tput sgr0`/"

.PHONY: whoami
whoami: ## Runs 'aws sts get-caller-identity'
	aws sts get-caller-identity

###
### Environment
###

.PHONY: env
env: ## Emit the values of the environment variables we care about
	@echo "AWS_ACCOUNT_ID=$${AWS_ACCOUNT_ID:-}"
	echo "AWS_REGION=$${AWS_REGION:-}"
	echo "MAKEFILES=$${MAKEFILES:-}"
	echo
	echo "# Needed for running messages.sh; must match the Terraform workspace in ./app:"
	echo "WORKSPACE=$${WORKSPACE:-}"
	echo
	echo "# Needed to run 'docker-compose build' in ./app:"
	echo "REGISTRY_SLASH=$${REGISTRY_SLASH:-}"
	echo "COLON_TAG=$${COLON_TAG:-}" # Should match the value of WORKSPACE above

###
### Terraform
###

TF_MANIFEST_FILES := $(shell find . -maxdepth 1 -type f -name '*.tf')
# The presence of .tf or .tfvars files indicates that make should include
# terraform-specific targets.
ifneq ($(TF_MANIFEST_FILES), )
  TF_CONFIG_DIR = .terraform
else
  TF_CONFIG_DIR =
endif

# Variables
TF_WORKSPACE = $(shell terraform workspace show)
CAREFUL ?= .validate-workspace

# .PHONY: init
# init: | $(TF_CONFIG_DIR)

$(TF_CONFIG_DIR):
	terraform init

.PHONY: plan
plan: $(TF_CONFIG_DIR) tfplan ## Run 'terraform plan'

state.tf:
	@. $(UTILS)
	if [ ! -f "$@" ]; then
		log_notice "state.tf does not exist; checking if we should create a bucket..."
		$(ROOT)/bin/create-state-bucket.sh
	fi

tfplan: $(CAREFUL) | state.tf
	terraform plan -out=tfplan $(PLAN_TARGET) | tee plan-output.txt

.PHONY: plan-destroy
plan-destroy: .validate-workspace ## Make a plan to destroy the current configuration
	@. $(UTILS)
	terraform plan -destroy -out=tfplan | tee plan-output.txt
	log_warning "You've generated a plan to destroy all infrastructure in this configuration. Be sure this is what you want before running 'make apply'."

.PHONY: apply
apply: $(CAREFUL) ## Apply the changes in `tfplan` (i.e. after running 'make plan').
	terraform apply tfplan 2>&1 | tee apply-output.txt

.PHONY: .validate-workspace
.validate-workspace: # Print a big warning if we're on the workspace 'default'
	@if [ "$(TF_WORKSPACE)" = "default" ]; then
		echo "Select a non-default workspace. Your current workspace is '$(TF_WORKSPACE)' (list workspaces with 'terraform workspace list')."
		exit 1
	fi

.PHONY: docs
docs:
	@. $(UTILS)
	for dir in app demo-cluster; do
		log_verbose "terraform-docs markdown $${dir} > $${dir}/README.md"
		terraform-docs markdown $${dir} > $${dir}/README.md
	done

###
### Other
###

.PHONY: nodes-show
nodes-show: ## Show node groups
	kubectl get nodes -o custom-columns-file=$(ROOT)/columns.txt --sort-by 'metadata.labels.eks\.amazonaws\.com\/nodegroup'

.PHONY: asg-list
asg-list: ## List autoscaling groups
	aws autoscaling describe-auto-scaling-groups | jq -r '.AutoScalingGroups[].AutoScalingGroupName' # Tags[] | select(.Key == "Name")'

ASG ?=
.PHONY: asg-activity
asg-activity: ## Show activity for autoscaling group: make asg-activity ASG=<name>
	@[ -z "$(ASG)" ] && echo "Specify an ASG= (view with 'make asg-list')" && exit 1
	echo "Showing autoscaling activity for ASG '$(ASG)'..."
	aws autoscaling describe-scaling-activities --auto-scaling-group-name $(ASG)

###
### Deps
###

OS_NAME := $(shell uname -s | tr A-Z a-z)
ARCH = $(shell uname -m)
ifeq ($(ARCH),x86_64)
  ARCH_NAME = amd64
else
  ARCH_NAME = $(ARCH)
endif
TERRAFORM_VERSION = 1.0.7
TERRAFORM_SOURCE := "https://releases.hashicorp.com/terraform/$(TERRAFORM_VERSION)/terraform_$(TERRAFORM_VERSION)_$(OS_NAME)_$(ARCH_NAME).zip"

.PHONY: deps
deps: /usr/local/bin/terraform

/usr/local/bin/terraform:
	cd /tmp
	curl -sLO $(TERRAFORM_SOURCE)
	sudo unzip "$$(basename $(TERRAFORM_SOURCE))" -d /usr/local/bin/
	/usr/local/bin/terraform -version
