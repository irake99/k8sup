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

function contains_element() {
  local e
  for e in "${@:2}"; do [[ $e == *"$1"* ]] && echo "$e"; done
}

function prune_resource() {
  local namespace=$1
  local prune_whitelist=$2
  local path=$3
  random=$(echo $RANDOM)

cat > ${path} << EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: clear-${random}
  labels:
    cdxvirt/cluster-service: "true"
spec:
  containers:
  - name: clear-${random}
    image: ${image}
    command:
    - "kubectl"
    - "delete"
    - "pod"
    - "clear-${random}"
EOF

  ${KUBECTL} --namespace ${namespace} apply --prune=true --prune-whitelist=${prune_whitelist} -l cdxvirt/cluster-service=true -f ${path}
}

function union() {
  local OLDIFS
  local file1=$1
  local file2=$2
  local union_array

  test -s ${file1} || touch ${file1}
  test -s ${file2} || touch ${file2}

  OLDIFS="$IFS"
  IFS=$'\n'

  union_array=($(sort ${file1} ${file2} | uniq))
  echo "${union_array[*]}"
  IFS="$OLDIFS"
}

function except() {
  local OLDIFS
  local file1=$1
  local file2=$2
  local except_array

  test -s ${file1} || touch ${file1}
  test -s ${file2} || touch ${file2}

  OLDIFS="$IFS"
  IFS=$'\n'

  except_array=($(grep -F -f ${file1} ${file2} -v))
  echo "${except_array[*]}"
  IFS="$OLDIFS"
}

function update_addons() {
  log DBG "== Clear ${ADDON_PATH} hidden files =="
  find ${ADDON_PATH} -type f -name ".*" | xargs --no-run-if-empty rm

  log DBG "== Find out files with labels =="
  local files_with_label=$(find ${ADDON_PATH} -type f -name "*.yaml" ! -type l | xargs --no-run-if-empty grep -l 'cdxvirt/cluster-service: .true.')
  local files_with_label_array=(${files_with_label// / });
  local path filename namespace union_array
  local not_prune_resource_array=("core/v1/ConfigMap" "storage.k8s.io/v1beta1/StorageClass" "core/v1/Endpoints")
  local prune_resource_array=("core/v1/Namespace" \
                            "core/v1/PersistentVolumeClaim" \
                            "core/v1/PersistentVolume" \
                            "core/v1/Pod" \
                            "core/v1/ReplicationController" \
                            "core/v1/Secret" \
                            "core/v1/Service" \
                            "batch/v1/Job" \
                            "extensions/v1beta1/DaemonSet" \
                            "extensions/v1beta1/Deployment" \
                            "extensions/v1beta1/HorizontalPodAutoscaler" \
                            "extensions/v1beta1/Ingress" \
                            "extensions/v1beta1/ReplicaSet" \
                            "apps/v1beta1/StatefulSet")

  for path in "${files_with_label_array[@]}"; do
    filename=$(echo $path | sed 's/.*\///')
    file_kind=$(find ${path} | xargs sed 's/"//g; s/ //g' | grep "kind:" | sed 's/kind://g' | sort | uniq)
    file_kind_array=(${file_kind// / });
    file_namespace=$(find ${path} | xargs sed 's/"//g; s/ //g' | grep "namespace:" | sed 's/namespace://g')

    if [ -z ${file_namespace} ]; then
      file_namespace="default"
    else
      file_namespace=$file_namespace
    fi

    # Find out file kind in prune_resource and write it into /tmp/.service_addons_now_status
    for kind in "${file_kind_array[@]}"; do
      prune_resource=$(contains_element $kind "${prune_resource_array[@]}")
      not_prune_resource=$(contains_element $kind "${not_prune_resource_array[@]}")
      if [[ ${prune_resource} != "" ]]; then
        cat ${path} >> ${ADDON_PATH}/.${file_namespace}.${kind}
        echo "---" >> ${ADDON_PATH}/.${file_namespace}.${kind}
        echo "$file_namespace, $prune_resource" >> /tmp/.service_addons_now_status
      elif [[ ${not_prune_resource} != "" ]]; then
        meta_name=$(cat ${path} | sed 's/"//g; s/ //g;' | sed -n 's/name://p')
        echo "$file_namespace, $not_prune_resource, $meta_name, $path" >> /tmp/.service_addons_now_status.run_one_time
      fi
    done
  done

  log DBG "== Check before and now yaml status =="
  OLDIFS="$IFS"
  IFS=$'\n'
  union_array=($(union /tmp/.service_addons_before_status /tmp/.service_addons_now_status))
  mv /tmp/.service_addons_now_status /tmp/.service_addons_before_status

  create_array=($(except /tmp/.service_addons_before_status.run_one_time /tmp/.service_addons_now_status.run_one_time))
  delete_array=($(except /tmp/.service_addons_now_status.run_one_time /tmp/.service_addons_before_status.run_one_time))
  mv /tmp/.service_addons_now_status.run_one_time /tmp/.service_addons_before_status.run_one_time
  IFS="$OLDIFS"

  log DBG "== Run command kubectl apply/create/delte =="
  for unit in "${union_array[@]}"; do
    namespace=$(echo ${unit} | awk -F", " '{print$1}')
    resource=$(echo ${unit} | awk -F", " '{print$2}')
    kind=$(echo ${resource} | sed 's/.*\///g')
    path="${ADDON_PATH}/.${namespace}.${kind}"

    # Run with kubectl apply
    if [[ -f ${path} ]]; then
      ${KUBECTL} --namespace ${namespace} apply --prune=true --prune-whitelist=${resource} -l cdxvirt/cluster-service=true -f ${path}
    else
      prune_resource ${namespace} ${resource} ${path}
    fi
  done

  # Run with kubectl create/delete
  for unit in "${create_array[@]}"; do
    namespace=$(echo ${unit} | awk -F", " '{print$1}')
    resource=$(echo ${unit} | awk -F", " '{print$2}')
    meta_name=$(echo ${unit} | awk -F", " '{print$3}')
    path=$(echo ${unit} | awk -F", " '{print$4}')
    kind=$(echo ${resource} | sed 's/.*\///g')

    ${KUBECTL} --namespace ${namespace} create -f ${path}
  done

  for unit in "${delete_array[@]}"; do
    namespace=$(echo ${unit} | awk -F", " '{print$1}')
    resource=$(echo ${unit} | awk -F", " '{print$2}')
    meta_name=$(echo ${unit} | awk -F", " '{print$3}')
    path=$(echo ${unit} | awk -F", " '{print$4}')
    kind=$(echo ${resource} | sed 's/.*\///g')

    ${KUBECTL} --namespace ${namespace} delete ${kind} ${meta_name}
  done

  if [[ $? -eq 0 ]]; then
    log INFO "== Service addons update completed successfully at $(date -Is) =="
  fi
}

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
