// Package netdevices discovers selectable Linux network devices without changing them.
package netdevices

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

var safeName = regexp.MustCompile(`^[a-zA-Z0-9_.-]+$`)

// List returns physical interfaces and bridges, excluding ports enslaved to a
// master. root is the sysfs network class directory (normally /sys/class/net).
// Call ListWithVLAN on Linux to include explicitly identified VLAN devices.
func List(root string) ([]string, error) {
	return list(root, nil)
}

// ListWithVLAN also accepts interfaces listed in /proc/net/vlan. The directory
// may be absent when no VLAN module is loaded; other read errors are returned.
func ListWithVLAN(root, vlanRoot string) ([]string, error) {
	entries, err := os.ReadDir(vlanRoot)
	if err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("read VLAN devices: %w", err)
	}
	vlans := make(map[string]bool)
	for _, entry := range entries {
		if entry.Name() != "config" && !entry.IsDir() {
			vlans[entry.Name()] = true
		}
	}
	return list(root, vlans)
}

func list(root string, vlans map[string]bool) ([]string, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, fmt.Errorf("read network devices: %w", err)
	}
	var devices []string
	for _, entry := range entries {
		name := entry.Name()
		if name == "lo" || !safeName.MatchString(name) {
			continue
		}
		path := filepath.Join(root, name)
		if _, err := os.Lstat(filepath.Join(path, "master")); err == nil {
			continue
		} else if !os.IsNotExist(err) {
			return nil, fmt.Errorf("inspect %s master: %w", name, err)
		}
		bridge, err := exists(filepath.Join(path, "bridge"))
		if err != nil {
			return nil, fmt.Errorf("inspect %s bridge: %w", name, err)
		}
		physical, err := exists(filepath.Join(path, "device"))
		if err != nil {
			return nil, fmt.Errorf("inspect %s device: %w", name, err)
		}
		if bridge || physical || vlans[name] {
			devices = append(devices, name)
		}
	}
	sort.Strings(devices)
	return devices, nil
}

func exists(path string) (bool, error) {
	_, err := os.Stat(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	return err == nil, err
}
