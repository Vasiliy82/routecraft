package openwrt

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"regexp"
	"strconv"
)

var sessionID = regexp.MustCompile(`^[a-f0-9]{32}$`)

// DHCPUCIRequest constructs an rpcd set request for exactly one DHCP section.
// A short-lived, scoped session isolates pending changes from other UCI users.
func DHCPUCIRequest(plan DHCPPlan, section, session string) ([]byte, error) {
	if !logicalName.MatchString(section) || !sessionID.MatchString(session) {
		return nil, fmt.Errorf("invalid DHCP section or UCI session")
	}
	allowed := map[string]bool{"ignore": true, "dhcpv4": true, "dhcpv6": true, "ra": true, "ra_dns": true, "start": true, "limit": true}
	values := make(map[string]any, len(plan.Options)+1)
	for name, value := range plan.Options {
		if !allowed[name] {
			return nil, fmt.Errorf("unexpected DHCP option %q", name)
		}
		switch name {
		case "ignore", "ra_dns":
			if value != "0" && value != "1" {
				return nil, fmt.Errorf("invalid ignore value")
			}
		case "dhcpv4", "dhcpv6", "ra":
			if value != "disabled" && value != "server" {
				return nil, fmt.Errorf("invalid %s mode", name)
			}
		case "start", "limit":
			n, err := strconv.ParseUint(value, 10, 32)
			if err != nil || n == 0 || strconv.FormatUint(n, 10) != value {
				return nil, fmt.Errorf("invalid %s value", name)
			}
		}
		values[name] = value
	}
	for name, list := range plan.OptionLists {
		if name != "dns" && name != "router" {
			return nil, fmt.Errorf("unexpected DHCP list %q", name)
		}
		if len(list) == 0 {
			return nil, fmt.Errorf("empty DHCP list %q", name)
		}
		for _, raw := range list {
			addr, err := netip.ParseAddr(raw)
			if err != nil || addr.Zone() != "" || addr.IsUnspecified() || addr.IsMulticast() || (name == "router" && !addr.Is4()) {
				return nil, fmt.Errorf("invalid address in DHCP list %q", name)
			}
		}
		values[name] = list
	}
	if plan.ReplaceDHCPOptions {
		values["dhcp_option"] = plan.DHCPOptions
	}
	if len(values) == 0 {
		return nil, fmt.Errorf("empty DHCP plan")
	}
	return json.Marshal(map[string]any{"ubus_rpc_session": session, "config": "dhcp", "section": section, "values": values})
}
