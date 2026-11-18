package openwrt

import (
	"reflect"
	"testing"
)

func TestDNSInstancesPreservesMultipleBindings(t *testing.T) {
	input := []byte(`{"values":{"first":{".type":"dnsmasq",".name":"first","interface":["lan","guest"],"notinterface":"wan","port":"53"},"second":{".type":"dnsmasq",".name":"second","listen_address":["192.0.2.1"],"port":"0"},"lan":{".type":"dhcp"}}}`)
	got, err := DNSInstances(input)
	if err != nil || len(got) != 2 || !reflect.DeepEqual(got[0].Interfaces, []string{"lan", "guest"}) || !reflect.DeepEqual(got[0].ExcludedInterfaces, []string{"wan"}) || got[1].Port != "0" {
		t.Fatalf("got %+v, %v", got, err)
	}
}

func TestDNSInstancesRejectsMalformedStatus(t *testing.T) {
	for _, data := range []string{`{}`, `{"values":{"d":{".type":"dnsmasq","interface":42}}}`} {
		if _, err := DNSInstances([]byte(data)); err == nil {
			t.Fatalf("accepted %s", data)
		}
	}
}
