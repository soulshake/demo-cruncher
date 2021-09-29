## Dependencies

- Terraform
- aws cli
- `terraform-docs` (optional)
- `direnv` (optional)
- `jq`

To install Terraform:

```
make deps
```

To install autocompletion:

```
terraform -install-autocomplete
```

## Other stuff

Configurable:

- `TF_VAR_key_pair_name`
- workspace
- `AWS_REGION`

### Create the AWS resources (IAM roles, policies, ECR repo, etc)

In `./infra`:

```
terraform init
make plan
make apply
```

### Create the cluster

In `./demo-cluster/`:

```
make plan
make apply
```

### Build and push queue-watcher image

In `./app/`:

```
export REGISTRY_SLASH=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
aws ecr get-login-password | docker login --username AWS --password-stdin ${REGISTRY_SLASH}
export COLON_TAG=:production
docker-compose build && docker-compose push
```

### Instantiate the demo app

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
