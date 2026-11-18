package openwrt

import (
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// DHCPPlan is a proposed change to one existing DHCP section, never applied by
// this package. The caller must snapshot, display, apply and verify it.
type DHCPPlan struct {
	Options            map[string]string   `json:"options"`
	OptionLists        map[string][]string `json:"option_lists,omitempty"`
	DHCPOptions        []string            `json:"dhcp_options,omitempty"`
	ReplaceDHCPOptions bool                `json:"replace_dhcp_options"`
}

// PlanDHCP produces changes for the explicitly selected one-arm mode. ra is
// "keep", "server", or "disabled"; DHCPv4 ownership is dnsmasq or odhcpd.
// Existing scoped or symbolic DHCP options are rejected when managing DHCP,
// because silently replacing gateway/DNS in them could affect other clients.
func PlanDHCP(mode, ra, backend string, pool IPv4Pool, dns6 netip.Addr, oldOptions []string) (DHCPPlan, error) {
	if ra != "keep" && ra != "server" && ra != "disabled" {
		return DHCPPlan{}, fmt.Errorf("explicit RA mode is required")
	}
	if backend != "dnsmasq" && backend != "odhcpd" {
		return DHCPPlan{}, fmt.Errorf("unknown DHCPv4 backend")
	}
	result := DHCPPlan{Options: map[string]string{}}
	if ra != "keep" {
		result.Options["ra"] = ra
	}
	switch mode {
	case "external":
		result.Options["ignore"] = "1"
		result.Options["dhcpv4"] = "disabled"
		result.Options["dhcpv6"] = "disabled"
		return result, nil
	case "managed":
		if err := pool.Validate(); err != nil {
			return DHCPPlan{}, err
		}
		if !dns6.Is6() || dns6.Is4In6() || dns6.IsUnspecified() || dns6.IsMulticast() || dns6.Zone() != "" {
			return DHCPPlan{}, fmt.Errorf("a usable local IPv6 DNS address is required")
		}
		result.Options["ignore"] = "0"
		result.Options["dhcpv6"] = "server"
		result.OptionLists = map[string][]string{"dns": {dns6.String()}}
		if ra == "server" {
			result.Options["ra_dns"] = "1"
		}
		if backend == "odhcpd" {
			result.Options["dhcpv4"] = "server"
			result.OptionLists["router"] = []string{pool.Router.String()}
			result.OptionLists["dns"] = append([]string{pool.Router.String()}, result.OptionLists["dns"]...)
		} else {
			result.Options["dhcpv4"] = "disabled"
		}
		result.Options["start"] = strconv.FormatUint(uint64(pool.Start), 10)
		result.Options["limit"] = strconv.FormatUint(uint64(pool.Limit), 10)
		result.ReplaceDHCPOptions = true
		for _, option := range oldOptions {
			code, _, found := strings.Cut(option, ",")
			if !found || code == "" {
				return DHCPPlan{}, fmt.Errorf("cannot safely inspect existing DHCP option")
			}
			number, err := strconv.Atoi(code)
			if err != nil || number < 1 || number > 254 {
				return DHCPPlan{}, fmt.Errorf("scoped or symbolic DHCP options require manual review")
			}
			if number != 3 && number != 6 {
				result.DHCPOptions = append(result.DHCPOptions, option)
			}
		}
		result.DHCPOptions = append(result.DHCPOptions, "3,"+pool.Router.String(), "6,"+pool.Router.String())
		return result, nil
	default:
		return DHCPPlan{}, fmt.Errorf("unknown DHCP mode")
	}
}
