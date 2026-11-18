package openwrt

import (
	"net/netip"
	"reflect"
	"testing"
)

func TestPlanDNSPreservesBindingsAndRejectsConflicts(t *testing.T) {
	ip4, ip6 := netip.MustParseAddr("192.0.2.1"), netip.MustParseAddr("fd00::1")
	inst := DNSInstance{Name: "main", Port: "53", Interfaces: []string{"guest"}}
	plan, err := PlanDNS([]DNSInstance{inst}, "lan", "br-lan", ip4, ip6, true)
	if err != nil || !reflect.DeepEqual(plan.OptionLists["interface"], []string{"guest", "lan"}) {
		t.Fatalf("plan %+v, %v", plan, err)
	}
	inst.ExcludedInterfaces = []string{"br-lan"}
	if _, err := PlanDNS([]DNSInstance{inst}, "lan", "br-lan", ip4, ip6, true); err == nil {
		t.Fatal("accepted excluded LAN")
	}
	inst.ExcludedInterfaces = nil
	inst.Port = "0"
	if _, err := PlanDNS([]DNSInstance{inst}, "lan", "br-lan", ip4, ip6, false); err == nil {
		t.Fatal("enabled an unverified port")
	}
	plan, err = PlanDNS([]DNSInstance{inst}, "lan", "br-lan", ip4, ip6, true)
	if err != nil || plan.Options["port"] != "53" {
		t.Fatalf("plan %+v, %v", plan, err)
	}
	if _, err := PlanDNS([]DNSInstance{inst, inst}, "lan", "br-lan", ip4, ip6, true); err == nil {
		t.Fatal("accepted ambiguous instance")
	}
	inst.Port = "53"
	inst.ExcludedInterfaces = []string{"br-*"}
	if _, err := PlanDNS([]DNSInstance{inst}, "lan", "br-lan", ip4, ip6, true); err == nil {
		t.Fatal("accepted wildcard exclusion")
	}
}

func TestPlanDNSAddsAddressesWithoutDroppingExistingOnes(t *testing.T) {
	inst := DNSInstance{Name: "main", ListenAddresses: []string{"127.0.0.1"}}
	plan, err := PlanDNS([]DNSInstance{inst}, "lan", "br-lan", netip.MustParseAddr("192.0.2.1"), netip.MustParseAddr("fd00::1"), true)
	want := []string{"127.0.0.1", "192.0.2.1", "fd00::1"}
	if err != nil || !reflect.DeepEqual(plan.OptionLists["listen_address"], want) {
		t.Fatalf("plan %+v, %v", plan, err)
	}
}
