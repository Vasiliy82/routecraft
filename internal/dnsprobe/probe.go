// Package dnsprobe verifies a DNS listener using both UDP and TCP.
package dnsprobe

import (
	"context"
	"fmt"
	"net"
	"strings"
)

// Check resolves name through server over UDP and TCP independently. server is
// host:port and name must be an absolute DNS name. It checks listener behavior,
// not DNS advertisement, policy isolation, or the path used by LAN clients.
func Check(ctx context.Context, server, name string) error {
	if _, _, err := net.SplitHostPort(server); err != nil {
		return fmt.Errorf("invalid DNS server: %w", err)
	}
	if name == "" || !strings.HasSuffix(name, ".") {
		return fmt.Errorf("DNS probe name must be absolute")
	}
	for _, transport := range []string{"udp", "tcp"} {
		dialer := net.Dialer{}
		resolver := net.Resolver{PreferGo: true, StrictErrors: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, transport, server)
		}}
		addresses, err := resolver.LookupIP(ctx, "ip4", name)
		if err != nil {
			return fmt.Errorf("DNS %s lookup failed: %w", transport, err)
		}
		if len(addresses) == 0 {
			return fmt.Errorf("DNS %s returned no IPv4 answer", transport)
		}
	}
	return nil
}
