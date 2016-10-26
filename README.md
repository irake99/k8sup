# k8sup

Using One Docker container to bootstrap a HA Kubernetes cluster with auto service discovery.

Default behavior: If only one cluster is discovered, auto join it. If more than one cluster are discovered, start a new cluster.

You still can join a specified cluster or force to start a new cluster.

<pre>
Options:
-n, --network=NETINFO        SubnetID/Mask or Host IP address or NIC name
                             e. g. "192.168.11.0/24" or "192.168.11.1"
                             or "eth0" (Required option)
-c, --cluster=CLUSTER_ID     Join a specified cluster
    --new                    Force to start a new cluster
-p, --proxy                  Force to run as etcd and k8s proxy
-h, --help                   This help text
</pre>

Run k8s:
<pre>
$ sudo docker run -d \
    --privileged \
    --net=host \
    --pid=host \
    --restart=always \
    -v $(which docker):/bin/docker \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/lib/libdevmapper.so:/usr/lib/$(readlink /usr/lib/libdevmapper.so | xargs basename) \
    -v /lib/modules:/lib/modules:ro \
    -v /etc/cni:/etc/cni \
    -v /opt/cni:/opt/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /var/lib/etcd:/var/lib/etcd \
    -v /etc/kubernetes:/etc/kubernetes \
    --name=k8sup \
    cdxvirt/k8sup \
    --network={your-subnet-id/mask}
</pre>

Stop k8s:
<pre>
$ sudo docker exec k8sup /go/kube-down
</pre>

Show k8sup log and Cluster ID:
<pre>
$ sudo docker logs k8sup
</pre>

If you want to delete etcd data:
<pre>
$ sudo rm -rf /var/lib/etcd/*
</pre>
