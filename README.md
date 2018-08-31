# k8sup

Using One Docker container to bootstrap a HA Kubernetes cluster with auto cluster discovery.

Default behavior:
1. If only one cluster is discovered, join it automatically.
2. If more than one cluster are discovered, start a new cluster.

About cluster ID:  
You can specify the same cluster ID (or name) to multiple nodes that it will make them become the same cluster. Conversely, You can also specify a different cluster ID (or name) to start node(s) as another cluster.

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

About bootstrap token:  
You can use '--ca-hash=CA_HASH' after the seed (first) host started and prompted (deploy method 1), or use '--unsafe-skip-ca-verification' on all hosts at the same time (deploy method 2).

Examples:

Deploy method 1 on CoreOS:

Put the token and CA hash and run k8s on the seed node:
```
$ CLUSTER_ID_OR_NAME="my-cluster"
$ NETADDR="192.168.56.0/24"
$ docker pull cdxvirt/k8sup:k8s-1.11
$ docker run -d \
    --privileged \
    --net=host \
    --pid=host \
    --restart=always \
    -v /run/torcx/bin/docker:/bin/docker:ro \
    -v /run/systemd:/run/systemd \
    -v /etc/modprobe.d/:/etc/modprobe.d \
    -v /etc/systemd/network/:/etc/systemd/network \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /run/torcx/unpack/docker/lib:/host/lib:ro \
    -v /lib/modules:/lib/modules:ro \
    -v /etc/cni:/etc/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /var/lib/etcd:/var/lib/etcd \
    -v /var/lib/kubelet:/var/lib/kubelet \
    -v /etc/kubernetes:/etc/kubernetes \
    --name=k8sup \
    cdxvirt/k8sup:k8s-1.11 \
    --cluster="${CLUSTER_ID_OR_NAME}" \
    --network="${NETADDR}"; \
      && docker logs -f k8sup
```
And you will get the prompt of boostrap token and seed node CA hash like this:
```
Bootstrap token: a40d40.9290474d10999472
Seed host CA hash: aa1f1751d09e231d9705b9ba513d380ee83f5087d0a5dbd8cd0f1d49432dee24
```

Then run k8s on all other hosts:
```
$ TOKEN="a40d40.9290474d10999472"
$ CA_HASH="aa1f1751d09e231d9705b9ba513d380ee83f5087d0a5dbd8cd0f1d49432dee24"
$ CLUSTER_ID_OR_NAME="my-cluster"
$ NETADDR="192.168.56.0/24"
$ docker pull cdxvirt/k8sup:k8s-1.11
$ docker run -d \
    --privileged \
    --net=host \
    --pid=host \
    --restart=always \
    -v /run/torcx/bin/docker:/bin/docker:ro \
    -v /run/systemd:/run/systemd \
    -v /etc/modprobe.d/:/etc/modprobe.d \
    -v /etc/systemd/network/:/etc/systemd/network \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /run/torcx/unpack/docker/lib:/host/lib:ro \
    -v /lib/modules:/lib/modules:ro \
    -v /etc/cni:/etc/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /var/lib/etcd:/var/lib/etcd \
    -v /var/lib/kubelet:/var/lib/kubelet \
    -v /etc/kubernetes:/etc/kubernetes \
    --name=k8sup \
    cdxvirt/k8sup:k8s-1.11 \
    --token="${TOKEN}" \
    --ca-hash="${CA_HASH}" \
    --cluster="${CLUSTER_ID_OR_NAME}" \
    --network="${NETADDR}"; \
      && docker logs -f k8sup
```

---

Deploy method 2 on CoreOS:

Generate a new bootstrap token:
```
$ TOKEN="$(od -An -t x -N 12 /dev/urandom | tr -d ' ' | tail -c 23 | sed 's/./&./6')"
```

Run k8s on all hosts at the same time:
```
$ CLUSTER_ID_OR_NAME="my-cluster"
$ NETADDR="192.168.56.0/24"
$ docker pull cdxvirt/k8sup:k8s-1.11
$ docker run -d \
    --privileged \
    --net=host \
    --pid=host \
    --restart=always \
    -v /run/torcx/bin/docker:/bin/docker:ro \
    -v /run/systemd:/run/systemd \
    -v /etc/modprobe.d/:/etc/modprobe.d \
    -v /etc/systemd/network/:/etc/systemd/network \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /run/torcx/unpack/docker/lib:/host/lib:ro \
    -v /lib/modules:/lib/modules:ro \
    -v /etc/cni:/etc/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /var/lib/etcd:/var/lib/etcd \
    -v /var/lib/kubelet:/var/lib/kubelet \
    -v /etc/kubernetes:/etc/kubernetes \
    --name=k8sup \
    cdxvirt/k8sup:k8s-1.11 \
    --token=${TOKEN} \
    --unsafe-skip-ca-verification \
    --cluster="${CLUSTER_ID_OR_NAME}" \
    --network="${NETADDR}"; \
      && docker logs -f k8sup
```

---

Download kubectl:
```
$ sudo -i
  RELEASE="$(curl -sSL "https://dl.k8s.io/release/stable.txt")"; \
  mkdir -p /opt/bin; \
  cd /opt/bin; \
  curl -L --remote-name-all \
  "https://storage.googleapis.com/kubernetes-release/release/${RELEASE}/bin/linux/amd64/kubectl"; \
  chmod +x kubectl
```

Setup kubectl:
```
$ sudo mkdir -p /root/.kube; \
  sudo cp -i /etc/kubernetes/kubeconfig /root/.kube/config; \
  echo "alias kubectl='sudo kubectl'" >> ~/.bashrc; source ~/.bashrc
```

---

Stop k8sup on a node and **remove** the node from the cluster:
```
$ kubectl delete node "$(hostname)"; \
  etcdctl member remove "$(etcdctl member list \
    | grep "$(hostname)" \
    | awk '{print $1}' \
    | sed 's/.$//')" ;\
  docker rm -fv k8sup-kubelet k8sup-etcd k8sup; \
  docker rm -fv $(docker ps -a --filter name=k8s_ -q); \
  awk '$2 ~ path {print $2}' path=/var/lib/kubelet /proc/mounts \
    | sudo xargs -r umount; \
  sudo rm -rf \
    /var/lib/etcd/* \
    /var/lib/kubelet \
    /etc/kubernetes
```

Stop k8sup on a node and **keep** the node in the cluster:
```
$ docker rm -fv k8sup-kubelet k8sup-etcd k8sup; \
  docker rm -fv $(docker ps -a --filter name=k8s_ -q); \
  awk '$2 ~ path {print $2}' path=/var/lib/kubelet /proc/mounts \
    | sudo xargs -r umount
```

Show k8sup log and Cluster ID:
```
$ docker logs k8sup
```

If you want to delete etcd data:
```
$ sudo rm -rf /var/lib/etcd/*
```

---

Dashboard:

1. Get a Bearer Token of the 'admin-user' Service Account:
```
$ SECRET="$(kubectl -n kube-system get sa admin-user -o yaml \
    | awk '/admin-user-token/ {print $3}')"; \
  kubectl -n kube-system describe secret "${SECRET}" \
  | sed -n 's/token:\s*\(.*\)/\1/p'
```

2. Use SSH tunnel to connect your local machine to the one of master node.

   SSH tunnel example:
```
$ SSH_USER="core"
$ K8S_NODE_IP="192.168.56.101"
$ ssh "${SSH_USER}@${K8S_NODE_IP}" -L 8001:localhost:8001
```

3. Create a secure channel to your kube-apiserver. Run the following command on the node where you connected by SSH tunnel:
```
$ kubectl proxy
```
Now access Dashboard at:  
http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/

4. Use the Bearer Token to login the Dashboard.

In other words, the Dashboard can **only** be accessed from the machine where the command is executed. So You can use SSH tunnel to connect your local machine to the one of master node then start kubectl proxy **or** run kubectl proxy directly on your local machine with your kubeconfig.

---

NOTE:

1. If you want to use Ceph RBD mapping with k8sup, make sure that the 'rbd.ko' kernel object file, the 'modprobe' command file, and either the 'rbd' command file or the host path '/opt/bin' are mounted to the k8sup container as volumes.

2. k8sup ships with a default ntp service to synchronize system time of whole cluster. If a node is running other NTP client already, k8sup will not synchronize system time for this node, so you need to ensure all cluster nodes have the same system time by yourself.

3. Running k8sup on Ubuntu 16.04.2 <br /> https://gist.github.com/hsfeng/7fa5b57b68a62d7f14f3a10fc7db46cf <br />
