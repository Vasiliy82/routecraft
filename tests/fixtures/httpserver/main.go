// Command httpserver is a local HTTP endpoint for sing-box integration tests.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
)

func main() {
	addr := flag.String("listen", "127.0.0.1:18080", "listen address")
	flag.Parse()
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "routecraft-test-ok")
	})
	log.Fatal(http.ListenAndServe(*addr, nil))
}
