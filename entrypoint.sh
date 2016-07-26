#!/bin/bash
set -e

echo "Copy cni plugins"
cp -rf bin /opt/cni
mkdir -p /etc/cni/net.d/
cp -f /go/10-containernet.conf /etc/cni/net.d/
cp -f /go/99-loopback.conf /etc/cni/net.d/
mkdir -p /var/lib/cni/networks/mynet; echo "" > /var/lib/cni/networks/mynet/last_reserved_ip

sh -c 'docker stop etcd0' >/dev/null 2>&1 || true 
sh -c 'docker rm etcd0' >/dev/null 2>&1 || true
sh -c 'docker stop flannel0' >/dev/null 2>&1 || true
sh -c 'docker rm flannel0' >/dev/null 2>&1 || true

echo "Running etcd"
etcdCID=$(docker run -d -v /usr/share/ca-certificates/:/etc/ssl/certs -v /var/lib/etcd:/var/lib/etcd -p 4001:4001 -p 2380:2380 -p 2379:2379 --restart=always --name etcd0 quay.io/coreos/etcd /usr/local/bin/etcd --name etcd0  --advertise-client-urls http://192.168.32.56:2379,http://192.168.32.56:4001  --listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001  --initial-advertise-peer-urls http://192.168.32.56:2380  --listen-peer-urls http://0.0.0.0:2380  --initial-cluster-token etcd-cluster-1  --initial-cluster etcd0=http://192.168.32.56:2380  --initial-cluster-state new --data-dir /var/lib/etcd)

echo "Setting etcd"
docker exec -it ${etcdCID} /usr/local/bin/etcdctl set /coreos.com/network/config '{ "Network": "10.1.0.0/16", "Backend": { "Type": "vxlan"}}'

echo "Running flanneld"
docker run --name flannel0 --net=host -d --privileged -v /dev/net:/dev/net -v /run/flannel:/run/flannel --restart=always quay.io/coreos/flannel:0.5.5 /opt/bin/flanneld --etcd-endpoints=http://192.168.32.56:4001

echo "Running Kubernetes"
/go/kube-up $@
