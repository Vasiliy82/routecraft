package openwrt

import (
	"net/netip"
	"reflect"
	"testing"
)

func TestPlanDHCPExternalLeavesOptionsAndRAUntouched(t *testing.T) {
	plan, err := PlanDHCP("external", "keep", "dnsmasq", IPv4Pool{}, netip.Addr{}, []string{"tag:client,6,192.0.2.1"})
	if err != nil || plan.ReplaceDHCPOptions || plan.Options["ignore"] != "1" || plan.Options["dhcpv6"] != "disabled" {
		t.Fatalf("plan %+v error %v", plan, err)
	}
	if _, ok := plan.Options["ra"]; ok {
		t.Fatal("RA unexpectedly changed")
	}
}

func TestPlanDHCPManagedPreservesOtherOptions(t *testing.T) {
	pool := IPv4Pool{Prefix: netip.MustParsePrefix("192.0.2.0/24"), Router: netip.MustParseAddr("192.0.2.1"), Start: 10, Limit: 20}
	plan, err := PlanDHCP("managed", "server", "dnsmasq", pool, netip.MustParseAddr("fd00::1"), []string{"42,192.0.2.2", "3,192.0.2.3", "6,192.0.2.4"})
	want := []string{"42,192.0.2.2", "3,192.0.2.1", "6,192.0.2.1"}
	if err != nil || !reflect.DeepEqual(plan.DHCPOptions, want) || plan.Options["dhcpv4"] != "disabled" || plan.Options["dhcpv6"] != "server" {
		t.Fatalf("plan %+v error %v", plan, err)
	}
	if !reflect.DeepEqual(plan.OptionLists["dns"], []string{"fd00::1"}) || plan.Options["ra_dns"] != "1" {
		t.Fatalf("unexpected IPv6 DNS plan: %+v", plan)
	}
	if _, err := PlanDHCP("managed", "server", "dnsmasq", pool, netip.MustParseAddr("fd00::1"), []string{"tag:guest,6,192.0.2.4"}); err == nil {
		t.Fatal("accepted scoped option")
	}
}

func TestPlanDHCPRejectsUnknownModesAndSelectsBackend(t *testing.T) {
	pool := IPv4Pool{Prefix: netip.MustParsePrefix("192.0.2.0/24"), Router: netip.MustParseAddr("192.0.2.1"), Start: 10, Limit: 20}
	plan, err := PlanDHCP("managed", "disabled", "odhcpd", pool, netip.MustParseAddr("fd00::1"), nil)
	if err != nil || plan.Options["dhcpv4"] != "server" || plan.Options["ra"] != "disabled" {
		t.Fatalf("plan %+v error %v", plan, err)
	}
	if !reflect.DeepEqual(plan.OptionLists["router"], []string{"192.0.2.1"}) || !reflect.DeepEqual(plan.OptionLists["dns"], []string{"192.0.2.1", "fd00::1"}) {
		t.Fatalf("unexpected odhcpd plan: %+v", plan)
	}
	if _, err := PlanDHCP("managed", "server", "dnsmasq", pool, netip.Addr{}, nil); err == nil {
		t.Fatal("accepted missing IPv6 DNS")
	}
	for _, args := range [][3]string{{"bad", "keep", "dnsmasq"}, {"managed", "bad", "dnsmasq"}, {"managed", "keep", "bad"}} {
		if _, err := PlanDHCP(args[0], args[1], args[2], pool, netip.MustParseAddr("fd00::1"), nil); err == nil {
			t.Fatalf("accepted %+v", args)
		}
	}
}
