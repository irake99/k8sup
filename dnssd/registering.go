package main

import (
	"flag"
	"fmt"
	"log"
	"math/rand"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/grandcat/zeroconf"
)

var (
	IPMask      = flag.String("IPMask", "", "IP/mask for listening service, required flag.")
	Port        = flag.Int("port", 2379, "etcd port.")
	clusterID   = flag.String("clusterID", "", "Cluster ID, required flag.")
	etcdProxy   = flag.String("etcdProxy", "false", "Is this node running on etcd proxy node. (default \"false\")")
	etcdStarted = flag.String("etcdStarted", "false", "Is the etcd service started. (default \"false\")")
	service     = flag.String("service", "_etcd._tcp", "Set the service type of the new service.")
	domain      = flag.String("domain", "local.", "Set the network domain.")
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
	SRVtext = append(SRVtext, "IPAddr="+IPAddr.String())
	SRVtext = append(SRVtext, "etcdPort="+strconv.Itoa(*Port))
	SRVtext = append(SRVtext, "etcdProxy="+*etcdProxy)
	SRVtext = append(SRVtext, "etcdStarted="+*etcdStarted)
	SRVtext = append(SRVtext, "NetworkID="+Network.String())
	SRVtext = append(SRVtext, "NodeName="+NodeName)
	SRVtext = append(SRVtext, "UnixNanoTime="+strconv.FormatInt(time.Now().UnixNano(), 10))
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

	// etcd health check (If it down, stop mDNS)
	if *etcdStarted == "true" {
		go func() {
			client := &http.Client{
				Timeout: time.Duration(5e9),
			}
			etcdURL := "http://127.0.0.1:" + strconv.Itoa(*Port) + "/health"
			for {
				// Check etcd every 5 seconds
				time.Sleep(5e9)
				_, err := client.Get(etcdURL)
				if err != nil {
					fmt.Println("mDNS stopped!")
					s.Shutdown()
					time.Sleep(1e9)
					os.Exit(0)
				}
			}
		}()
	}

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
