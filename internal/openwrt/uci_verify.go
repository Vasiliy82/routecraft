package openwrt

import (
	"encoding/json"
	"fmt"
	"reflect"
)

// VerifyDHCPRestored compares only options touched by the plan, including
// missing options and ordered lists, against a saved UCI section snapshot.
func VerifyDHCPRestored(plan DHCPPlan, before, current []byte) error {
	read := func(data []byte) (map[string]any, error) {
		var value struct {
			Values map[string]any `json:"values"`
		}
		if err := json.Unmarshal(data, &value); err != nil || value.Values == nil {
			return nil, fmt.Errorf("invalid UCI section snapshot")
		}
		return value.Values, nil
	}
	original, err := read(before)
	if err != nil {
		return err
	}
	now, err := read(current)
	if err != nil {
		return err
	}
	names := make(map[string]bool)
	for name := range plan.Options {
		names[name] = true
	}
	for name := range plan.OptionLists {
		names[name] = true
	}
	if plan.ReplaceDHCPOptions {
		names["dhcp_option"] = true
	}
	if len(names) == 0 {
		return fmt.Errorf("empty DHCP plan")
	}
	for name := range names {
		a, aok := original[name]
		b, bok := now[name]
		if aok != bok || !reflect.DeepEqual(a, b) {
			return fmt.Errorf("DHCP option %q was not restored", name)
		}
	}
	return nil
}
