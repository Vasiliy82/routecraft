package openwrt

import "testing"

func TestInterfacesForDeviceKeepsAmbiguousMappings(t *testing.T) {
	data := []byte(`{"interface":[{"interface":"lan","up":true,"device":"br-lan","l3_device":"br-lan"},{"interface":"lan6","up":true,"device":"br-lan","l3_device":"br-lan"},{"interface":"wan","device":"eth0","l3_device":"pppoe-wan"}]}`)
	got, err := InterfacesForDevice(data, "br-lan")
	if err != nil || len(got) != 2 || got[0].Name != "lan" || got[1].Name != "lan6" {
		t.Fatalf("got %+v, %v", got, err)
	}
	got, err = InterfacesForDevice(data, "pppoe-wan")
	if err != nil || len(got) != 1 || got[0].Name != "wan" || got[0].Device != "eth0" {
		t.Fatalf("got %+v, %v", got, err)
	}
}

func TestInterfacesForDeviceRejectsInvalidInput(t *testing.T) {
	for _, data := range []string{`{bad`, `{"interface":[{"interface":"bad name","device":"br-lan"}]}`} {
		if _, err := InterfacesForDevice([]byte(data), "br-lan"); err == nil {
			t.Fatalf("accepted %s", data)
		}
	}
}
