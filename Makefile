.DELETE_ON_ERROR:
SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

.DEFAULT_GOAL := hello
# Don't delete .PRECIOUS targets when planning fails
.PRECIOUS: plan-output.txt

# Include all .mk files in repo root
include $(wildcard $(shell git rev-parse --show-toplevel)/*.mk)

# Variables
SERVICE_NAME ?= $(shell basename $(CURDIR))
ifeq ($(SERVICE_NAME), infra)
    # We're being run in repo root
	SERVICE_NAME = "no particular service"
endif
TF_WORKSPACE = $(shell terraform workspace show)
CAREFUL ?= .validate-workspace
VERY_CAREFUL = $(CAREFUL) .validate-workspace-strict

# Directories
ROOT := $(shell git rev-parse --show-toplevel)
UTILS = $(ROOT)/bin/utils.sh

###
### Env-specific changes
###

# If notify-send is installed, send desktop notifications after plan/apply operations.
NOTIFY = $(shell which notify-send)
ifeq ($(NOTIFY),)
	NOTIFY = $$(which echo)
	URGENCY =
else
	NOTIFY += --expire-time 3000
	URGENCY = -u low
endif

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

.PHONY: hello
hello: ## Shows very basic options
	@. $(UTILS)
	echo "Greetings, human. 👋"
	echo -e "You are hacking on $${green}$${underline}$${bold}$(SERVICE_NAME)$${reset} in workspace $${underline}$${bold}$(TF_WORKSPACE)$${reset}"
	echo
	echo "Would you like to:"
	echo "	make plan	- plan your demise"
	echo "	make apply	- dance with the devil in the pale moonlight"
	echo "	make help	- show all commands"

.PHONY: help
help: ## Displays help for each commented make recipe
	@echo "The following commands are available:"
	echo
	echo "[info]"
	echo "	make whoami-aws - show aws caller identity"
	echo
	echo "[terraform]"
	echo "	make plan - show changes required by the current configuration"
	echo "	make plan-destroy - make a plan to destroy the current configuration"
	echo "	make apply - create, update or destroy infrastructure"
	echo
	echo "[teardown]"
	echo "	make clean - remove Terraform plan files"
	echo
	echo "Notes:"
	echo
	echo "To print debug output simultaneously to a file, run:"
	echo " make plan-debug"
	echo " make apply-debug"
	echo
	echo "See also:"
	# When 'make help` is run, this parses the make recipes and prints the ones meeting the regex below (i.e. without leading dot) and contain a trailing comment starting with ##.
	# h/t @jessfraz: https://github.com/jessfraz/dotfiles/blob/fe9870b99c85e20025616936c9c2e9f18ba9d1f9/Makefile#L97
	x=$$(grep -Eh '^[0-9a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}')
	# bold everything following the last occurrence of ':' on each line
	echo "$${x}" | sed "s/\(.*\):/\1:`tput bold`/" | sed "s/$$/`tput sgr0`/"

.PHONY: docs
docs:
	@. $(UTILS)
	for dir in app demo-cluster infra; do
		log_verbose "terraform-docs markdown $${dir} > $${dir}/README.md"
		terraform-docs markdown $${dir} > $${dir}/README.md
	done

.PHONY: whoami
whoami: ## Runs 'aws sts get-caller-identity'
	aws sts get-caller-identity

.PHONY: .validate-workspace
.validate-workspace: # Print a big warning if we're on the workspace 'default'
	@. $(UTILS)
	if [[ "$(TF_WORKSPACE)" == "default" ]]; then
		log_error "Select a non-default workspace. Your current workspace is '$(TF_WORKSPACE)'"
	fi

.PHONY: .validate-workspace-strict
.validate-workspace-strict: # Exit if we're on the workspace 'default'
	@. $(UTILS)
	if [ "$(TF_WORKSPACE)" = "default" ]; then
		log_error "Select a non-default workspace. Your current workspace is '$(TF_WORKSPACE)'"
		exit 1
	fi

###
### Terraform
###

.PHONY: plan
plan: tfplan ## Run 'terraform plan'

.PHONY: plan-debug
plan-debug: ## Run 'terraform plan' and write debug logs to debug.txt
	@. $(UTILS)
	log_notice "Debug logs will be written to debug.txt."
	TF_LOG=trace make plan 2>&1 | tee debug.txt


state.tf:
	@. $(UTILS)
	if [ ! -f "$@" ]; then
		log_notice "state.tf does not exist; checking if we should create a bucket..."
		$(ROOT)/bin/create-state-bucket.sh
	fi

tfplan plan-output.txt &: .validate-workspace-strict $(DATA_FILES) $(CAREFUL) $(MANIFEST_FILES) $(TF_WORKSPACE_FILE) | $(TF_CONFIG_DIR) state.tf
	@. $(UTILS)
	log_notice "Generating tfplan and plan-output.txt..."
	if terraform plan -out=tfplan $(PLAN_TARGET) | tee plan-output.txt; then
		ret=$$?
		$(NOTIFY) $(URGENCY) "Done!" "Planning finished: $$(basename $${PWD})"
	else
		ret=$$?
		[ -n "$(URGENCY)" ] && URGENCY="-u critical"
		$(NOTIFY) $${URGENCY:-} "Error!" "Planning failed: $$(basename $${PWD})"
	fi
	exit $$ret

tfplan.json: tfplan
# Note: $< is the name of the first prerequisite.
	@. $(UTILS)
	log_notice "Generating tfplan.json... "
	terraform show -no-color -json $< | jq . > $@

.PHONY: apply
apply: $(VERY_CAREFUL) ## Apply the changes in `tfplan` (i.e. after running 'make plan').
	@. $(UTILS)
	if [ ! -f "tfplan" ]; then
		log_error "No tfplan exists. Run 'make plan' to generate it and try again."
		exit 1
	fi
	if terraform apply tfplan 2>&1 | tee apply-output.txt; then
		ret=$$?
		$(NOTIFY) $(URGENCY) "Done!" "[apply] Your bidding has been done: $$(basename $${PWD})"
	else
		ret=$$?
		[ -n "$(URGENCY)" ] && URGENCY="-u critical"
		$(NOTIFY) $${URGENCY} "Error!" "Apply failed (code $$ret): $$(basename $${PWD})"
	fi
	exit $$ret

.PHONY: apply-debug
apply-debug:
	@. $(UTILS)
	log_notice "Debug logs will be written to debug.txt."
	TF_LOG=trace make apply 2>&1 | tee debug.txt

.PHONY: nodes-show
nodes-show: ## Show node groups
	kubectl get nodes -o custom-columns-file=$(ROOT)/columns.txt --sort-by 'metadata.labels.eks\.amazonaws\.com\/nodegroup'

.PHONY: asg-list
asg-list: ## List autoscaling groups
	aws autoscaling describe-auto-scaling-groups | jq -r '.AutoScalingGroups[].AutoScalingGroupName' # Tags[] | select(.Key == "Name")'

asg ?=
.PHONY: asg-activity
asg-activity: ## Show activity for autoscaling group asg=
	@. $(UTILS)
	log_verbose "Showing autoscaling activity for ASG '$(asg)'..."
	if [ -n "$(asg)" ]; then
	  aws autoscaling describe-scaling-activities --auto-scaling-group-name $(asg)
	else
	  log_warning "Specify an asg="
	fi
