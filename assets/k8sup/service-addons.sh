#!/bin/bash

KUBECTL=${KUBECTL_BIN:-/usr/local/bin/kubectl}

ADDON_CHECK_INTERVAL_SEC=${TEST_ADDON_CHECK_INTERVAL_SEC:-60}
ADDON_PATH=${ADDON_PATH:-/etc/kubernetes/addons}

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

function parse_yaml() {
  local prefix=$2
  local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
  sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
      -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
  awk -F$fs '{
    indent = length($1)/2;
    vname[indent] = $2;
    for (i in vname) {if (i > indent) {delete vname[i]}}
    if (length($3) > 0) {
       vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
       printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
    }
    }'
}

function find_deleted_yaml() {
  local yaml_in_installed=$(find ${ADDON_PATH}/installed -type f -name ".*")

  for path in $yaml_in_installed; do
    filename=$(echo $path | sed 's/.*\/.//')
    namespace=$(parse_yaml ${path}|awk -F\" '/metadata_namespace=/{print $2}')
    if [ -z ${namespace} ]; then
      namespace="default"
    else
      namespace=$namespace
    fi

    log DBG "PATH: ${path}, FILENAME: ${filename}, NAMESPACE: ${namespace}"

    test -s ${ADDON_PATH}/installed/${filename} || ( kubectl delete -n ${namespace} -f ${path} ; rm -f ${path} )
  done
}

function update_addons() {
  log DBG "== Find out files with labels =="
  local files_with_label=$(find ${ADDON_PATH} -path "${ADDON_PATH}/installed" -prune -o -type f -name "*.yaml" -print | xargs --no-run-if-empty grep -l 'cdxvirt/cluster-service: .true.')

  for file in $files_with_label; do
    path=${file}
    filename=$(echo $path | sed 's/.*\///')
    name=$(parse_yaml ${path}|awk -F\" '/metadata_name=/{print $2}')
    kind=$(parse_yaml ${path}|awk -F\" '/kind=/{print $2}')
    namespace=$(parse_yaml ${path}|awk -F\" '/metadata_namespace=/{print $2}')
    if [ -z ${namespace} ]; then
      namespace="default"
    else
      namespace=$namespace
    fi

    kubectl replace -n ${namespace} -f ${path} --force && \
    mv -f ${path} ${ADDON_PATH}/installed/${filename} && \
    cp ${ADDON_PATH}/installed/${filename} ${ADDON_PATH}/installed/.${filename}
  done

  find_deleted_yaml

  if [[ $? -eq 0 ]]; then
    log INFO "== Service addons update completed successfully at $(date -Is) =="
  fi
}

if [ -d "${ADDON_PATH}/installed" ]; then
  log DBG "Directory ${ADDON_PATH}/installed exists!"
else
  mkdir -p ${ADDON_PATH}/installed
fi

log INFO "== Service addons started at $(date -Is) with ADDON_CHECK_INTERVAL_SEC=${ADDON_CHECK_INTERVAL_SEC} =="

# Start the apply loop.
# Check if the configuration has changed recently - in case the user
# created/updated/deleted the files on the master.
log INFO "== Entering periodical apply loop at $(date -Is) =="
while true; do
  start_sec=$(date +"%s")
  # Only print stderr for the readability of logging
  update_addons
  end_sec=$(date +"%s")
  len_sec=$((${end_sec}-${start_sec}))
  # subtract the time passed from the sleep time
  if [[ ${len_sec} -lt ${ADDON_CHECK_INTERVAL_SEC} ]]; then
    sleep_time=$((${ADDON_CHECK_INTERVAL_SEC}-${len_sec}))
    sleep ${sleep_time}
  fi
done
