package routinginspect

import "testing"

func TestCheckRoutesAcceptsOnlyOwnedLocalDefault(t *testing.T) {
	owned := `{"type":"2","dst":"default","dev":"lo","table":"100","scope":"254","flags":[]}`
	if err := CheckRoutes([]byte("["+owned+"]"), 100, true); err != nil {
		t.Fatal(err)
	}
	if err := CheckRoutes([]byte("["+owned+"]"), 100, false); err == nil {
		t.Fatal("accepted foreign table")
	}
	if err := CheckRoutes([]byte("["+owned+","+owned+"]"), 100, true); err == nil {
		t.Fatal("accepted duplicate")
	}
	if err := CheckRoutes([]byte(`[{"type":"1","dst":"default","dev":"eth0","table":"100"}]`), 100, true); err == nil {
		t.Fatal("accepted foreign route")
	}
	if err := CheckRoutes([]byte(`[{"dst":"default","dev":"eth0","table":"254"}]`), 100, false); err != nil {
		t.Fatal(err)
	}
}
