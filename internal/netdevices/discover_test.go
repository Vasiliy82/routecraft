package netdevices

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestListExcludesBridgePortsAndUnknownVirtualDevices(t *testing.T) {
	root := t.TempDir()
	for _, path := range []string{"lo", "eth0/device", "eth1/device", "eth1/master", "eth2/device", "eth2/master", "br-lan/bridge", "tun0", "unsafe@name/device"} {
		if err := os.MkdirAll(filepath.Join(root, path), 0755); err != nil {
			t.Fatal(err)
		}
	}
	got, err := List(root)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"br-lan", "eth0"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestListReportsUnavailableDirectory(t *testing.T) {
	if _, err := List(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("expected error")
	}
}

func TestListWithVLANIncludesVLANButNotEnslavedPort(t *testing.T) {
	root := t.TempDir()
	vlanRoot := t.TempDir()
	for _, path := range []string{"br-lan/bridge", "br-lan.10", "eth0/device", "eth0/master", "eth0.20/master", "unknown"} {
		if err := os.MkdirAll(filepath.Join(root, path), 0755); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"config", "br-lan.10", "eth0.20"} {
		if err := os.WriteFile(filepath.Join(vlanRoot, name), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	got, err := ListWithVLAN(root, vlanRoot)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"br-lan", "br-lan.10"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestListRefreshReflectsRemovedDevice(t *testing.T) {
	root := t.TempDir()
	device := filepath.Join(root, "eth0")
	if err := os.MkdirAll(filepath.Join(device, "device"), 0755); err != nil {
		t.Fatal(err)
	}
	before, err := ListWithVLAN(root, filepath.Join(root, "no-vlan"))
	if err != nil || len(before) != 1 {
		t.Fatalf("before removal: %v, %v", before, err)
	}
	if err := os.RemoveAll(device); err != nil {
		t.Fatal(err)
	}
	after, err := ListWithVLAN(root, filepath.Join(root, "no-vlan"))
	if err != nil || len(after) != 0 {
		t.Fatalf("after removal: %v, %v", after, err)
	}
}
