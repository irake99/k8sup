#!/bin/bash

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

  mkdir -p "${DEST_DIR}"
  for FILE in ${FILE_LIST}; do
    rm -f "${DEST_DIR}/${FILE}" || true
  done

  # Wait a moment until all files exist
  local CERTS_EXISTED="false"
  until [[ "${CERTS_EXISTED}" == "true" ]]; do
    CERTS_EXISTED="true"
    for FILE in ${FILE_LIST}; do
      test -f "${CERTS_DIR}/${FILE}" || CERTS_EXISTED="false"
    done
    if [[ "${CERTS_EXISTED}" == "false" ]]; then
      sleep 1
    fi
  done

  for FILE in ${FILE_LIST}; do
    cp -f "${CERTS_DIR}/${FILE}" "${DEST_DIR}" || true
  done
}

function upload_kube_certs(){
  local ETCD_PATH="$1"
  local CERTS_DIR="/srv/kubernetes"
  local FILE_LIST="ca.crt kubecfg.crt kubecfg.key server.cert server.key basic_auth.csv known_tokens.csv"
  local ENCODED_DATA=""

  # Wait a moment until all files exist
  local CERTS_EXISTED="false"
  until [[ "${CERTS_EXISTED}" == "true" ]]; do
    CERTS_EXISTED="true"
    for FILE in ${FILE_LIST}; do
      test -f "${CERTS_DIR}/${FILE}" || CERTS_EXISTED="false"
    done
    if [[ "${CERTS_EXISTED}" == "false" ]]; then
      sleep 1
    fi
  done

  local CERTS_ON_ETCD="$(check_certs_exist_on_etcd "${ETCD_PATH}")" || exit
  echo "CERTS_ON_ETCD: ${CERTS_ON_ETCD}"
  if [[ "${CERTS_ON_ETCD}" == "false" ]]; then
    for FILE in ${FILE_LIST}; do
      ENCODED_DATA="$(cat "${CERTS_DIR}/${FILE}" | base64)"
      curl -s "http://127.0.0.1:2379/v2/keys/${ETCD_PATH}/${FILE}" -XPUT -d value="${ENCODED_DATA}" &>/dev/null
    done
  else
    download_kube_certs "${ETCD_PATH}"
  fi
}

function download_kube_certs(){
  local ETCD_PATH="$1"
  local CERTS_DIR="/srv/kubernetes"
  local FILE_LIST="ca.crt kubecfg.crt kubecfg.key server.cert server.key basic_auth.csv known_tokens.csv"
  local RAWDATA=""
  local CERT=""

  mkdir -p "${CERTS_DIR}"

  for FILE in ${FILE_LIST}; do
    until RAWDATA="$(curl -sf "http://127.0.0.1:2379/v2/keys/${ETCD_PATH}/${FILE}")"; do
      echo "Waiting to get etcd keys..." 1>&2
      sleep 1
    done
    CERT="$(echo "${RAWDATA}" \
      | sed -n "s/.*value\":\"\(.*\)\",.*/\1/p" \
      | sed "s/\\\n/\n/g" \
      | base64 -d -i)"
    echo "${CERT}" |  tee "${CERTS_DIR}/${FILE}" 1>/dev/null
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

function main(){
  apt-get update 1>/dev/null
  apt-get install -y curl 1>/dev/null
  local DOMAIN_NAME="$1"
  local DONT_HOLD="$2"
  local ETCD_PATH="k8sup/cluster/k8s_certs"
  local CERTS_ON_ETCD=""

  # Remove old certs for master services before that started
  rm -rf "/srv/kubernetes/"*

  CERTS_ON_ETCD="$(check_certs_exist_on_etcd "${ETCD_PATH}")" || exit
  echo "CERTS_ON_ETCD: ${CERTS_ON_ETCD}"
  if [[ "${CERTS_ON_ETCD}" == "true" ]]; then
    download_kube_certs "${ETCD_PATH}"
  else
    upload_kube_certs "${ETCD_PATH}" &
  fi

  /setup-files.sh "${DOMAIN_NAME}" &

  cp_kube_certs

  [[ "${DONT_HOLD}" != "DONT_HOLD" ]] && wait || exit 0
}

main "$@"
