FROM golang:1.6.3
MAINTAINER hsfeng@gmail.com

RUN apt-get -y update

RUN apt-get -y install net-tools jq iptables bc module-init-tools uuid-runtime psmisc ntpdate && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ToDo: Remove /go/heapster-1.2.0 (30MB) to save space?
RUN mkdir -p /go/downloads && curl -sfk -o /go/downloads/heapster.tar.gz -L https://github.com/kubernetes/heapster/archive/v1.2.0.tar.gz && tar xfz /go/downloads/heapster.tar.gz && rm -rf /go/downloads/heapster.tar.gz

RUN sed -i "s|^  labels:|  labels:\n    kubernetes.io/cluster-service: 'true'|g" /go/heapster-1.2.0/deploy/kube-config/influxdb/*-controller.yaml

COPY cni-conf /go/cni-conf
COPY kube-conf /go/kube-conf
COPY dnssd /go/dnssd
COPY flannel-conf /go/flannel-conf

WORKDIR /go

RUN go get "github.com/oleksandr/bonjour" \
    && go build -o /go/dnssd/registering /go/dnssd/registering.go \
    && go build -o /go/dnssd/browsing /go/dnssd/browsing.go

ADD runcom /go/runcom
ADD kube-up /go/kube-up
ADD kube-down /go/kube-down
ADD entrypoint.sh /go/entrypoint.sh
ADD cp-certs.sh /go/cp-certs.sh
ADD service-addons.sh /go/service-addons.sh

RUN chmod +x /go/entrypoint.sh
RUN chmod +x /go/kube-up

ENTRYPOINT ["/go/entrypoint.sh"]
CMD []
