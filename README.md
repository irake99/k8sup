# k8sup

Using One Docker container to bootstrap a HA Kubernetes cluster with auto service discovery.

Default behavior: If only one cluster is discovered, auto join it. If more than one cluster are discovered, start a new cluster.

You still can join a specified cluster or force to start a new cluster.

<pre>
Options:
-i, --ip=IPADDR           Host IP address (Required)
-c, --cluster=CLUSTER_ID  Join a specified cluster
-n, --new                 Force to start a new cluster
-h, --help                This help text
</pre>

<pre>
$ git clone https://github.com/irake99/k8sup.git

$ cd k8sup

$ docker build -t k8sup .

$ sudo docker run -it \
    --privileged \
    --net=host \
    --pid=host \
    -v $(which docker):/bin/docker \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/lib/libdevmapper.so:/usr/lib/$(readlink /usr/lib/libdevmapper.so | xargs basename) \
    -v /etc/cni:/etc/cni \
    -v /opt/cni:/opt/cni \
    -v /var/lib/cni:/var/lib/cni \
    -v /etc/kubernetes:/etc/kubernetes \
    k8sup \
    --ip={your-host-ip}
</pre>

If you want to delete etcd data:
<pre>
$ sudo rm -rf /var/lib/etcd/*
</pre>
