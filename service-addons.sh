#!/bin/bash

KUBECTL=${KUBECTL_BIN:-/usr/local/bin/kubectl}
KUBECTL_OPTS=${KUBECTL_OPTS:-}

ADDON_CHECK_INTERVAL_SEC=${TEST_ADDON_CHECK_INTERVAL_SEC:-60}
ADDON_PATH=${ADDON_PATH:-/etc/kubernetes/addons}

SYSTEM_NAMESPACE=kube-system

# Remember that you can't log from functions that print some output (because
# logs are also printed on stdout).
# $1 level
# $2 message
function log() {
  # manage log levels manually here

  # add the timestamp if you find it useful
  case $1 in
    DB3 )
#        echo "$1: $2"
        ;;
    DB2 )
#        echo "$1: $2"
        ;;
    DBG )
#        echo "$1: $2"
        ;;
    INFO )
        echo "$1: $2"
        ;;
    WRN )
        echo "$1: $2"
        ;;
    ERR )
        echo "$1: $2"
        ;;
    * )
        echo "INVALID_LOG_LEVEL $1: $2"
        ;;
  esac
}

# $1 command to execute.
# $2 count of tries to execute the command.
# $3 delay in seconds between two consecutive tries
function run_until_success() {
  local -r command=$1
  local tries=$2
  local -r delay=$3
  local -r command_name=$1
  while [ ${tries} -gt 0 ]; do
    log DBG "executing: '$command'"
    # let's give the command as an argument to bash -c, so that we can use
    # && and || inside the command itself
    /bin/bash -c "${command}" && \
      log DB3 "== Successfully executed ${command_name} at $(date -Is) ==" && \
      return 0
    let tries=tries-1
    #log WRN "== Failed to execute ${command_name} at $(date -Is). ${tries} tries remaining. =="
    sleep ${delay}
  done
  return 1
}
function create_addons() {
  local -r enable_prune=$1;
  local -r additional_opt=$2;

  for filename in $(ls ${ADDON_PATH}); do
    namespace="$(sed -n "s/^[ \t]*namespace:[ \t]*\(.*\)/\1/p" "${ADDON_PATH}/${filename}" | uniq)"
    if [[ -z "${namespace}" ]]; then
      namespace="default"
    elif [[ "$(echo "${namespace}" | wc -l)" -gt "1" ]]; then
      log ERR "Mutilple namespaces in a yaml file: "${ADDON_PATH}/${filename}", skip..."
      continue
    fi
    run_until_success "${KUBECTL} ${KUBECTL_OPTS} --namespace=${namespace} create -f ${ADDON_PATH}/${filename} ${additional_opt}" 1 1 \
      && log INFO "++ obj ${filename} is created ++"
  done
}

function update_addons() {
  local -r enable_prune=$1;
  local -r additional_opt=$2;

  for filename in $(ls ${ADDON_PATH}); do
    namespace="$(sed -n "s/^[ \t]*namespace:[ \t]*\(.*\)/\1/p" "${ADDON_PATH}/${filename}" | uniq)"
    if [[ -z "${namespace}" ]]; then
      namespace="default"
    elif [[ "$(echo "${namespace}" | wc -l)" -gt "1" ]]; then
      log ERR "Mutilple namespaces in a yaml file: "${ADDON_PATH}/${filename}", skip..."
      continue
    fi
    run_until_success "${KUBECTL} ${KUBECTL_OPTS} --namespace=${namespace} apply -f ${ADDON_PATH}/${filename} --prune=${enable_prune} -l cdxvirt/cluster-service=true ${additional_opt}" 1 1 \
      && log INFO "++ obj ${filename} is applied ++"
  done

  if [[ $? -eq 0 ]]; then
    log INFO "== Kubernetes addon update completed successfully at $(date -Is) =="
  fi
}

log INFO "== Kubernetes addon manager started at $(date -Is) with ADDON_CHECK_INTERVAL_SEC=${ADDON_CHECK_INTERVAL_SEC} =="
update_addons false

# Start the apply loop.
# Check if the configuration has changed recently - in case the user
# created/updated/deleted the files on the master.
log INFO "== Entering periodical apply loop at $(date -Is) =="
while true; do
  start_sec=$(date +"%s")
  # Only print stderr for the readability of logging
  create_addons true ">/dev/null 2>&1"
  update_addons true ">/dev/null 2>&1"
  end_sec=$(date +"%s")
  len_sec=$((${end_sec}-${start_sec}))
  # subtract the time passed from the sleep time
  if [[ ${len_sec} -lt ${ADDON_CHECK_INTERVAL_SEC} ]]; then
    sleep_time=$((${ADDON_CHECK_INTERVAL_SEC}-${len_sec}))
    sleep ${sleep_time}
  fi
done
