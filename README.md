# Cruncher

This is a simple demo app showing how to implement queue-based batch processing on Kubernetes, and optionally, cluster autoscaling.

It uses AWS EKS and AWS SQS.


## Architecture overview

For each task to execute, a message is posted in the SQS queue.
A custom controller (`queue-watcher`) watches that queue, and receives
these messages. For each message, `queue-watcher` creates a
Kubernetes Job, then deletes the message from the queue.

Then the Kubernetes Job controller kicks in, and run the requested tasks in Pods.
If enough Pods are created, they will fill up the available cluster capacity,
causing new Pods to be in the "Pending" state.
This will then trigger the cluster autoscaler to add more nodes.

Completed Jobs (both successful and failed) are not deleted.
This makes it possible to detect failed jobs and requeue them
(examples will be provided).


## How to run the demo

### Part 1: the setup

Make sure that you have the required dependencies:

- Terraform
- AWS CLI
- `envsubst` (typically found in package `gettext`)
- `jq`

Set the following environment variables:

- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (unless your AWS CLI is already configured)
- `AWS_REGION` (required)
- `AWS_ACCOUNT_ID` (required)

If you don't know your account ID, you can see it with `aws sts get-caller-identity`
(after configuring the AWS CLI, i.e. by setting the access key and secret access key environment variables).

Create the EKS cluster.

```bash
cd cluster
terraform init
terraform apply
aws eks update-kubeconfig --name default --alias default
cd ..
```

Note: this usually takes at least 10-15 minutes to complete.

Note: the name of the cluster (`default` in the example above) corresponds
to the name of the Terraform workspace. If you want to deploy multiple
clusters, you can change the Terraform workspace, and it should deploy
another set of resources. You will also have to set `TF_VAR_cluster` when
running Terraform commands in the `queue` subdirectory.

Create the SQS queue.

```bash
cd queue
terraform init
terraform apply
export QUEUE_URL=$(terraform output -raw queue_url)  # Important! We will use this in other commands below.
cd ..
```

This Terraform configuration creates an SQS queue and an IAM role with
minimally scoped permissions.

Note: the value of the `namespace` variable will be part of the queue
URL, so if you want to create multiple queues, you can do so by setting
the `TF_VAR_namespace` environment variable when running Terraform commands
in the `queue` subdirectory. However, if you do that, you will
need to adjust a few other manifests where that value might be hardcoded.

Now, we need to start the `queue-watcher` controller. Normally, we would
build+push an image with the code of that controller; but to simplify things
a bit, we are going to store the code of the controller in a ConfigMap,
and use an image that has all the dependencies that we need. That way,
we don't have to rely on an external image or a registry.

```bash
kubectl create configmap queue-watcher \
        --from-file=./controller \
        --from-literal=QUEUE_URL=$QUEUE_URL
```

We can now start the `queue-watcher` controller.

```bash
envsubst < controller/queue-watcher.yaml | kubectl apply -f-
```

(We need `envsubst` because that YAML manifest contains references to
`AWS_ACCOUNT_ID` in order to set permissions properly.)


### Part 2: light testing

Put a few messages in the queue:

```bash
aws sqs send-message --queue-url $QUEUE_URL \
    --message-body '{"target": "127.0.0.1", "duration": "10"}'
aws sqs send-message --queue-url $QUEUE_URL \
    --message-body '{"target": "127.0.0.2", "duration": "20"}'
```

Check that jobs and pods are created...
```bash
watch kubectl get jobs,pods
```

...And that the number of messages in the queue goes down.
```bash
aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names All
```

Completed jobs can be removed like this:
```bash
kubectl get jobs
  -o=jsonpath='{.items[?(@.status.conditions[].type=="Complete")].metadata.name}' |
  xargs kubectl delete jobs
```

Note: the `queue-watcher` controller doesn't remove jobs automatically,
so you may want to either patch it to remove completed jobs, or perhaps
set up a CronJob to do it on a regular basis, or whatever suits your needs.


### Part 3: handling job failures

Let's see what happens when we put some messages that will cause jobs to fail.

```bash
aws sqs send-message --queue-url $QUEUE_URL \
    --message-body '{"target": "this.is.invalid", "duration": "10"}'
aws sqs send-message --queue-url $QUEUE_URL \
    --message-body '{"target": "this.is.also.invalid", "duration": "10"}'
```

Look at the job status:

```bash
kubectl get jobs -o custom-columns=NAME:metadata.name,COMMAND:spec.template.spec.containers[0].command,STATUS:status.conditions[0].type
```

At some point, the "invalid" jobs will show a status of `Failed`.

We can list them with the following command:

```bash
kubectl get jobs \
  -o=jsonpath='{.items[?(@.status.conditions[].type=="Failed")].metadata.name}'
```

We can requeue a single failed job like this:

```bash
JOBNAME=demo-...
TASK=$(kubectl get job $JOBNAME -o jsonpath={.metadata.annotations.task})
aws sqs send-message --queue-url $QUEUE_URL --message-body "$TASK"
kubectl delete job $JOBNAME
```

And we can combine the two previous steps to requeue all failed jobs:

```bash
for JOBNAME in $(
  kubectl get jobs \
  -o=jsonpath='{.items[?(@.status.conditions[].type=="Failed")].metadata.name}'
); do
  TASK=$(kubectl get job $JOBNAME -o jsonpath={.metadata.annotations.task})
  aws sqs send-message --queue-url $QUEUE_URL --message-body "$TASK"
  kubectl delete job $JOBNAME
done
```

Note: the `queue-watcher` controller doesn't automatically requeue
jobs, because Kubernetes already retries jobs multiple times.
If a job ends in `Failed` state, it means that it probably requires
some human intervention before retrying it!


### Part 4: cluster autoscaling

Assuming that the cluster is using t3.medium nodes (2 cpu, 4 GB of memory),
and that the job spec requests 0.1 CPU and 100 MB of memory, each node can
accomodate a bit less than 20 pods.

If we create 100 tasks, we should see cluster autoscaling.

```bash
for i in $(seq 100); do
  aws sqs send-message --queue-url $QUEUE_URL \
    --message-body '{"target": "127.0.0.1", "duration": "10"}'
done
```

Check nodes, showing their node group, too:
```bash
watch kubectl get nodes -L eks.amazonaws.com/nodegroup
```

Note: there is one node group per availability zone, and each node
group has a max size of 3, so assuming the default of 3 availability
zones, you may be able to get up to 9 nodes.

You can also view AWS autoscaling activity:

```bash
watch "aws autoscaling describe-scaling-activities --output=table" \
      "--query 'Activities | sort_by(@, &StartTime)[].
              [StartTime,AutoScalingGroupName,Description,StatusCode]'"
```

Normally, you should see a few nodes come up; and after all the
jobs are completed, the nodes will eventually be shutdown.


### Part 5: clean up

Delete the queue:
```bash
cd queue
terraform destroy
cd ..
```

Delete the cluster:
```bash
cd cluster
terraform destroy
cd ..
```

You might need manual cleanup for the following:
- entries in your `~/.kube/config`
- any CloudWatch log groups that have been created automatically


## Miscellanous bits and ends

### SSH access

If you want to be able to connect to nodes with SSH, set `TF_VAR_public_key`
to the desired public key (in OpenSSH format), then plan/apply in the `cluster` directory.

### Availability zones

Node groups are created in the 3 standard AWS availability zones (`abc`) by default. To change this, set your desired AZs like so:

```bash
export TF_VAR_availability_zones='["a", "b"]'
```

Then plan/apply in the `cluster` directory.

Warning: due to particularities of the Terraform Kubernetes provider, changing values that result in cluster replacement (e.g. changing the value of `var.availability_zones`) after the cluster resources have been created will cause errors regarding Helm resources during planning. In this case, do a targeted apply first, like: `terraform apply -target aws_eks_cluster.current`.

### Purging the SQS queue

If you accidentally added a bunch of garbage in the queue and want
to purge it in a pinch:

```bash
aws sqs purge-queue --queue-url $QUEUE_URL
```


## Discussion failed job management

When processing a message queue, it is common to have a "dead letter queue"
where messages end up if they fail to be processed correctly. This gives us
two strategies to manage retries.

1. Leverage SQS native dead letter queue.

In that case, the consumer would receive messages from the queue, and it
*would not* delete messages from the queue. When a message is received from
the queue, it becomes invisible to other consumers for a short period of time
(default is 30 seconds). When the consumer has processed the message, it
deletes the message. If the consumer needs more than 30 seconds to process the
message, it can change the *visibility* of the message (essentially telling
the queue "I need more time to work on this; do not make that message visible
to other consumers yet"). If the consumer fails to change the visibility of the
message, the message becomes visible again, and can be received by another
consumer. If a message is received too many times (FIXME: what's the exact
behavior here?), it eventually gets moved to the dead letter queue, where
it can be inspected to figure out why nobody was able to process it.

The advantage of this method is that it doesn't require to store message
state anywhere else than in SQS. This is well suited to purely stateless
queue consumers.

The downside of this method is that if the messages need a lot of processing
time, the consumers need to regularly update the message visibility.
This requires to either add some logic to the worker code, or run a
"visibility updater" process in parallel to the worker code.

2. Don't leverage SQS native dead letter queue.

In that case, the consumer would receive messages from the queue,
and for each message, it would submit a job to a batch processing
system (in our case, Kubernetes is the batch processing system),
and immediately delete the messages from the queue.
If a message processing fails, the message never ends up in the SQS
dead letter queue; instead, it ends up showing an error state
in our batch processing system. (In our case, that's a Kubernetes
Job with a "Failed" condition.)

The advantage of this method is that the worker code doesn't need
to be aware of SQS and the message visibility timeouts.

The downside of this method is that it requires that our batch
processing system offers durability for jobs; i.e. that when
we submit a job, it won't disappear if it fails, and that we can
store alongside the job enough information to recreate it or
put it back in the queue if it fails.

**Which one is best?**

They both have merits. In a system where Kubernetes is only one
of many consumers for the queue, or where Kubernetes clusters are
considered to be ephemeral, it would be better to leverage the SQS
dead letter queue. In a system that would be "Kubernetes-centric",
or potentially using multiple queues, or trying to be agnostic
to the type of queue used, it would be better to not leverage the
SQS queue.

YMMV.
