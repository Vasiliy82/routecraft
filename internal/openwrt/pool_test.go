package openwrt

import (
	"net/netip"
	"testing"
)

func TestIPv4PoolValidation(t *testing.T) {
	valid := IPv4Pool{Prefix: netip.MustParsePrefix("192.0.2.1/24"), Router: netip.MustParseAddr("192.0.2.1"), Start: 10, Limit: 20}
	tests := []struct {
		name   string
		change func(*IPv4Pool)
		ok     bool
	}{
		{"valid", func(*IPv4Pool) {}, true},
		{"router in pool", func(p *IPv4Pool) { p.Router = netip.MustParseAddr("192.0.2.11") }, false},
		{"outside subnet", func(p *IPv4Pool) { p.Router = netip.MustParseAddr("198.51.100.1") }, false},
		{"network address", func(p *IPv4Pool) { p.Router = netip.MustParseAddr("192.0.2.0") }, false},
		{"broadcast included", func(p *IPv4Pool) { p.Start = 254; p.Limit = 2 }, false},
		{"zero limit", func(p *IPv4Pool) { p.Limit = 0 }, false},
		{"overflow", func(p *IPv4Pool) { p.Start = ^uint32(0); p.Limit = ^uint32(0) }, false},
		{"host subnet", func(p *IPv4Pool) {
			p.Prefix = netip.MustParsePrefix("192.0.2.0/31")
			p.Router = netip.MustParseAddr("192.0.2.1")
		}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := valid
			tc.change(&p)
			if err := p.Validate(); (err == nil) != tc.ok {
				t.Fatalf("error = %v", err)
			}
		})
	}
}
