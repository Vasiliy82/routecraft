package openwrt

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"reflect"
	"regexp"
)

var deviceName = regexp.MustCompile(`^[a-zA-Z0-9_.-]+$`)

// DNSUCIRequest creates a scoped DNS configuration request. An empty plan is
// a no-op and must not be sent as a UCI set call.
func DNSUCIRequest(plan DNSPlan, session string) ([]byte, error) {
	if !logicalName.MatchString(plan.Section) || !sessionID.MatchString(session) {
		return nil, fmt.Errorf("invalid DNS section or UCI session")
	}
	values := make(map[string]any)
	for key, value := range plan.Options {
		if key != "port" || value != "53" {
			return nil, fmt.Errorf("unsupported DNS option")
		}
		values[key] = value
	}
	for key, list := range plan.OptionLists {
		if (key != "interface" && key != "listen_address") || len(list) == 0 {
			return nil, fmt.Errorf("unsupported DNS list")
		}
		for _, value := range list {
			if key == "interface" && !deviceName.MatchString(value) {
				return nil, fmt.Errorf("invalid DNS interface")
			}
			if key == "listen_address" {
				addr, err := netip.ParseAddr(value)
				if err != nil || addr.Zone() != "" || addr.IsMulticast() {
					return nil, fmt.Errorf("invalid DNS listen address")
				}
			}
		}
		values[key] = list
	}
	if len(values) == 0 {
		return nil, fmt.Errorf("empty DNS plan")
	}
	return json.Marshal(map[string]any{"ubus_rpc_session": session, "config": "dhcp", "section": plan.Section, "values": values})
}

// VerifyDNSRestored compares only options changed by the DNS plan.
func VerifyDNSRestored(plan DNSPlan, before, current []byte) error {
	read := func(data []byte) (map[string]any, error) {
		var status struct {
			Values map[string]any `json:"values"`
		}
		if err := json.Unmarshal(data, &status); err != nil || status.Values == nil {
			return nil, fmt.Errorf("invalid UCI snapshot")
		}
		return status.Values, nil
	}
	a, err := read(before)
	if err != nil {
		return err
	}
	b, err := read(current)
	if err != nil {
		return err
	}
	keys := make(map[string]bool)
	for k := range plan.Options {
		keys[k] = true
	}
	for k := range plan.OptionLists {
		keys[k] = true
	}
	if len(keys) == 0 {
		return fmt.Errorf("empty DNS plan")
	}
	for key := range keys {
		av, aok := a[key]
		bv, bok := b[key]
		if aok != bok || !reflect.DeepEqual(av, bv) {
			return fmt.Errorf("DNS option %q was not restored", key)
		}
	}
	return nil
}
