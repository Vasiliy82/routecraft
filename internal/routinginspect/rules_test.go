package routinginspect

import "testing"

func TestCheckDetectsTableAndMaskOverlap(t *testing.T) {
	tests := []struct {
		name, data string
		bad        bool
	}{
		{"unrelated tailscale mark", `[{"fwmark":"0x80000","fwmask":"0xff0000","table":"52"}]`, false},
		{"exact mark", `[{"fwmark":"0x81","table":"200"}]`, true},
		{"masked overlap", `[{"fwmark":"0x80","fwmask":"0xf0","table":"200"}]`, true},
		{"different mask", `[{"fwmark":"0x90","fwmask":"0xf0","table":"200"}]`, false},
		{"reserved table", `[{"table":"100"}]`, true},
		{"inverted", `[{"not":null,"fwmark":"0x90","table":"200"}]`, true},
		{"invalid", `{}`, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := Check([]byte(tc.data), 0x81, 100)
			if (err != nil) != tc.bad {
				t.Fatalf("error %v", err)
			}
		})
	}
}

func TestCheckOwnedAllowsOnlyExactScopedRule(t *testing.T) {
	owned := `{"priority":32765,"src":"all","fwmark":"0x81","iif":"br-lan","table":"100"}`
	if err := CheckOwned([]byte("["+owned+"]"), 0x81, 100, "br-lan"); err != nil {
		t.Fatal(err)
	}
	if err := CheckOwned([]byte("["+owned+","+owned+"]"), 0x81, 100, "br-lan"); err == nil {
		t.Fatal("accepted duplicate")
	}
	if err := CheckOwned([]byte("["+owned+"]"), 0x81, 100, "other"); err == nil {
		t.Fatal("accepted rule for a different LAN")
	}
	if err := CheckOwned([]byte(`[{"fwmark":"0x81","iif":"br-lan","table":"100","uid_start":1}]`), 0x81, 100, "br-lan"); err == nil {
		t.Fatal("accepted unexpected selector")
	}
}
