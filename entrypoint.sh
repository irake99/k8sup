#!/bin/bash
set -e

function etcd_creator(){
  local IPADDR="$1"
  local ETCD_NAME="$2"

  docker run \
    -d \
    -v /usr/share/ca-certificates/:/etc/ssl/certs \
    -v /var/lib/etcd:/var/lib/etcd \
    --net=host \
    --restart=always \
    --name=k8sup-etcd \
    "${ENV_ETCD_IMAGE}" \
    /usr/local/bin/etcd \
      --name "${ETCD_NAME}" \
      --advertise-client-urls http://${IPADDR}:2379,http://${IPADDR}:4001 \
      --listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 \
      --initial-advertise-peer-urls http://${IPADDR}:2380  \
      --listen-peer-urls http://0.0.0.0:2380 \
      --initial-cluster-token etcd-cluster-1 \
      --initial-cluster "${ETCD_NAME}=http://${IPADDR}:2380" \
      --initial-cluster-state new \
      --data-dir /var/lib/etcd
}

function flanneld(){
  local IPADDR="$1"
  local ETCD_CID="$2"

  echo "Setting flannel parameters to etcd"
  local KERNEL_SHORT_VERSION="$(uname -r | cut -d '.' -f 1-2)"
  local VXLAN="$(echo "${KERNEL_SHORT_VERSION} >= 3.9" | bc)"
  if [ "${VXLAN}" -eq 1 ] && [ -n "$(lsmod | grep vxlan &> /dev/null)" ]; then
    docker exec -it \
      "${ETCD_CID}" \
      /usr/local/bin/etcdctl \
      --endpoints http://127.0.0.1:2379 \
      set /coreos.com/network/config '{ "Network": "10.1.0.0/16", "Backend": { "Type": "vxlan"}}'
  else
    docker exec -it \
      "${ETCD_CID}" \
      /usr/local/bin/etcdctl \
      --endpoints http://127.0.0.1:2379 \
      set /coreos.com/network/config '{ "Network": "10.1.0.0/16"}'
  fi

  docker run \
    -d \
    --name k8sup-flannel \
    --net=host \
    --privileged \
    --restart=always \
    -v /dev/net:/dev/net \
    -v /run/flannel:/run/flannel \
    "${ENV_FLANNELD_IMAGE}" \
    /opt/bin/flanneld \
      --etcd-endpoints=http://${IPADDR}:4001 \
      --iface=${IPADDR}
}

function main(){

  export ENV_ETCD_VERSION="3.0.4"
  export ENV_FLANNELD_VERSION="0.5.5"
#  export ENV_K8S_VERSION="1.3.4"
  export ENV_ETCD_IMAGE="quay.io/coreos/etcd:v${ENV_ETCD_VERSION}"
  export ENV_FLANNELD_IMAGE="quay.io/coreos/flannel:${ENV_FLANNELD_VERSION}"
#  export ENV_HYPERKUBE_IMAGE="gcr.io/google_containers/hyperkube-amd64:v${ENV_K8S_VERSION}"

  echo "Copy cni plugins"
  cp -rf bin /opt/cni
  mkdir -p /etc/cni/net.d/
  cp -f /go/cni-conf/10-containernet.conf /etc/cni/net.d/
  cp -f /go/cni-conf/99-loopback.conf /etc/cni/net.d/
  mkdir -p /var/lib/cni/networks/mynet; echo "" > /var/lib/cni/networks/mynet/last_reserved_ip

  sh -c 'docker stop k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-etcd' >/dev/null 2>&1 || true
  sh -c 'docker stop k8sup-flannel' >/dev/null 2>&1 || true
  sh -c 'docker rm k8sup-flannel' >/dev/null 2>&1 || true

  echo "Running etcd"
  local ETCD_CID=$(etcd_creator "${IPADDR}" "${HOSTNAME}")

  until curl -s 127.0.0.1:2379/v2/keys; do
    echo "Waiting for etcd ready..."
    sleep 1
  done
  echo "Running flanneld"
  flanneld "${IPADDR}" "${ETCD_CID}"

  echo "Running Kubernetes"
  /go/kube-up "$1"

}

main "$@"
