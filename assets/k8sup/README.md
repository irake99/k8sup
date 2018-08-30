# k8sup

Using One Docker container to bootstrap a HA Kubernetes cluster with auto cluster discovery.

Default behavior:
1. If only one cluster is discovered, join it automatically.
2. If more than one cluster are discovered, start a new cluster.

You can specify the same cluster ID to multiple nodes that it will make them become the same cluster. Conversely, You can also specify a different cluster ID to start node(s) as another cluster.

```
Options:
-n, --network=NETINFO              SubnetID/Mask or Host IP address or NIC name
                                   e. g. "192.168.11.0/24" or "192.168.11.1"
                                   or "eth0"
-c, --cluster=CLUSTER_ID           Join a specified cluster
    --token=TOKEN                  Boostrap token
    --ca-hash=CA_HASH              To verify the TLS boostrap seed host CA cert
    --unsafe-skip-ca-verification  Skip valid the hash of TLS boostrap seed host CA cert
    --k8s-version=VERSION          Specify k8s version (Default: 1.7.3)
    --max-etcd-members=NUM         Maximum etcd member size (Default: 3)
    --restore                      Try to restore etcd data and start a new cluster
    --restart                      Restart etcd and k8s services
    --rejoin-etcd                  Re-join the same etcd cluster
    --start-kube-svcs-only         Try to start kubernetes services (Assume etcd and flannel are ready)
    --start-etcd-only              Start etcd and flannel but don't start kubernetes services
    --worker                       Force to run as k8s worker and etcd proxy
    --debug                        Enable debug mode
    --enable-keystone              Enable Keystone service (Default: disabled)
-r, --registry=REGISTRY            Registry of docker image
                                   (Default: 'quay.io/coreos' and 'gcr.io/google_containers')
-v, --version                      Show k8sup version
-h, --help                         This help text
```

---

You can use '--ca-hash=CA_HASH' after the seed (first) host started and prompted (deploy method 1), or use '--unsafe-skip-ca-verification' on all hosts at the same time (deploy method 2).

Deploy method 1:

Put the token and CA hash and run k8s on the seed host:
```
$ docker pull cdxvirt/k8sup:v2.0
$ docker run -d \
    --privileged \
    --net=host \
    --pid=host \
    --restart=always \
    -v $(which docker):/bin/docker:ro \
    -v /run/systemd:/run/systemd \
    -v /etc/modprobe.d/:/etc/modprobe.d \
    -v /etc/systemd/network/:/etc/systemd/network \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/lib/:/host/lib:ro \
    -v /lib/modules:/lib/modules:ro \
    -v /etc/cni:/etc/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /var/lib/etcd:/var/lib/etcd \
    -v /var/lib/kubelet:/var/lib/kubelet \
    -v /etc/kubernetes:/etc/kubernetes \
    --name=k8sup \
    cdxvirt/k8sup:v2.0 \
    --network={your-subnet-id/mask}
```
And you will get the prompt of boostrap token and seed host CA hash like this:
```
Bootstrap token: a40d40.9290474d10999472
Seed host CA hash: aa1f1751d09e231d9705b9ba513d380ee83f5087d0a5dbd8cd0f1d49432dee24
```

Then run k8s on all other hosts:
```
$ docker pull cdxvirt/k8sup:v2.0
$ docker run -d \
    --privileged \
    --net=host \
    --pid=host \
    --restart=always \
    -v $(which docker):/bin/docker:ro \
    -v /run/systemd:/run/systemd \
    -v /etc/modprobe.d/:/etc/modprobe.d \
    -v /etc/systemd/network/:/etc/systemd/network \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/lib/:/host/lib:ro \
    -v /lib/modules:/lib/modules:ro \
    -v /etc/cni:/etc/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /var/lib/etcd:/var/lib/etcd \
    -v /var/lib/kubelet:/var/lib/kubelet \
    -v /etc/kubernetes:/etc/kubernetes \
    --name=k8sup \
    cdxvirt/k8sup:v2.0 \
    --token={your-token} \
    --ca-hash={your-ca-hash} \
    --network={your-subnet-id/mask}
```

---

Deploy method 2:

Generate a new bootstrap token:
```
TOKEN="$(od -An -t x -N 12 /dev/urandom | tr -d ' ' | tail -c 23 | sed 's/./&./6')"
```

Run k8s on all hosts at the same time:
```
$ docker pull cdxvirt/k8sup:v2.0
$ docker run -d \
    --privileged \
    --net=host \
    --pid=host \
    --restart=always \
    -v $(which docker):/bin/docker:ro \
    -v /run/systemd:/run/systemd \
    -v /etc/modprobe.d/:/etc/modprobe.d \
    -v /etc/systemd/network/:/etc/systemd/network \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/lib/:/host/lib:ro \
    -v /lib/modules:/lib/modules:ro \
    -v /etc/cni:/etc/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /var/lib/etcd:/var/lib/etcd \
    -v /var/lib/kubelet:/var/lib/kubelet \
    -v /etc/kubernetes:/etc/kubernetes \
    --name=k8sup \
    cdxvirt/k8sup:v2.0 \
    --token=${TOKEN} \
    --unsafe-skip-ca-verification \
    --network={your-subnet-id/mask}
```

---

Stop k8s:
```
$ docker run \
    --privileged \
    --net=host \
    --pid=host \
    --rm=true \
    -v $(which docker):/bin/docker:ro \
    -v /run/systemd:/run/systemd \
    -v /etc/modprobe.d/:/etc/modprobe.d \
    -v /etc/systemd/network/:/etc/systemd/network \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/lib/:/host/lib:ro \
    -v /lib/modules:/lib/modules:ro \
    -v /usr/sbin/modprobe:/usr/sbin/modprobe:ro \
    -v /opt/bin:/opt/bin:rw \
    -v /etc/cni:/etc/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /var/lib/etcd:/var/lib/etcd \
    -v /var/lib/kubelet:/var/lib/kubelet \
    -v /etc/kubernetes:/etc/kubernetes \
    --entrypoint=/workdir/assets/k8sup/kube-down \
    cdxvirt/k8sup:v2.0
```

Remove k8s from node:
```
$ docker run \
    --privileged \
    --net=host \
    --pid=host \
    --rm=true \
    -v $(which docker):/bin/docker:ro \
    -v /run/systemd:/run/systemd \
    -v /etc/modprobe.d/:/etc/modprobe.d \
    -v /etc/systemd/network/:/etc/systemd/network \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/lib/:/host/lib:ro \
    -v /lib/modules:/lib/modules:ro \
    -v /usr/sbin/modprobe:/usr/sbin/modprobe:ro \
    -v /opt/bin:/opt/bin:rw \
    -v /etc/cni:/etc/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /var/lib/etcd:/var/lib/etcd \
    -v /var/lib/kubelet:/var/lib/kubelet \
    -v /etc/kubernetes:/etc/kubernetes \
    --entrypoint=/workdir/assets/k8sup/kube-down \
    cdxvirt/k8sup:v2.0 \
    --remove
```

Show k8sup log and Cluster ID:
```
$ docker logs k8sup
```

If you want to delete etcd data:
```
$ sudo rm -rf /var/lib/etcd/*
```

To access the dashboard:
```
Browse https://<your-master-node-ip>:6443/ui
user:     admin
password: admin
```

NOTE:

1. If you want to use Ceph RBD mapping with k8sup, make sure that the 'rbd.ko' kernel object file, the 'modprobe' command file, and either the 'rbd' command file or the host path '/opt/bin' are mounted to the k8sup container as volumes.

2. k8sup ships with a default ntp service to synchronize system time of whole cluster. If a node is running other NTP client already, k8sup will not synchronize system time for this node, so you need to ensure all cluster nodes have the same system time by yourself.

3. Running k8sup on Ubuntu 16.04.2 <br /> https://gist.github.com/hsfeng/7fa5b57b68a62d7f14f3a10fc7db46cf <br />
