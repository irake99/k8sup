# bash functions
source "$(dirname "$0")/env.sh" || { echo 'Can not load the env.sh file, exiting...' >&2 && exit 1 ; }

function init(){
  mv -f "${WORKDIR}/bin"/* "/opt/bin/"
  rmdir "${WORKDIR}/bin"
}

function hold_until_kube_apiserver_started(){
  until curl-k8s -sf "https://10.0.0.1:443/version" &>/dev/null; do
    sleep 1
  done
}

function get_all_authorized_keys_from_k8s_secrets(){
  local INTERVAL="10"
  local KEYS
  local DECODED_KEYS
  local KEY_FILE=~/".ssh/authorized_keys"
  if [[ ! -f "${KEY_FILE}" ]]; then
    mkdir -p ~/".ssh"
    touch "${KEY_FILE}"
    chmod 600 "${KEY_FILE}"
  fi
  while true; do
    DECODED_KEYS=""
    KEYS="$(curl-k8s -s "https://10.0.0.1/api/v1/namespaces/kube-system/secrets/k8sup-authorized-keys" \
             | jq -r '.data[]?' 2>/dev/null)"
    # If no such keys on k8s, then erase authorized_keys file for keeping synchronized status
    if [[ -z "${KEYS}" ]]; then
      if [[ -s "${KEY_FILE}" ]]; then
        > "${KEY_FILE}"
        echo "authorized_keys updated!"
      fi
      sleep "${INTERVAL}"
      continue
    fi
    # Decode line by line, because this base64 command doesn't support multiple line decoding
    for KEY in ${KEYS}; do
      DECODED_KEYS="$(echo "${KEY}" | base64 -d)"$'\n'"${DECODED_KEYS}"
    done
    # Remove the extra last character '\n'
    DECODED_KEYS="$(echo "${DECODED_KEYS}" | head -c -1)"
    # Update file if keys have been changed
    if ! cmp -s "${KEY_FILE}" <(echo "${DECODED_KEYS}"); then
      echo "${DECODED_KEYS}" > "${KEY_FILE}"
      echo "authorized_keys updated!"
    fi
    sleep "${INTERVAL}"
  done
}
