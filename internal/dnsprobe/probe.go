// Package dnsprobe verifies a DNS listener using both UDP and TCP.
package dnsprobe

import (
	"context"
	"fmt"
	"net"
	"strings"
	"time"
)

// Check resolves name through server over UDP and TCP independently. server is
// host:port and name must be an absolute DNS name. It checks listener behavior,
// not DNS advertisement, policy isolation, or the path used by LAN clients.
func Check(ctx context.Context, server, name string) error {
	if err := validateProbe(server, name); err != nil {
		return err
	}
	return check(ctx, server, name)
}

// Wait retries the UDP and TCP check until both succeed or ctx expires.
func Wait(ctx context.Context, server, name string) error {
	if err := validateProbe(server, name); err != nil {
		return err
	}
	for {
		probeCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		err := check(probeCtx, server, name)
		cancel()
		if err == nil {
			return nil
		}

		timer := time.NewTimer(time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return fmt.Errorf("DNS listener did not become ready: %w (last probe: %v)", ctx.Err(), err)
		case <-timer.C:
		}
	}
}

func validateProbe(server, name string) error {
	if _, _, err := net.SplitHostPort(server); err != nil {
		return fmt.Errorf("invalid DNS server: %w", err)
	}
	if name == "" || !strings.HasSuffix(name, ".") {
		return fmt.Errorf("DNS probe name must be absolute")
	}
	return nil
}

func check(ctx context.Context, server, name string) error {
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
