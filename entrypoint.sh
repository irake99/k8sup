#!/bin/bash
set -e

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
etcdCID=$(docker run -d -v /usr/share/ca-certificates/:/etc/ssl/certs -v /var/lib/etcd:/var/lib/etcd --net=host --restart=always --name k8sup-etcd quay.io/coreos/etcd /usr/local/bin/etcd --name etcd0  --advertise-client-urls http://$1:2379,http://$1:4001  --listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001  --initial-advertise-peer-urls http://$1:2380  --listen-peer-urls http://0.0.0.0:2380  --initial-cluster-token etcd-cluster-1  --initial-cluster etcd0=http://$1:2380  --initial-cluster-state new --data-dir /var/lib/etcd)

echo "Setting etcd"
KERNEL_SHORT_VERSION=$(uname -r | cut -d '.' -f 1-2)
VXLAN=`echo "$KERNEL_SHORT_VERSION >= 3.9" | bc`
if [ $VXLAN -eq 1 ] && [ -n `lsmod | grep vxlan &> /dev/null` ]; then
    docker exec -it ${etcdCID} /usr/local/bin/etcdctl --endpoints http://127.0.0.1:4001 set /coreos.com/network/config '{ "Network": "10.1.0.0/16", "Backend": { "Type": "vxlan"}}'
else
     docker exec -it ${etcdCID} /usr/local/bin/etcdctl --endpoints http://127.0.0.1:4001 set /coreos.com/network/config '{ "Network": "10.1.0.0/16"}'
fi

echo "Running flanneld"
docker run --name k8sup-flannel --net=host -d --privileged -v /dev/net:/dev/net -v /run/flannel:/run/flannel --restart=always quay.io/coreos/flannel:0.5.5 /opt/bin/flanneld --etcd-endpoints=http://$1:4001 --iface=$1

echo "Running Kubernetes"
/go/kube-up $1
