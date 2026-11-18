package openwrt

import (
	"net/netip"
	"testing"
)

func TestValidateLANAddressesRequiresAssignedAddresses(t *testing.T) {
	iface := LogicalInterface{Name: "lan", Up: true, IPv4: []string{"192.0.2.1/24"}, IPv6: []string{"fd00::1/64"}}
	pool := IPv4Pool{Prefix: netip.MustParsePrefix("192.0.2.0/24"), Router: netip.MustParseAddr("192.0.2.1"), Start: 10, Limit: 20}
	if err := ValidateLANAddresses(iface, pool, netip.MustParseAddr("fd00::1")); err != nil {
		t.Fatal(err)
	}
	if err := ValidateLANAddresses(iface, pool, netip.MustParseAddr("fd00::2")); err == nil {
		t.Fatal("accepted unassigned IPv6")
	}
	pool.Router = netip.MustParseAddr("192.0.2.2")
	if err := ValidateLANAddresses(iface, pool, netip.MustParseAddr("fd00::1")); err == nil {
		t.Fatal("accepted unassigned IPv4")
	}
}
