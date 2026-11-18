package openwrt

import "testing"

func TestDNSUCIRequestAndRestore(t *testing.T) {
	plan := DNSPlan{Section: "main", Options: map[string]string{"port": "53"}, OptionLists: map[string][]string{"interface": {"guest", "lan"}}}
	if _, err := DNSUCIRequest(plan, "0123456789abcdef0123456789abcdef"); err != nil {
		t.Fatal(err)
	}
	before := []byte(`{"values":{"port":"0","interface":["guest"]}}`)
	changed := []byte(`{"values":{"port":"53","interface":["guest","lan"]}}`)
	if err := VerifyDNSRestored(plan, before, changed); err == nil {
		t.Fatal("accepted changed DNS state")
	}
	if err := VerifyDNSRestored(plan, before, before); err != nil {
		t.Fatal(err)
	}
	plan.OptionLists["interface"] = []string{"bad name"}
	if _, err := DNSUCIRequest(plan, "0123456789abcdef0123456789abcdef"); err == nil {
		t.Fatal("accepted invalid interface")
	}
}
