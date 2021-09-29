## Dependencies

- Terraform
- aws cli
- `notify-send` (optional)
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

In `./infra`:

```
terraform init
make plan
make apply
```

In `./demo-cluster/`:

```
make plan
make apply
```

In `./app/`:

```
aws ecr get-login-password | docker login --username AWS --password-stdin 731288958074.dkr.ecr.eu-central-1.amazonaws.com
export REGISTRY_SLASH=731288958074.dkr.ecr.eu-central-1.amazonaws.com/
export COLON_TAG=:production
docker-compose build && docker-compose push
```

Update your kube config:

```
aws eks update-kubeconfig --name demo
kubectl config set-context demo --namespace demo-production
```

Add some messages to the queue:

```
export QUEUE_URL=https://sqs.eu-central-1.amazonaws.com/731288958074/demo-production
./messages.sh --add 1
```

or:
```
export QUEUE_URL=$(terraform -chdir=app output -json | jq -r .queue_url.value)
aws sqs send-message --queue-url https://sqs.eu-central-1.amazonaws.com/731288958074/demo-production --message-body '{ "target": "goo.gl", "duration": "1"}'
```
