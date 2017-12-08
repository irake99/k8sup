package main

import (
	"flag"
	"fmt"
	"log"
	"math/rand"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/grandcat/zeroconf"
)

var (
	IPMask       = flag.String("IPMask", "", "IP/mask for listening service, required flag.")
	Port         = flag.Int("port", 443, "Service port.")
	clusterID    = flag.String("clusterID", "", "Cluster ID, required flag.")
	creator      = flag.String("creator", "false", "Is the node first started. (default \"false\")")
	started      = flag.String("started", "false", "Is the cluster started. (default \"false\")")
	UnixNanoTime = flag.String("unix-nano-time", "", "User specify the unix nano time")
	service      = flag.String("service", "_cdxvirt._tcp", "Set the service type of the new service.")
	domain       = flag.String("domain", "local.", "Set the network domain.")
)

func getInterfaceByIPNet(Net *net.IPNet) (*net.Interface, error) {
	ift, err := net.Interfaces()
	if err != nil {
		panic(err)
	}
	for _, iface := range ift {
		addrs, err := iface.Addrs()
		if err != nil {
			panic(err)
		}
		for _, addr := range addrs {
			IPaddr, _, _ := net.ParseCIDR(addr.String())
			if Net.Contains(IPaddr) {
				return &iface, nil
			}
		}
	}
	err = fmt.Errorf("No such interface by the given network: %s", Net.String())
	return nil, err
}

func main() {
	flag.Parse()
	if *IPMask == "" || *clusterID == "" {
		flag.PrintDefaults()
		os.Exit(1)
	}

	// Set the seed of ramdom number
	rand.Seed(time.Now().UnixNano())

	// Get hostname and network information
	NodeName, _ := os.Hostname()
	IPAddr, Network, err := net.ParseCIDR(*IPMask)
	if err != nil {
		panic(err)
	}
	IPAddrs := []string{IPAddr.String()}

	// Find the specific interface by IPNet for registering
	iface, err := getInterfaceByIPNet(Network)
	if err != nil {
		panic(err)
	}
	ifaces := []net.Interface{*iface}

	// Make the SRV text
	var SRVtext []string
	if *clusterID != "" {
		SRVtext = append(SRVtext, "clusterID="+*clusterID)
	}
	if *UnixNanoTime == "" {
		*UnixNanoTime = strconv.FormatInt(time.Now().UnixNano(), 10)
	}
	SRVtext = append(SRVtext, "IPAddr="+IPAddr.String())
	SRVtext = append(SRVtext, "Port="+strconv.Itoa(*Port))
	SRVtext = append(SRVtext, "Creator="+*creator)
	SRVtext = append(SRVtext, "Started="+*started)
	SRVtext = append(SRVtext, "NetworkID="+Network.String())
	SRVtext = append(SRVtext, "NodeName="+NodeName)
	SRVtext = append(SRVtext, "UnixNanoTime="+*UnixNanoTime)
	fmt.Printf("Registering: %s %s:%d %s %s\n", NodeName, IPAddr, *Port, *clusterID, iface.Name)

	// Make a uniq instance name
	Instance := fmt.Sprintf("%016X", rand.Int63())
	Instance = NodeName + "-" + Instance

	// Run registration (blocking call)
	s, err := zeroconf.RegisterProxy(Instance, *service, *domain, *Port, NodeName, IPAddrs, SRVtext, ifaces)
	if err != nil {
		log.Fatalln(err.Error())
	}
	defer s.Shutdown()

	// Ctrl+C handling
	fmt.Println("Press Ctrl+C to stop...")
	handler := make(chan os.Signal, 1)
	signal.Notify(handler, os.Interrupt, syscall.SIGTERM)
	select {
	case sig := <-handler:
		// Exit by user
		fmt.Println(sig)
		if sig == os.Interrupt {
			s.Shutdown()
			time.Sleep(1e9)
			os.Exit(0)
		}
	}
}
