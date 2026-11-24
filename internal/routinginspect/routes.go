package routinginspect

import (
	"encoding/json"
	"fmt"
)

// CheckRoutes examines a numeric `ip -j -N -4 route show table all` dump.
// The only owned route allowed in the reserved table is one local default via
// loopback; unknown attributes, duplicates, or any foreign entry are refused.
func CheckRoutes(data []byte, reservedTable uint32, owned bool) error {
	var routes []map[string]json.RawMessage
	if err := json.Unmarshal(data, &routes); err != nil || routes == nil {
		return fmt.Errorf("invalid routing table JSON")
	}
	count := 0
	allowed := map[string]bool{"type": true, "dst": true, "dev": true, "table": true, "scope": true, "flags": true}
	for _, route := range routes {
		raw, ok := route["table"]
		if !ok {
			continue
		}
		table, err := number(raw)
		if err != nil {
			return fmt.Errorf("cannot read route table ID: %w", err)
		}
		if table != uint64(reservedTable) {
			continue
		}
		if !owned {
			return fmt.Errorf("reserved routing table contains foreign routes")
		}
		count++
		if count > 1 {
			return fmt.Errorf("reserved table has multiple routes")
		}
		for key := range route {
			if !allowed[key] {
				return fmt.Errorf("reserved route has unexpected attributes")
			}
		}
		var kind, dst, dev, scope string
		_ = json.Unmarshal(route["type"], &kind)
		_ = json.Unmarshal(route["dst"], &dst)
		_ = json.Unmarshal(route["dev"], &dev)
		_ = json.Unmarshal(route["scope"], &scope)
		var flags []string
		if raw, ok := route["flags"]; ok {
			if err := json.Unmarshal(raw, &flags); err != nil || len(flags) > 0 {
				return fmt.Errorf("reserved route has unexpected flags")
			}
		}
		if (kind != "2" && kind != "local") || (dst != "default" && dst != "0.0.0.0/0") || dev != "lo" || (scope != "254" && scope != "host") {
			return fmt.Errorf("reserved route does not match RouteCraft")
		}
	}
	return nil
}
