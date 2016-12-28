FROM scratch
MAINTAINER hsfeng@gmail.com

ADD rootfs.tar.gz /
WORKDIR /go

# TODO: Remove /go/heapster-1.2.0(30MB) to save space?
RUN mkdir -p /go/downloads && curl -k -o /go/downloads/heapster.tar.gz -L https://github.com/kubernetes/heapster/archive/v1.2.0.tar.gz 
RUN tar -xvf /go/downloads/heapster.tar.gz && rm -rf /go/downloads/heapster.tar.gz

COPY cni-conf /go/cni-conf
COPY kube-conf /go/kube-conf
COPY dnssd /go/dnssd
COPY flannel-conf /go/flannel-conf

ADD kube-up /go/kube-up
ADD kube-down /go/kube-down
ADD entrypoint.sh /go/entrypoint.sh
ADD cp-certs.sh /go/cp-certs.sh
ADD update-addons.sh /go/update-addons.sh

RUN chmod +x /go/entrypoint.sh
RUN chmod +x /go/kube-up

ENTRYPOINT ["/go/entrypoint.sh"]
CMD []
