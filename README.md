# Cruncher

This is a simple demo app to demonstrate cluster autoscaling on EKS.

A `queue-watcher` deployment is created, which monitors an SQS queue. When messages appear in the queue, the deployment creates enough Kubernetes jobs to handle each message.

Each job pops a message from the queue, processes it, and deletes it.

If more resources are needed, the cluster autoscaler kicks in to add more nodes.

## Setup

### Dependencies

- Terraform
- AWS CLI
- `jq`
- `make`

To install Terraform:

```
make deps
```

### Set environment variables

Run the following commands to retrieve your account ID and region:

```
aws sts get-caller-identity
aws configure get region
```

Ensure the following environment variables are set:

- `AWS_REGION`
- `AWS_ACCOUNT_ID`
- `MAKEFILES=../Makefile` (to be able to run make in subdirectories)
- `WORKSPACE=production` (or another value of your choice)

Run `make env` to show the current values of these variables.

### Create the cluster

In `./demo-cluster/`:

```
terraform init
terraform workspace select demo-cluster
make plan
make apply
```

To be able to connect to nodes, set `TF_VAR_public_key` to the desired public key (in OpenSSH format), then plan/apply.

### Instantiate the demo app

In `./app/`:

#### Build and push queue-watcher image

```
export REGISTRY_SLASH=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
export COLON_TAG=:${WORKSPACE}
aws ecr get-login-password | docker login --username AWS --password-stdin ${REGISTRY_SLASH}
docker-compose build && docker-compose push
```

#### Deploy

```
terraform init
terraform workspace new ${WORKSPACE}
make plan
make apply
```

### Interact with the demo app

Update your kube config:

```
aws eks update-kubeconfig --name demo
kubectl config set-context demo --namespace demo-${WORKSPACE}
# ^ WORKSPACE should match the Terraform workspace in ./app
```

Add some messages to the queue (ensure `AWS_REGION` and `AWS_ACCOUNT_ID` are set):

```
./messages.sh --add 1
```

or:
```
export QUEUE_URL=$(terraform -chdir=app output -json | jq -r .queue_url.value)
aws sqs send-message --queue-url "${QUEUE_URL}" --message-body '{ "target": "goo.gl", "duration": "1"}'
```
