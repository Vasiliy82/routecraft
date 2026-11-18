package openwrt

import "testing"

func TestVerifyDHCPRestoredChecksOnlyTouchedOptions(t *testing.T) {
	plan := DHCPPlan{Options: map[string]string{"ignore": "1"}, OptionLists: map[string][]string{"dns": {"fd00::1"}}, ReplaceDHCPOptions: true}
	before := []byte(`{"values":{"ignore":"0","dns":["fd00::2"],"dhcp_option":["3,192.0.2.1"],"other":"old"}}`)
	same := []byte(`{"values":{"other":"new","ignore":"0","dns":["fd00::2"],"dhcp_option":["3,192.0.2.1"]}}`)
	if err := VerifyDHCPRestored(plan, before, same); err != nil {
		t.Fatal(err)
	}
	missing := []byte(`{"values":{"dns":["fd00::2"],"dhcp_option":["3,192.0.2.1"]}}`)
	if err := VerifyDHCPRestored(plan, before, missing); err == nil {
		t.Fatal("accepted missing option")
	}
	changed := []byte(`{"values":{"ignore":"0","dns":["fd00::3"],"dhcp_option":["3,192.0.2.1"]}}`)
	if err := VerifyDHCPRestored(plan, before, changed); err == nil {
		t.Fatal("accepted changed DNS")
	}
}
