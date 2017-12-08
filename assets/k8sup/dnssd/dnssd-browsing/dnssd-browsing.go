package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"time"

	"github.com/grandcat/zeroconf"
)

var (
	service  = flag.String("service", "_cdxvirt._tcp", "Set the service category to look for devices.")
	domain   = flag.String("domain", "local.", "Set the search domain. For local networks, default is fine.")
	waitTime = flag.Int("wait", 5, "Duration in [s] to run discovery.")
)

func main() {
	flag.Parse()

	resolver, err := zeroconf.NewResolver(nil)
	if err != nil {
		log.Fatalln("Failed to initialize resolver:", err.Error())
	}

	entries := make(chan *zeroconf.ServiceEntry)
	go func(results <-chan *zeroconf.ServiceEntry) {
		for entry := range results {
			fmt.Printf("%s %s:%d %s %s\n", entry.HostName, entry.AddrIPv4, entry.Port, entry.Text, entry.ServiceInstanceName())
		}
		log.Println("No more entries.")
	}(entries)

	// Send the "stop browsing" signal after the desired timeout
	ctx, cancel := context.WithTimeout(context.Background(), time.Second*time.Duration(*waitTime))
	defer cancel()
	err = resolver.Browse(ctx, *service, *domain, entries)
	if err != nil {
		log.Fatalln("Failed to browse:", err.Error())
	}

	<-ctx.Done()
	// Wait some additional time to see debug messages on go routine shutdown.
	time.Sleep(1e9)
}
