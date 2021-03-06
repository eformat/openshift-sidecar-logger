# OpenShift Sidecar Logger

## Scenario

Use sidecar container pattern to send a container's logs to an external REST service on OpenShift.

https://kubernetes.io/docs/concepts/cluster-administration/logging/#streaming-sidecar-container

External service supports:

* batch only (continous stream not supported)
* logs gzipped
* support basic filtering prior to sending

Configurable Constraints:

* Some duplicate log entries may be sent (using `oc log --since-time` is used for batch log collection) which is accurate to `seconds` only.
* The sidecar collects logs approximately every `sleep_time` seconds. There is some variable amount of time based on processing time and actual sidecar sleep time that is factored into log collection time.

Features:

* Takes into account sending time in seconds to minimise duplicate log entries
* SIGTERM is handled to take into account `terminationGracePeriodSeconds` which defaults to 60 seconds. Graceful termination and startup requires more fine tuning.

## Usage

#### Build sidecar container

The logging sidecar is:

* small footprint (memory, cpu)
* based on a supported image
* simple to configure

Build the `logging-sidecar` image so it can be shared in the `openshift` namespace. Requires a user with `edit` permission on the `openshift` namespace.

```
oc new-build -n openshift --name=logging-sidecar --strategy=docker --context-dir=docker https://github.com/eformat/openshift-sidecar-logger
```

#### Configuration

A `ConfigMap` is used to configure the sidecar logging container.

Parameter            | Description             | Example Value
-------------------- | ----------------------- | ------------- 
`container_name` | Name of the container to retrieve logs from | 'count'
`grep_pattern` | Filter logs from `container_name` using PCRE Pattern to pass to `grep` (see man grep -P) | 'Y\w+\s+F\w+$'
`sleep_time` | Time for logging sidecar to sleep (seconds). Send a batch approximately every `sleep_time` seconds | '60'
`log_server_uri` | Batch log collection server URI | 'http://localhost:8080/datafeed'
`feed_name_header` | Feed Name Header value| 'CSV_FEED'
`system_name_header` | System Name Header value | 'EXAMPLE_SYSTEM'
`env_name_header` | Environment Name Header value | 'EXAMPLE_ENVIRONMENT'
`dedupe` | Remove duplicate log line entries | 'true'
`graceful_exit_time` | Time for container (set by `container_name`) to gracefully exit (seconds) | '55'
`startup_time` | Estimated time for logging sidecar container to start (seconds) | '15'

If any `one` of the following `ConfigMap` entries are unset, the sidecar logger performs a noop:

```
  feed_name_header: ''
  system_name_header: ''
  env_name_header: ''
```

Set the environment variable `DEBUG=true` to see verbose debug in sidecar logger.

#### Journald

Since OpensShift containers uses rthe docker -> journald driver, you may need to configure the journald subsystem on your nodes so as not to miss log messages at higher rates (>33/s)

By default systemd allows 1,000 messages within a 30 second period.

The limits are controlled in the `/etc/systemd/journald.conf` file.

```
RateLimitInterval=30s
RateLimitBurst=1000
```

Change these then restart journald

```
systemctl restart systemd-journald
```

You will see mesasges such as this if you need to allow more messages:

```
Oct 11 02:37:40 node06 journal: Suppressed 17 messages from /system.slice/docker.service
Oct 11 02:48:40 node06 journal: Suppressed 1342 messages from /system.slice/docker.service
Oct 11 02:49:10 node06 journal: Suppressed 1237 messages from /system.slice/docker.service
```

It can be tested with:

```
seq 1 3000 | logger
```

#### Create example project

As a normal user:

```
oc new-project logging-sidecar-example --display-name="Logging Sidecar Example" --description="Logging Sidecar Example"
```

#### Create example application from template

`TBD`

#### Create example application by hand

Allow the namespace `default` system account view access (this is so the `oc` command in the sidecar can read container logs)

```
oc policy add-role-to-user view system:serviceaccount:$(oc project -q):default
```

Create the `configmap` that configures the sidecar container:

```
oc apply -f config-map.yml
```

Create the `deploymentconfig` for the example application pod:

```
oc apply -f deployment-config.yml
```

#### Rollout a new configuration

Update the `ConfigMap` and redeploy the example pod

```
oc apply -f config-map.yml
oc rollout latest counter
```

#### Testing

Setup the `ConfigMap` to point to your collection REST endpoint `log_server_uri`.

The example uses `YOLO FOOBAR` as the string we filter against using the PCRE `grep_pattern:` `Y\w+\s+F\w+$`

In the example pod, the `count` container logs once a second.

```
oc logs -c count $(oc get pods --show-all=false -lapp=counter --template='{{range .items}}{{.metadata.name}}{{end}}') -f
```

The `logging-sidecar` sidecar collects `count` container logs, create a GZIP batch and forwards to the log server endpoint.

The REST call time to send GZIP'ed logs to the log server endpoint is logged to STDOUT, any errors will also be reported here:

```
oc logs -c logging-sidecar $(oc get pods --show-all=false -lapp=counter --template='{{range .items}}{{.metadata.name}}{{end}}') -f
```
