package openwrt

import "testing"

func TestDHCPSectionsDoesNotAssumeSectionNameMatchesInterface(t *testing.T) {
	data := []byte(`{"values":{"a":{".type":"dhcp",".name":"a","interface":"lan"},"lan":{".type":"dhcp",".name":"lan"},"dns":{".type":"dnsmasq",".name":"dns","interface":"lan"},"b":{".type":"dhcp",".name":"b","interface":"guest"}}}`)
	got, err := DHCPSections(data, "lan")
	if err != nil || len(got) != 2 || got[0].Name != "a" || got[1].Name != "lan" {
		t.Fatalf("got %+v, %v", got, err)
	}
}

func TestDHCPSectionsRejectsMissingOrInvalidData(t *testing.T) {
	for _, data := range []string{`{}`, `{bad`, `{"values":{"bad name":{".type":"dhcp","interface":"lan"}}}`} {
		if _, err := DHCPSections([]byte(data), "lan"); err == nil {
			t.Fatalf("accepted %s", data)
		}
	}
}
