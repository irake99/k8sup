#!/bin/bash

function check_certs_exist_on_etcd(){
  local ETCD_PATH="k8sup/cluster/k8s_certs"

  if curl -sf "http://localhost:2379/v2/keys/${ETCD_PATH}" &>/dev/null; then
    local CERTS_ON_ETCD="true"
  else
    local CERTS_ON_ETCD="false"
  fi

  echo "${CERTS_ON_ETCD}"
}

function upload_kube_certs(){
  local CERTS_DIR="/data"
  local FILE_LIST="ca.crt kubecfg.crt kubecfg.key server.cert server.key basic_auth.csv known_tokens.csv"
  local ETCD_PATH="k8sup/cluster/k8s_certs"

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

  curl -s "http://localhost:2379/v2/keys/${ETCD_PATH}" -XPUT -d dir=true 1>&2
  for FILE in ${FILE_LIST}; do
    local ENCODED_DATA="$( cat "${CERTS_DIR}/${FILE}" | base64)"
    curl -s "http://localhost:2379/v2/keys/${ETCD_PATH}/${FILE}" -XPUT -d value="${ENCODED_DATA}" &>/dev/null
  done
}

function download_kube_certs(){
  local CERTS_DIR="/data"
  local FILE_LIST="ca.crt kubecfg.crt kubecfg.key server.cert server.key basic_auth.csv known_tokens.csv"
  local ETCD_PATH="k8sup/cluster/k8s_certs"
  local RAWDATA=""
  local CERT=""

   mkdir-p "${CERTS_DIR}"

  for FILE in ${FILE_LIST}; do
    until RAWDATA="$(curl -sf "http://localhost:2379/v2/keys/${ETCD_PATH}/${FILE}")"; do
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
      chown root:kube-cert-test "${CERTS_DIR}/${FILE}"
      chmod 660 "${CERTS_DIR}/${FILE}"
    fi
  done
}

function main(){
  local CERTS_ON_ETCD="$(check_certs_exist_on_etcd)"
  if [[ "${CERTS_ON_ETCD}" == "true" ]]; then
    download_kube_certs
  else
    upload_kube_certs &
  fi

  /setup-files.sh "$@"
}

main "$@"
