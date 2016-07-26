FROM golang:1.6.3
MAINTAINER hsfeng@gmail.com

RUN apt-get -y update

RUN apt-get -y install net-tools jq iptables vim

RUN git clone https://github.com/containernetworking/cni.git
RUN git clone https://github.com/hsfeng/hyperkube-utils-on-coreos.git

ADD 10-containernet.conf /go/10-containernet.conf
ADD 99-loopback.conf /go/99-loopback.conf
ADD kube-up /go/kube-up

WORKDIR /go/cni

RUN ./build

ADD entrypoint.sh /go/entrypoint.sh
RUN chmod +x /go/entrypoint.sh
RUN chmod +x /go/kube-up

ENTRYPOINT ["/go/entrypoint.sh"]
CMD []
