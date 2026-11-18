package openwrt

import (
	"fmt"
	"net/netip"
)

// IPv4Pool validates dnsmasq's offset-based DHCP pool against a LAN prefix.
// Start and limit count addresses from the beginning of the subnet.
type IPv4Pool struct {
	Prefix netip.Prefix
	Router netip.Addr
	Start  uint32
	Limit  uint32
}

func (p IPv4Pool) Validate() error {
	if !p.Prefix.IsValid() || !p.Prefix.Addr().Is4() || !p.Router.Is4() {
		return fmt.Errorf("an IPv4 LAN prefix and router address are required")
	}
	prefix := p.Prefix.Masked()
	if !prefix.Contains(p.Router) {
		return fmt.Errorf("router is outside the LAN prefix")
	}
	bits := prefix.Bits()
	if bits > 30 {
		return fmt.Errorf("LAN prefix has no usable DHCP pool")
	}
	size := uint64(1) << uint(32-bits)
	baseBytes := prefix.Addr().As4()
	routerBytes := p.Router.As4()
	base := uint64(baseBytes[0])<<24 | uint64(baseBytes[1])<<16 | uint64(baseBytes[2])<<8 | uint64(baseBytes[3])
	router := uint64(routerBytes[0])<<24 | uint64(routerBytes[1])<<16 | uint64(routerBytes[2])<<8 | uint64(routerBytes[3])
	offset := router - base
	if offset == 0 || offset == size-1 {
		return fmt.Errorf("router is a network or broadcast address")
	}
	if p.Start == 0 || p.Limit == 0 {
		return fmt.Errorf("pool start and size must be positive")
	}
	first := uint64(p.Start)
	last := first + uint64(p.Limit) - 1
	if last >= size-1 {
		return fmt.Errorf("pool extends beyond usable LAN addresses")
	}
	if offset >= first && offset <= last {
		return fmt.Errorf("pool includes the router address")
	}
	return nil
}
