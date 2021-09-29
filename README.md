## Setup

### Dependencies

- Terraform
- aws cli
- `jq`

To install Terraform:

```
make deps
```

### Set environment variables

Ensure the following environment variables are set:

- `AWS_REGION`
- `AWS_ACCOUNT_ID`
- `MAKEFILES=../Makefile` # to be able to run make in subdirectories

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
export COLON_TAG=:production
aws ecr get-login-password | docker login --username AWS --password-stdin ${REGISTRY_SLASH}
docker-compose build && docker-compose push
```

#### Deploy

```
terraform init
terraform workspace select production
make plan
make apply
```

### Interact with the demo app

Update your kube config:

```
aws eks update-kubeconfig --name demo
kubectl config set-context demo --namespace demo-production
```

Add some messages to the queue:

```
export QUEUE_URL=https://sqs.${AWS_REGION}.amazonaws.com/${AWS_ACCOUNT_ID}/demo-production
./messages.sh --add 1
```

or:
```
export QUEUE_URL=$(terraform -chdir=app output -json | jq -r .queue_url.value)
aws sqs send-message --queue-url https://sqs.eu-central-1.amazonaws.com/731288958074/demo-production --message-body '{ "target": "goo.gl", "duration": "1"}'
```
