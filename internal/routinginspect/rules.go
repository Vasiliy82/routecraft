// Package routinginspect detects reserved policy-routing conflicts.
package routinginspect

import (
	"encoding/json"
	"fmt"
	"strconv"
)

func number(raw json.RawMessage) (uint64, error) {
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		s = string(raw)
	}
	n, err := strconv.ParseUint(s, 0, 32)
	if err != nil {
		return 0, fmt.Errorf("invalid numeric routing value")
	}
	return n, nil
}

// Check rejects rules referencing the reserved table or whose fwmark selector
// can match the reserved mark. Other selectors are ignored conservatively.
func Check(data []byte, reservedMark, reservedTable uint32) error {
	var rules []map[string]json.RawMessage
	if err := json.Unmarshal(data, &rules); err != nil || rules == nil {
		return fmt.Errorf("invalid policy-routing rules JSON")
	}
	for _, rule := range rules {
		if raw, ok := rule["table"]; ok {
			table, err := number(raw)
			if err != nil {
				return fmt.Errorf("cannot read policy rule table ID: %w", err)
			}
			if table == uint64(reservedTable) {
				return fmt.Errorf("reserved routing table is referenced")
			}
		}
		raw, marked := rule["fwmark"]
		if !marked {
			if _, ok := rule["fwmask"]; ok {
				return fmt.Errorf("routing mask without mark")
			}
			continue
		}
		mark, err := number(raw)
		if err != nil {
			return fmt.Errorf("cannot read policy rule fwmark: %w", err)
		}
		mask := uint64(0xffffffff)
		if raw, ok := rule["fwmask"]; ok {
			mask, err = number(raw)
			if err != nil {
				return fmt.Errorf("cannot read policy rule fwmask: %w", err)
			}
		}
		if _, inverted := rule["not"]; inverted {
			return fmt.Errorf("inverted marked rule requires review")
		}
		if mark&mask == uint64(reservedMark)&mask {
			return fmt.Errorf("reserved mark %#x overlaps an existing rule (fwmark %#x, fwmask %#x)", reservedMark, mark, mask)
		}
	}
	return nil
}

// CheckOwned allows at most one exact RouteCraft rule on the recorded LAN.
// All other rules are checked conservatively as foreign, even if a service
// file happens to exist. Unknown selectors on the owned rule are not accepted.
func CheckOwned(data []byte, reservedMark, reservedTable uint32, lan string) error {
	if lan == "" {
		return fmt.Errorf("recorded LAN is missing")
	}
	var rules []map[string]json.RawMessage
	if err := json.Unmarshal(data, &rules); err != nil || rules == nil {
		return fmt.Errorf("invalid policy-routing rules JSON")
	}
	allowed := map[string]bool{"priority": true, "src": true, "fwmark": true, "fwmask": true, "iif": true, "table": true}
	owned := 0
	for _, rule := range rules {
		match := true
		for name := range rule {
			if !allowed[name] {
				match = false
			}
		}
		var src, iif string
		_ = json.Unmarshal(rule["src"], &src)
		_ = json.Unmarshal(rule["iif"], &iif)
		mark, markErr := number(rule["fwmark"])
		table, tableErr := number(rule["table"])
		mask := uint64(0xffffffff)
		if raw, ok := rule["fwmask"]; ok {
			var err error
			mask, err = number(raw)
			if err != nil {
				match = false
			}
		}
		match = match && (src == "" || src == "all") && iif == lan && markErr == nil && tableErr == nil && mark == uint64(reservedMark) && table == uint64(reservedTable) && mask == 0xffffffff
		if match {
			owned++
			if owned > 1 {
				return fmt.Errorf("duplicate owned routing rules")
			}
			continue
		}
		encoded, err := json.Marshal([]map[string]json.RawMessage{rule})
		if err != nil {
			return err
		}
		if err := Check(encoded, reservedMark, reservedTable); err != nil {
			return err
		}
	}
	return nil
}
