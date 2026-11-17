package explain

import (
	"errors"
	"testing"

	"github.com/vasiliy82/routecraft/internal/policy"
)

func TestEvaluatePriorityAndUncertainty(t *testing.T) {
	p := policy.Policy{Version: 1, Rules: []policy.Rule{
		{Name: "first", Filter: []string{"domainsuffix:example.com", "port:443"}, Outbound: "first-out"},
		{Name: "second", Filter: []string{"domain:notexample.com"}, Outbound: "second-out"},
		{Name: "default", Outbound: "direct"},
	}}
	for _, tc := range []struct {
		target       Target
		status, rule string
	}{
		{Target{Domain: "api.example.com", Port: 80}, "matched", "first"},
		{Target{Domain: "notexample.com", Port: 80}, "matched", "second"},
		{Target{Domain: "other.test", Port: 443}, "matched", "first"},
		{Target{Domain: "other.test", Port: 80}, "matched", "default"},
		{Target{Domain: "notexample.com"}, "indeterminate", "first"},
	} {
		result, err := Evaluate(p, tc.target)
		if err != nil || result.Status != tc.status || result.Rule != tc.rule {
			t.Errorf("target %+v: got %+v, %v; want %s %s", tc.target, result, err, tc.status, tc.rule)
		}
	}
}

func TestCategoryMatcherControlsPriority(t *testing.T) {
	p := policy.Policy{Rules: []policy.Rule{
		{Name: "category", Filter: []string{"geosite:openai"}, Outbound: "vpn"},
		{Name: "default", Outbound: "direct"},
	}}
	matcher := func(kind, name, target string) (bool, error) {
		if kind != "geosite" || name != "openai" {
			t.Fatalf("wrong category %s:%s", kind, name)
		}
		return target == "chatgpt.com", nil
	}
	for _, tc := range []struct{ domain, rule string }{{"chatgpt.com", "category"}, {"example.org", "default"}} {
		result, err := EvaluateWithMatcher(p, Target{Domain: tc.domain}, matcher)
		if err != nil || result.Rule != tc.rule {
			t.Fatalf("%s: %+v, %v", tc.domain, result, err)
		}
	}
	_, err := EvaluateWithMatcher(p, Target{Domain: "chatgpt.com"}, func(_, _, _ string) (bool, error) { return false, errors.New("unreadable SRS") })
	if err == nil {
		t.Fatal("matcher failure silently fell through")
	}
}

func TestCategoryUnknownDoesNotFallThrough(t *testing.T) {
	p := policy.Policy{Version: 1, Rules: []policy.Rule{
		{Name: "category", Filter: []string{"geosite:unknown"}, Outbound: "vpn"},
		{Name: "default", Outbound: "direct"},
	}}
	result, err := Evaluate(p, Target{Domain: "example.com"})
	if err != nil || result.Status != "indeterminate" || result.Outbound != "" {
		t.Fatalf("unexpected result %+v, %v", result, err)
	}
}
