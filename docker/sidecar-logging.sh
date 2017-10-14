#!/usr/bin/env bash

# debug on fail
set -euxo pipefail

# logs are sequential in time.
# remove duplicates based on previous log send if present
# stored in ephemeral volume
newSend() {
  echo
  # strategy
  # if (deDupe)
  #   oc logs | grep > /var/log/container-2.log
  #   tail /var/log/container-1.log
  #   echo /var/log/container-1.log /var/log/container-2.log | sort | uniq | gzip | curl
  # else
  #   oc logs | grep | gzip | curl
};

# sends our logs using curl
sendLogs() {
  # first argument is to allow for graceful termination in _term()
  exitSleep=$1
  # we calculate the total processing duration in seconds using bash built-in
  start=${SECONDS}
  # get the datetime for log retrieval. take account of previous duration and sleep
  since=$(date --date="- $(($duration + $exitSleep)) seconds" --rfc-3339=seconds | sed "s/ /T/")
  # debug
  echo "${HOSTNAME}: $(date +''%Y-%m-%d %H:%M:%S:%N'' | sed ''s/\(:[0-9][0-9]\)[0-9]*$/\1/'') duration: $duration since: $since"
  # use openshift client to get logs, gzip them and use curl to send to REST endpoint
  oc logs --since-time $since ${MY_POD_NAME} -c ${CONTAINER_NAME} | grep -P ${GREP_PATTERN} | gzip -c -f | curl -sS --data-binary @- ${LOG_SERVER_URI} -H "Feed:${FEED_NAME_HEADER}" -H "System:${SYSTEM_NAME_HEADER}" -H "Environment:${ENV_NAME_HEADER}" -H "Compression:Gzip";
  # this is equivalent to backgrouding our sleep, so we can interrupt when container halted
  coproc sleep ${SLEEP_TIME}
  wait
  # calculate total processing duration
  duration=$((${SECONDS} - $start));
};

# sig handler for TERM sent by openshift when pod is stopped or deleted
# need to adjust for graceful termination of the container we are getting logs for
_term() {
  echo "Caught SIGTERM signal!"
  sleep 55
  sendLogs 55
  # exit gracefully
  exit 0
}
trap _term SIGTERM

# initial startup delay for container we a getting logs for and ourselves
duration=5;

# we noop and sleep forever if these variables are not set
while [[ "${FEED_NAME_HEADER}" && "${SYSTEM_NAME_HEADER}" && "${ENV_NAME_HEADER}" ]];
  do sendLogs 0
done

sleep infinity