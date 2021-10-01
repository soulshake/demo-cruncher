# Cruncher

This is a simple demo app to demonstrate cluster autoscaling on EKS.

A `queue-watcher` deployment is created, which monitors an SQS queue. When messages appear in the queue, the deployment:

- receives a message from the queue
- creates a Kubernetes job to process it
- deletes the message from the queue

If more resources are needed, the cluster autoscaler kicks in to add more nodes. Failed jobs can be requeued. For details, see below.

## Summary of resources defined in this repo

The `./cluster` directory contains the definitions for an EKS cluster, node group, associated IAM roles/policies, etc. This directory need only be instantiated once.

The `./app` directory contains everything needed to run one instantiation of the "app" on AWS.

Each Terraform workspace corresponds to a dedicated SQS queue and an IAM role with minimally scoped permissions. The `queue-watcher` deployment will run with a service account that assumes this IAM role via the cluster's OIDC provider, allowing it to retrieve messages from the SQS queue.

## Setup

### Dependencies

- Terraform
- AWS CLI
- `envsubst` (typically found in package `gettext`)
- `jq`
- `make` (optional)

### Set environment variables

Run the following commands to retrieve your account ID and region:

```
aws sts get-caller-identity
aws configure get region
```

Ensure the following environment variables are set:

- `AWS_REGION`
- `AWS_ACCOUNT_ID`
- `WORKSPACE=production` (or another value of your choice)

Note: the value of `WORKSPACE` will determine the names of:
- the Kubernetes namespace
- the IAM roles, policies, and queue created in `./app/`

Run `make show-env` to show the current values of these variables.

### Create the cluster

In `./cluster/`:

```
terraform init
terraform workspace new demo                     # note: the cluster will be given the same name as the workspace
terraform apply -target aws_eks_cluster.current
terraform plan
terraform apply
aws eks update-kubeconfig --name demo
```

To be able to connect to nodes, set `TF_VAR_public_key` to the desired public key (in OpenSSH format), then plan/apply.

Node groups are created in the 3 standard AWS availability zones (`abc`) by default. To change this, set your desired AZs like so:

```
export TF_VAR_availability_zones='["a", "b"]'
terraform plan
```

Warning: due to particularities of the Terraform Kubernetes provider, changing values that result in cluster replacement (e.g. changing the value of `var.availability_zones`) after the cluster resources have been created will cause errors regarding Helm resources during planning. In this case, do a targeted apply first, like: `terraform apply -target aws_eks_cluster.current`.

### Instantiate the demo app

In `./app/`:

#### Deploy the AWS resources

```
terraform init
terraform workspace new "${WORKSPACE}"
terraform plan
terraform apply
```

#### Deploy the K8s resources

In the repo root, run:

```
NAMESPACE=${WORKSPACE} envsubst '${AWS_ACCOUNT_ID},${AWS_REGION},${NAMESPACE}' < queue-watcher.yaml | kubectl apply -f -
```

### Interact with the demo app

Update your kube config:

```
kubectl config set-context demo --namespace "${WORKSPACE}"
# ^ WORKSPACE should match the Terraform workspace used in ./app
```

Add some messages to the queue (ensure `AWS_REGION` and `AWS_ACCOUNT_ID` are set):

```
./messages.sh --add 10
```

The values of `TARGET` and `DURATION` environment variables affect the resulting queue messages:


```
TARGET=example.com DURATION=60 ./messages.sh --add 1  # this job will ping example.com for 60 seconds
TARGET=invalid DURATION=10 ./messages.sh --add 1      # this job will fail
```

### Requeue failed jobs

To re-add failed tasks to the queue and delete the failed jobs, run:

```
./requeue-failed.sh
```

This command:
- finds all the jobs in the current namespace which have exceeded their backoff limit
- extracts the original task from an annotation on the failed job
- adds a new queue message for the task
- deletes the failed job

### Reset jobs and queue

To purge the queue and all jobs, run:

```
./messages.sh --purge
```

### Behold the autoscaling

As more messages are added to the queue, new nodes should be created.

To list nodes:

```
make nodes-show
```

To view autoscaling activity:

```
make asg-list
make asg-activity ASG=<id from previous command>
```

## Teardown

To remove all resources:

In the repo root:

```
NAMESPACE=${WORKSPACE} envsubst '${AWS_ACCOUNT_ID},${AWS_REGION},${NAMESPACE}' < queue-watcher.yaml | kubectl delete -f -
```

In `./app/`:

```
terraform destroy
```

In `./cluster/`:

```
terraform destroy
```

Manual cleanup:
- entries in your `~/.kube/config`
- any CloudWatch log groups that have been created automatically
