package openwrt

import (
	"encoding/json"
	"testing"
)

func TestDHCPUCIRequestScopesSectionAndOptions(t *testing.T) {
	plan := DHCPPlan{Options: map[string]string{"ignore": "1", "dhcpv6": "disabled"}}
	data, err := DHCPUCIRequest(plan, "lan", "0123456789abcdef0123456789abcdef")
	if err != nil {
		t.Fatal(err)
	}
	var request struct {
		Config  string         `json:"config"`
		Section string         `json:"section"`
		Values  map[string]any `json:"values"`
	}
	if err := json.Unmarshal(data, &request); err != nil {
		t.Fatal(err)
	}
	if request.Config != "dhcp" || request.Section != "lan" || request.Values["ignore"] != "1" {
		t.Fatalf("unexpected request %+v", request)
	}
	plan.Options["interface"] = "other"
	if _, err := DHCPUCIRequest(plan, "lan", "0123456789abcdef0123456789abcdef"); err == nil {
		t.Fatal("accepted unsupported option")
	}
	if _, err := DHCPUCIRequest(DHCPPlan{Options: map[string]string{"ignore": "1"}}, "bad name", "0123456789abcdef0123456789abcdef"); err == nil {
		t.Fatal("accepted invalid section")
	}
}

func TestDHCPUCIRequestValidatesAddressLists(t *testing.T) {
	plan := DHCPPlan{Options: map[string]string{"dhcpv6": "server"}, OptionLists: map[string][]string{"dns": {"fd00::1"}, "router": {"192.0.2.1"}}}
	data, err := DHCPUCIRequest(plan, "lan", "0123456789abcdef0123456789abcdef")
	if err != nil {
		t.Fatal(err)
	}
	var request struct {
		Values map[string]any `json:"values"`
	}
	if err := json.Unmarshal(data, &request); err != nil {
		t.Fatal(err)
	}
	if _, ok := request.Values["dns"].([]any); !ok {
		t.Fatal("DNS addresses were not encoded as a list")
	}
	plan.OptionLists["router"] = []string{"fd00::1"}
	if _, err := DHCPUCIRequest(plan, "lan", "0123456789abcdef0123456789abcdef"); err == nil {
		t.Fatal("accepted non-IPv4 DHCPv4 router")
	}
}
