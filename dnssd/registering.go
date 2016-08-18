package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"time"

	"github.com/oleksandr/bonjour"
)

func main() {
	if len(os.Args) != 5 {
		fmt.Printf("Usage: registering {Hostname} {IP} {Port} {etcd_cluster_ID}\n")
		return
	}
	Hostname := os.Args[1]
	IPAddr := os.Args[2]
	Port, _ := strconv.Atoi(os.Args[3])
	clusterID := os.Args[4]
	fmt.Printf("Registering: %s %s:%d %s\n", Hostname, IPAddr, Port, clusterID)
	// Run registration (blocking call)
	s, err := bonjour.RegisterProxy(clusterID, "_etcd._tcp", "", Port, Hostname, IPAddr, []string{clusterID}, nil)
	if err != nil {
		log.Fatalln(err.Error())
	}

	fmt.Println("Press Ctrl+C to stop...")
	// Ctrl+C handling
	handler := make(chan os.Signal, 1)
	signal.Notify(handler, os.Interrupt)
	for sig := range handler {
		if sig == os.Interrupt {
			s.Shutdown()
			time.Sleep(1e9)
			break
		}
	}
}
