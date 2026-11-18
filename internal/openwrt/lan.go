package openwrt

import (
	"fmt"
	"net/netip"
)

// ValidateLANAddresses ensures the proposed DHCP gateway and DNS addresses
// are actually assigned to the selected, active logical interface. It does
// not prove DNS is listening or that an IPv6 prefix can be delegated.
func ValidateLANAddresses(iface LogicalInterface, pool IPv4Pool, dns6 netip.Addr) error {
	if !iface.Up || iface.Dynamic {
		return fmt.Errorf("LAN logical interface must be active and non-dynamic")
	}
	if err := pool.Validate(); err != nil {
		return err
	}
	found4 := false
	for _, raw := range iface.IPv4 {
		prefix, err := netip.ParsePrefix(raw)
		if err != nil || !prefix.Addr().Is4() {
			return fmt.Errorf("invalid LAN IPv4 address")
		}
		if prefix.Addr() == pool.Router && prefix.Masked() == pool.Prefix.Masked() {
			found4 = true
		}
	}
	if !found4 {
		return fmt.Errorf("DHCP gateway is not assigned to the selected LAN prefix")
	}
	if !dns6.Is6() || dns6.Is4In6() || dns6.IsUnspecified() || dns6.IsMulticast() || dns6.Zone() != "" {
		return fmt.Errorf("invalid IPv6 DNS address")
	}
	for _, raw := range iface.IPv6 {
		prefix, err := netip.ParsePrefix(raw)
		if err != nil || !prefix.Addr().Is6() {
			return fmt.Errorf("invalid LAN IPv6 address")
		}
		if prefix.Addr() == dns6 {
			return nil
		}
	}
	return fmt.Errorf("IPv6 DNS address is not assigned to selected LAN")
}
