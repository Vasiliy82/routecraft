package openwrt

import (
	"fmt"
	"net/netip"
	"strconv"
)

// DNSPlan proposes only dnsmasq binding changes. It does not enable a service,
// resolve port ownership, or prove that queries from clients reach it.
type DNSPlan struct {
	Section     string              `json:"section"`
	Options     map[string]string   `json:"options"`
	OptionLists map[string][]string `json:"option_lists,omitempty"`
}

func contains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

// PlanDNS requires a single explicit instance and preserves its existing
// bindings. noPortConflict must be established separately before adding a
// listener or enabling DNS; it must account for ownership of existing sockets.
func PlanDNS(instances []DNSInstance, logical, device string, ipv4, ipv6 netip.Addr, noPortConflict bool) (DNSPlan, error) {
	if len(instances) != 1 {
		return DNSPlan{}, fmt.Errorf("DNS instance is missing or ambiguous")
	}
	if !logicalName.MatchString(logical) || !deviceName.MatchString(device) {
		return DNSPlan{}, fmt.Errorf("invalid LAN interface")
	}
	if !ipv4.Is4() || ipv4.IsUnspecified() || ipv4.IsMulticast() || ipv4.IsLoopback() || !ipv6.Is6() || ipv6.Is4In6() || ipv6.IsUnspecified() || ipv6.IsMulticast() || ipv6.IsLoopback() || ipv6.Zone() != "" {
		return DNSPlan{}, fmt.Errorf("valid LAN IPv4 and IPv6 addresses are required")
	}
	instance := instances[0]
	if !logicalName.MatchString(instance.Name) {
		return DNSPlan{}, fmt.Errorf("invalid dnsmasq section")
	}
	for _, name := range append(append([]string(nil), instance.Interfaces...), instance.ExcludedInterfaces...) {
		if !deviceName.MatchString(name) {
			return DNSPlan{}, fmt.Errorf("wildcard or unsupported DNS interface restriction requires review")
		}
	}
	if contains(instance.ExcludedInterfaces, logical) || contains(instance.ExcludedInterfaces, device) {
		return DNSPlan{}, fmt.Errorf("LAN is excluded by dnsmasq; review is required")
	}
	plan := DNSPlan{Section: instance.Name, Options: map[string]string{}}
	if instance.Port != "" {
		port, err := strconv.Atoi(instance.Port)
		if err != nil || (port != 0 && port != 53) {
			return DNSPlan{}, fmt.Errorf("dnsmasq uses an unsupported DNS port")
		}
		if port == 0 {
			if !noPortConflict {
				return DNSPlan{}, fmt.Errorf("DNS port availability is not confirmed")
			}
			plan.Options["port"] = "53"
		}
	}
	for _, raw := range instance.ListenAddresses {
		addr, err := netip.ParseAddr(raw)
		if err != nil || addr.Zone() != "" {
			return DNSPlan{}, fmt.Errorf("unsupported dnsmasq listen address")
		}
	}
	if len(instance.Interfaces) > 0 {
		if !contains(instance.Interfaces, logical) && !contains(instance.Interfaces, device) {
			if !noPortConflict {
				return DNSPlan{}, fmt.Errorf("DNS port conflict check is required")
			}
			plan.OptionLists = map[string][]string{"interface": append(append([]string(nil), instance.Interfaces...), logical)}
		}
	} else if len(instance.ListenAddresses) > 0 {
		addresses := append([]string(nil), instance.ListenAddresses...)
		if !contains(addresses, ipv4.String()) {
			addresses = append(addresses, ipv4.String())
		}
		if !contains(addresses, ipv6.String()) {
			addresses = append(addresses, ipv6.String())
		}
		if len(addresses) != len(instance.ListenAddresses) {
			if !noPortConflict {
				return DNSPlan{}, fmt.Errorf("DNS port conflict check is required")
			}
			plan.OptionLists = map[string][]string{"listen_address": addresses}
		}
	}
	return plan, nil
}
