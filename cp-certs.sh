#!/bin/bash

function check_and_wait_all_cert_files_in_var_lib_kubelet_kubeconfig(){
  local CERTS_DIR="/var/lib/kubelet/kubeconfig"
  local FILE_LIST="ca.crt kubecfg.crt kubecfg.key"

  # Wait a moment until all files exist
  local CERTS_EXISTED="false"
  until [[ "${CERTS_EXISTED}" == "true" ]]; do
    CERTS_EXISTED="true"
    for FILE in ${FILE_LIST}; do
      test -f "${CERTS_DIR}/${FILE}" || { CERTS_EXISTED="false" && break; }
    done
    if [[ "${CERTS_EXISTED}" == "false" ]]; then
      sleep 1
    fi
  done

  echo "All certs in ${CERTS_DIR}" 1>&2
}

function check_and_wait_all_cert_files_in_srv_kubernetes(){
  local CERTS_DIR="/srv/kubernetes"
  local FILE_LIST="ca.crt kubecfg.crt kubecfg.key server.cert server.key basic_auth.csv known_tokens.csv abac-policy-file.jsonl"

  # Wait a moment until all files exist
  local CERTS_EXISTED="false"
  until [[ "${CERTS_EXISTED}" == "true" ]]; do
    CERTS_EXISTED="true"
    for FILE in ${FILE_LIST}; do
      test -f "${CERTS_DIR}/${FILE}" || { CERTS_EXISTED="false" && break; }
    done
    if [[ "${CERTS_EXISTED}" == "false" ]]; then
      sleep 1
    fi
  done

  echo "All certs in ${CERTS_DIR}" 1>&2
}

function check_and_wait_all_certs_exist_on_etcd(){
  local ETCD_PATH="$1"
  local CERT_LIST="ca.crt kubecfg.crt kubecfg.key server.cert server.key basic_auth.csv known_tokens.csv"
  local CERTS_EXISTED

  # Wait a moment until all certs exist
  until [[ "${CERTS_EXISTED}" == "true" ]]; do
    CERTS_EXISTED="true"
    for CERT in ${CERT_LIST}; do
      curl -sf "http://127.0.0.1:2379/v2/keys/${ETCD_PATH}/${CERT}" &>/dev/null \
        || { CERTS_EXISTED="false" && break; }
    done
    if [[ "${CERTS_EXISTED}" == "false" ]]; then
      sleep 1
    fi
  done

  echo "All certs on etcd" 1>&2
}

function check_certs_exist_on_etcd(){
  local ETCD_PATH="$1"
  local ERROR_CODE=""
  local CERTS_ON_ETCD=""

  until curl -s "http://127.0.0.1:2379/v2/keys" &>/dev/null; do
    echo "Waiting for etcd ready..." 1>&2
    sleep 1
  done

  # Atomic operation for ensuring there are no certs on etcd that uploaded by other node before.
  curl -sf "http://127.0.0.1:2379/v2/keys/${ETCD_PATH}?prevExist=false" -XPUT -d dir=true 1>&2
  ERROR_CODE="$?"
  # Error code 22 means the certs have alreay been uploaded by other node before
  if [[ "${ERROR_CODE}" == "22" ]]; then
    CERTS_ON_ETCD="true"
  elif [[ "${ERROR_CODE}" == "0" ]]; then
    CERTS_ON_ETCD="false"
  else
    echo "Connect to etcd error, exiting..." 1>&2
    exit "${ERROR_CODE}"
  fi

  echo "${CERTS_ON_ETCD}"
}

# clone client-certificate and client-key for kube-proxy & kubelet
function cp_kube_certs(){
  local CERTS_DIR="/srv/kubernetes"
  local FILE_LIST="ca.crt kubecfg.crt kubecfg.key"
  local DEST_DIR="/var/lib/kubelet/kubeconfig"
  local CERTS_EXISTED

  mkdir -p "${DEST_DIR}"
  for FILE in ${FILE_LIST}; do
    rm -f "${DEST_DIR}/${FILE}" || true
  done

  # Wait a moment until all files exist
  echo "Copying certs to ${DEST_DIR}..." 1>&2
  until [[ "${CERTS_EXISTED}" == "true" ]]; do
    CERTS_EXISTED="true"
    for FILE in ${FILE_LIST}; do
      test -f "${CERTS_DIR}/${FILE}" || { CERTS_EXISTED="false" && break; }
    done
    if [[ "${CERTS_EXISTED}" == "false" ]]; then
      sleep 1
    fi
  done

  for FILE in ${FILE_LIST}; do
    cp -f "${CERTS_DIR}/${FILE}" "${DEST_DIR}" \
      && echo "${FILE}" copied 1>&2
  done
}

function upload_kube_certs(){
  local ETCD_PATH="$1"
  local CERTS_DIR="/srv/kubernetes"
  local FILE_LIST="ca.crt kubecfg.crt kubecfg.key server.cert server.key basic_auth.csv known_tokens.csv abac-policy-file.jsonl"
  local ENCODED_DATA=""

  # Wait a moment until all files exist
  local CERTS_EXISTED="false"
  until [[ "${CERTS_EXISTED}" == "true" ]]; do
    CERTS_EXISTED="true"
    for FILE in ${FILE_LIST}; do
      test -f "${CERTS_DIR}/${FILE}" || { CERTS_EXISTED="false" && break; }
    done
    if [[ "${CERTS_EXISTED}" == "false" ]]; then
      sleep 1
    fi
  done

  # Check again if CA exists, don't upload anything
  curl -sf "http://127.0.0.1:2379/v2/keys/${ETCD_PATH}/ca.crt" 1>&2
  ERROR_CODE="$?"
  if [[ "${ERROR_CODE}" == "22" ]]; then
    echo There are no certs on etcd, uploading certs... 1>&2
    for FILE in ${FILE_LIST}; do
      ENCODED_DATA="$(cat "${CERTS_DIR}/${FILE}" | base64)"
      curl -s "http://127.0.0.1:2379/v2/keys/${ETCD_PATH}/${FILE}" -XPUT -d value="${ENCODED_DATA}" 1>/dev/null \
        && echo "${FILE}" uploaded 1>&2
    done
  else
    download_kube_certs "${ETCD_PATH}"
  fi
}

function download_kube_certs(){
  local ETCD_PATH="$1"
  local CERTS_DIR="/srv/kubernetes"
  local FILE_LIST="ca.crt kubecfg.crt kubecfg.key server.cert server.key basic_auth.csv known_tokens.csv abac-policy-file.jsonl"
  local RAWDATA=""
  local CERT=""

  mkdir -p "${CERTS_DIR}"

  echo "Downloading certs to ${CERTS_DIR}..." 1>&2
  for FILE in ${FILE_LIST}; do
    until RAWDATA="$(curl -sf "http://127.0.0.1:2379/v2/keys/${ETCD_PATH}/${FILE}")"; do
      echo "Waiting to get etcd keys..." 1>&2
      sleep 1
    done
    CERT="$(echo "${RAWDATA}" \
      | sed -n "s/.*value\":\"\(.*\)\",.*/\1/p" \
      | sed "s/\\\n/\n/g" \
      | base64 -d -i)"
    echo "${CERT}" |  tee "${CERTS_DIR}/${FILE}" 1>/dev/null \
      && echo "${FILE} downloaded" 1>&2 \
      || { echo "Error: download or writing '${FILE}' failed!"; return 1; }
  done

  for FILE in ${FILE_LIST}; do
    if [[ "${FILE}" == "kubecfg.crt" ]] || [[ "${FILE}" == "kubecfg.key" ]]; then
      chmod 600 "${CERTS_DIR}/${FILE}"
    elif [[ "${FILE}" == "basic_auth.csv" ]] || [[ "${FILE}" == "known_tokens.csv" ]]; then
      chmod 644 "${CERTS_DIR}/${FILE}"
    else
      chown root:root "${CERTS_DIR}/${FILE}"
      chmod 660 "${CERTS_DIR}/${FILE}"
    fi
  done
}

function export_keystone_ssl(){
  local KEYSTONE_CERTS_PATH="/srv/keystone"
  local CERTS_DIR="/srv/kubernetes"

  mkdir -p "${KEYSTONE_CERTS_PATH}"
  openssl x509 -outform PEM -in "${CERTS_DIR}/ca.crt"      -out "${KEYSTONE_CERTS_PATH}/ca.pem"
  openssl x509 -outform PEM -in "${CERTS_DIR}/server.cert" -out "${KEYSTONE_CERTS_PATH}/keystone.pem"
  openssl rsa  -outform PEM -in "${CERTS_DIR}/server.key"  -out "${KEYSTONE_CERTS_PATH}/keystonekey.pem" 1>/dev/null

  # Waiting for apiserver ready
  until /hyperkube kubectl get secret &>/dev/null; do
    sleep 1
  done
  # Try to delete old certs and upload new certs
  /hyperkube kubectl delete secret keystone-tls-certs &>/dev/null
  /hyperkube kubectl create secret generic keystone-tls-certs --from-file="${KEYSTONE_CERTS_PATH}" --namespace=default 1>/dev/null \
    && echo "keystone certs uploaded as secret."
}

function main(){
  if ! which curl &>/dev/null; then
    apt-get update 1>/dev/null
    apt-get install -y curl 1>/dev/null
  fi
  local DOMAIN_NAME="$1"
  local DONT_HOLD="$2"
  local ETCD_PATH="k8sup/cluster/k8s_certs"
  local CERTS_DIR="/srv/kubernetes"
  local CERTS_ON_ETCD=""

  CERTS_ON_ETCD="$(check_certs_exist_on_etcd "${ETCD_PATH}")" || exit
  if [[ "${CERTS_ON_ETCD}" == "true" ]]; then
    download_kube_certs "${ETCD_PATH}" || exit 1
  else
    upload_kube_certs "${ETCD_PATH}" &
  fi

  mkdir -p "${CERTS_DIR}"
  if [[ -f "/abac-policy-file.jsonl" ]]; then
    cp -f "/abac-policy-file.jsonl" "${CERTS_DIR}"
  fi

  /setup-files.sh "${DOMAIN_NAME}" &

  cp_kube_certs

  if [[ "${DONT_HOLD}" != "DONT_HOLD" ]]; then
    check_and_wait_all_cert_files_in_srv_kubernetes
    export_keystone_ssl
    sleep infinity
  else
    check_and_wait_all_certs_exist_on_etcd "${ETCD_PATH}"
    check_and_wait_all_cert_files_in_srv_kubernetes
    check_and_wait_all_cert_files_in_var_lib_kubelet_kubeconfig
    exit 0
  fi
}

main "$@"
