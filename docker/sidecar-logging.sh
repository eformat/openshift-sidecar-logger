#!/usr/bin/env bash

# debug on fail
set -euo pipefail

#
# TTD - check args
#
# ${SLEEP_TIME} >= 5 sec <= 3600 min ??
# check HEADERS
#

# filtered openshift logs for container
oc_logs='oc logs --since-time $since ${MY_POD_NAME} -c ${CONTAINER_NAME} | grep -P ${GREP_PATTERN}'
# send zipped to endpoint
gzip_curl='gzip -c -f | curl -sS --data-binary @- ${LOG_SERVER_URI} -H "Feed:${FEED_NAME_HEADER}" -H "System:${SYSTEM_NAME_HEADER}" -H "Environment:${ENV_NAME_HEADER}" -H "Compression:Gzip"'

_send() {
  if [ ! "x${DEDUPE}" = xtrue ]; then
    # do not handle duplicates
    eval $oc_logs | eval $gzip_curl;
    return
  fi

  # removes duplicates
  (
    # wait for exclusive lock (fd 200) for 2 seconds
    flock -x -w 2 200

    # stores logs temporarily, rotating two files
    file1=/tmp/001.dat
    file2=/tmp/002.dat

    # grep (-v) select non-matching lines, (-x) that match whole lines, (-f) get patterns from files
    if [[ ! -f "$file1" && ! -f "$file2" ]]
    then
	  eval $oc_logs > $file1
	  cat $file1 | eval $gzip_curl;
    elif [[ -f "$file1" && ! -f "$file2" ]]
    then
      eval $oc_logs > $file2
      grep -v -x -f $file1 $file2 | eval $gzip_curl;
      rm -f $file1
    elif [[ ! -f "$file1" && -f "$file2" ]]
    then
      eval $oc_logs > $file1
      grep -v -x -f $file2 $file1 | eval $gzip_curl;
      rm -f $file2
    else
      eval $oc_logs | eval $gzip_curl;
      rm -f $file1 $file2
    fi
  ) 200>/tmp/.data.lock

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
  echo "${HOSTNAME}: $(date +'%Y-%m-%d %H:%M:%S' | sed 's/\(:[0-9][0-9]\)[0-9]*$/\1/') duration: $duration since: $since"
  # use openshift client to get logs, gzip them and use curl to send to REST endpoint
  _send
  # this is equivalent to backgrouding our sleep, so we can interrupt when container halted
  coproc sleep ${SLEEP_TIME}
  wait
  # calculate total processing duration
  duration=$((${SECONDS} - $start));
};

# sig handler for TERM sent by openshift when pod is stopped or deleted
# need to adjust for graceful termination of the container we are getting logs for
_term() {
  echo "Caught SIGTERM signal! Waiting ${GRACEFUL_EXIT_TIME} seconds before sending"
  sleep ${GRACEFUL_EXIT_TIME}
  sendLogs ${GRACEFUL_EXIT_TIME}
  # exit gracefully
  exit 0
}
trap _term SIGTERM

# initial startup delay for container we a getting logs for and ourselves
duration=5;

# set variables to send logs
while [[ "${FEED_NAME_HEADER}" && "${SYSTEM_NAME_HEADER}" && "${ENV_NAME_HEADER}" ]];
  do sendLogs 0
done

# sidecar does nothing if a header is empty
sleep infinity