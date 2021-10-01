.DELETE_ON_ERROR:
SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

.DEFAULT_GOAL := help

# Directories
ROOT := $(shell git rev-parse --show-toplevel)

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

.PHONY: kubectl-apply
kubectl-apply:
	NAMESPACE=$${WORKSPACE} envsubst '$${AWS_ACCOUNT_ID},$${AWS_REGION},$${NAMESPACE}' < queue-watcher.yaml | kubectl apply -f -

.PHONY: show-env
show-env: ## Emit the values of the environment variables we care about
	@echo "AWS_ACCOUNT_ID=$${AWS_ACCOUNT_ID:-}"
	echo "AWS_REGION=$${AWS_REGION:-}"
	echo
	echo "# Needed for running messages.sh; must match the Terraform workspace in ./app:"
	echo "WORKSPACE=$${WORKSPACE:-}"

.PHONY: docs
docs:
	for dir in app cluster; do
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
	aws autoscaling describe-auto-scaling-groups | jq -r '.AutoScalingGroups[].AutoScalingGroupName'

ASG ?=
.PHONY: asg-activity
asg-activity: ## Show activity for autoscaling group: make asg-activity ASG=<name>
	@[ -z "$(ASG)" ] && echo "Specify an ASG= (view with 'make asg-list')" && exit 1
	echo "Showing autoscaling activity for ASG '$(ASG)'..."
	aws autoscaling describe-scaling-activities --auto-scaling-group-name $(ASG)
