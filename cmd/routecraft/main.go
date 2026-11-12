package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/vasiliy82/routecraft/internal/compiler"
	"github.com/vasiliy82/routecraft/internal/explain"
	"github.com/vasiliy82/routecraft/internal/policy"
)

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "routecraft:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 || (args[0] != "validate" && args[0] != "compile" && args[0] != "explain") {
		return fmt.Errorf("usage: routecraft validate|compile|explain [options]")
	}
	command := args[0]
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(stderr)
	policyPath := flags.String("policy", "configs/policy.example.yaml", "policy YAML")
	outboundPath := flags.String("outbounds", "configs/outbounds.example.yaml", "outbounds YAML")
	categoryPath := flags.String("categories", "configs/categories.example.yaml", "local category index YAML")
	output := flags.String("output", "", "output directory for the sing-box fragment")
	domain := flags.String("domain", "", "target domain for explain")
	ip := flags.String("ip", "", "target IP for explain")
	port := flags.Int("port", 0, "target port for explain")
	network := flags.String("network", "", "target network for explain (tcp or udp)")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %v", flags.Args())
	}
	if command != "compile" && *output != "" {
		return fmt.Errorf("--output is only valid for compile")
	}
	if command != "explain" && (*domain != "" || *ip != "" || *port != 0 || *network != "") {
		return fmt.Errorf("target flags are only valid for explain")
	}
	if command == "compile" && *output == "" {
		return fmt.Errorf("compile requires --output DIR")
	}
	pBytes, err := os.ReadFile(*policyPath)
	if err != nil {
		return fmt.Errorf("read policy: %w", err)
	}
	p, err := policy.Parse(pBytes)
	if err != nil {
		return fmt.Errorf("policy: %w", err)
	}
	oBytes, err := os.ReadFile(*outboundPath)
	if err != nil {
		return fmt.Errorf("read outbounds: %w", err)
	}
	o, err := policy.ParseOutbounds(oBytes)
	if err != nil {
		return fmt.Errorf("outbounds: %w", err)
	}
	cBytes, err := os.ReadFile(*categoryPath)
	if err != nil {
		return fmt.Errorf("read categories: %w", err)
	}
	c, err := policy.ParseCategories(cBytes)
	if err != nil {
		return fmt.Errorf("categories: %w", err)
	}
	if err = policy.Validate(p, o, c); err != nil {
		return err
	}
	if command == "validate" {
		fmt.Fprintln(stdout, "Policy syntax and references are valid; runtime readiness was not checked.")
		return nil
	}
	if command == "explain" {
		result, err := explain.Evaluate(p, explain.Target{Domain: *domain, IP: *ip, Port: *port, Network: *network})
		if err != nil {
			return err
		}
		encoder := json.NewEncoder(stdout)
		encoder.SetIndent("", "  ")
		return encoder.Encode(result)
	}
	artifact, err := compiler.Compile(compiler.Input{Policy: p, Outbounds: o, Categories: c})
	if err != nil {
		return err
	}
	data, err := compiler.Marshal(artifact)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(*output, 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}
	path := filepath.Join(*output, "sing-box.fragment.json")
	if err = os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("write fragment: %w", err)
	}
	fmt.Fprintf(stdout, "Wrote %s (fragment only; not applied).\n", path)
	return nil
}
