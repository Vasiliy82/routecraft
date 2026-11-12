package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateCompileAndExplain(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	p := write("policy.yaml", "version: 1\nrules:\n  - name: block\n    filter: [domain:bad.example, port:443]\n    outbound: reject\n  - name: default\n    outbound: direct\n")
	o := write("outbounds.yaml", "version: 1\noutbounds:\n  direct: {type: direct}\n  reject: {type: reject}\n")
	c := write("categories.yaml", "version: 1\ncategories: {}\n")
	flags := []string{"--policy", p, "--outbounds", o, "--categories", c}
	var stdout, stderr bytes.Buffer
	if err := run(append([]string{"validate"}, flags...), &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stdout.String(), "runtime readiness was not checked") {
		t.Fatal(stdout.String())
	}
	stdout.Reset()
	output := filepath.Join(dir, "out")
	if err := run(append(append([]string{"compile"}, flags...), "--output", output), &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(output, "sing-box.fragment.json"))
	if err != nil || !bytes.Contains(data, []byte(`"mode": "or"`)) {
		t.Fatalf("fragment %s: %v", data, err)
	}
	stdout.Reset()
	if err := run(append(append([]string{"explain"}, flags...), "--domain", "good.example", "--port", "443"), &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stdout.String(), `"rule": "block"`) || !strings.Contains(stdout.String(), `"filter": "port:443"`) {
		t.Fatal(stdout.String())
	}
}

func TestCompileDoesNotWriteOnInvalidPolicy(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	p := write("policy.yaml", "version: 1\nrules:\n  - name: default\n    outbound: missing\n")
	o := write("outbounds.yaml", "version: 1\noutbounds:\n  direct: {type: direct}\n")
	c := write("categories.yaml", "version: 1\ncategories: {}\n")
	output := filepath.Join(dir, "out")
	var stdout, stderr bytes.Buffer
	err := run([]string{"compile", "--policy", p, "--outbounds", o, "--categories", c, "--output", output}, &stdout, &stderr)
	if err == nil {
		t.Fatal("invalid policy unexpectedly compiled")
	}
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		t.Fatalf("output created: %v", err)
	}
}
