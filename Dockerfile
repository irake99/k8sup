FROM golang:1.7.5
MAINTAINER hsfeng@gmail.com

RUN apt-get -y update

RUN apt-get -y install net-tools jq iptables bc module-init-tools uuid-runtime ntpdate && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY cni-conf /go/cni-conf
COPY kube-conf /go/kube-conf
COPY dnssd /go/dnssd
COPY flannel-conf /go/flannel-conf

WORKDIR /go

RUN mkdir -p /go/src \
    && ln -s /go/dnssd /go/src/dnssd \
    && go get -u github.com/kardianos/govendor \
    && cd /go/src/dnssd \
    && govendor sync \
    && go build -o /go/src/dnssd/registering /go/src/dnssd/registering.go \
    && go build -o /go/src/dnssd/browsing /go/src/dnssd/browsing.go

ADD runcom /go/runcom
ADD kube-up /go/kube-up
ADD kube-down /go/kube-down
ADD k8sup.sh /go/k8sup.sh
ADD cp-certs.sh /go/cp-certs.sh
ADD kube-conf/abac-policy-file.jsonl /go/abac-policy-file.jsonl
ADD kube-conf/rbac-basic-binding.yaml /go/rbac-basic-binding.yaml
ADD setup-files.sh /go/setup-files.sh
ADD copy-addons.sh /go/copy-addons.sh
ADD make-ca-cert.sh /go/make-ca-cert.sh
ADD service-addons.sh /go/service-addons.sh

ADD https://storage.googleapis.com/kubernetes-release/easy-rsa/easy-rsa.tar.gz /go/easy-rsa.tar.gz

RUN chmod +x /go/k8sup.sh
RUN chmod +x /go/kube-up

ENTRYPOINT ["/go/k8sup.sh"]
CMD []
