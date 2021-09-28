Configurable:

- `TF_VAR_key_pair_name`
- workspace
- `AWS_REGION`

In `./infra`:

```
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


Add some messages to the queue:

```
export QUEUE_URL=https://sqs.eu-central-1.amazonaws.com/731288958074/demo-$(terraform workspace show)
export MSG='{ "target": "goo.gl", "duration": "30" }'
aws sqs send-message --queue-url "${QUEUE_URL}" --message-body "${MSG}"
```
