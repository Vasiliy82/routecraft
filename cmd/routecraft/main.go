package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/vasiliy82/routecraft/internal/compiler"
	"github.com/vasiliy82/routecraft/internal/explain"
	"github.com/vasiliy82/routecraft/internal/geodata"
	"github.com/vasiliy82/routecraft/internal/policy"
)

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "routecraft:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) > 0 && args[0] == "db" {
		return runDB(args[1:], stdout, stderr)
	}
	if len(args) == 0 || (args[0] != "validate" && args[0] != "compile" && args[0] != "explain") {
		return fmt.Errorf("usage: routecraft validate|compile|explain|db [options]")
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
	singBox := flags.String("sing-box", "sing-box", "sing-box binary for category matching")
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
		matcher := func(kind, name, target string) (bool, error) {
			path := c.Categories[kind+":"+name]
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, *singBox, "rule-set", "match", "--format", "binary", path, target)
			output, err := cmd.CombinedOutput()
			if err != nil {
				return false, fmt.Errorf("sing-box match failed: %w: %s", err, strings.TrimSpace(string(output)))
			}
			lines := strings.TrimSpace(string(output))
			if lines == "" {
				return false, nil
			}
			for _, line := range strings.Split(lines, "\n") {
				if !strings.HasPrefix(line, "match rules.") {
					return false, fmt.Errorf("unexpected sing-box match output")
				}
			}
			return true, nil
		}
		result, err := explain.EvaluateWithMatcher(p, explain.Target{Domain: *domain, IP: *ip, Port: *port, Network: *network}, matcher)
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

func runDB(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 || (args[0] != "discover" && args[0] != "list" && args[0] != "fetch") {
		return fmt.Errorf("usage: routecraft db discover|list|fetch [options]")
	}
	flags := flag.NewFlagSet("db "+args[0], flag.ContinueOnError)
	flags.SetOutput(stderr)
	output := flags.String("output", "", "catalog output file")
	index := flags.String("index", "", "catalog input file")
	kind := flags.String("type", "", "filter by category type")
	search := flags.String("search", "", "filter by name")
	name := flags.String("name", "", "category name for fetch")
	singBox := flags.String("sing-box", "sing-box", "sing-box binary for SRS validation")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %v", flags.Args())
	}
	if args[0] == "discover" {
		if *output == "" || *index != "" || *kind != "" || *search != "" || *name != "" {
			return fmt.Errorf("db discover requires only --output FILE")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		catalog, err := geodata.Discover(ctx, &http.Client{Timeout: 20 * time.Second}, geodata.DefaultTreesURL)
		if err != nil {
			return err
		}
		data, err := json.MarshalIndent(catalog, "", "  ")
		if err != nil {
			return err
		}
		if err = writeAtomic(*output, append(data, '\n')); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "Indexed %d categories at revision %s; rule-set files were not downloaded.\n", len(catalog.Categories), catalog.Revision)
		return nil
	}
	if *kind != "" && *kind != "geoip" && *kind != "geosite" {
		return fmt.Errorf("invalid category type %q", *kind)
	}
	if *index == "" {
		return fmt.Errorf("--index FILE is required")
	}
	data, err := os.ReadFile(*index)
	if err != nil {
		return fmt.Errorf("read catalog: %w", err)
	}
	var catalog geodata.Catalog
	if err = json.Unmarshal(data, &catalog); err != nil {
		return fmt.Errorf("parse catalog: %w", err)
	}
	if catalog.Version != 1 || catalog.Source == "" || catalog.Revision == "" {
		return fmt.Errorf("invalid catalog metadata")
	}
	if args[0] == "fetch" {
		if *output == "" || *kind == "" || *name == "" || *search != "" {
			return fmt.Errorf("db fetch requires --index FILE --type geoip|geosite --name NAME --output FILE")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		download, err := geodata.Fetch(ctx, &http.Client{Timeout: 30 * time.Second}, catalog, *kind, *name)
		if err != nil {
			return err
		}
		if err = writeValidatedSRS(ctx, *singBox, *output, download.Data); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "Fetched %s:%s revision %s SHA256 %s; validated by sing-box.\n", *kind, *name, catalog.Revision, download.SHA256)
		return nil
	}
	if *output != "" || *name != "" {
		return fmt.Errorf("db list does not accept --output or --name")
	}
	for _, category := range catalog.Categories {
		if (*kind == "" || category.Kind == *kind) && strings.Contains(category.Name, *search) {
			fmt.Fprintf(stdout, "%s:%s\n", category.Kind, category.Name)
		}
	}
	return nil
}

func writeValidatedSRS(ctx context.Context, singBox, path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create rule-set directory: %w", err)
	}
	f, err := os.CreateTemp(dir, ".routecraft-srs-*")
	if err != nil {
		return fmt.Errorf("create temporary rule-set: %w", err)
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return fmt.Errorf("write rule-set: %w", err)
	}
	cmd := exec.CommandContext(ctx, singBox, "rule-set", "decompile", tmp, "--output", os.DevNull)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("sing-box rejected rule-set: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if err = os.Rename(tmp, path); err != nil {
		return fmt.Errorf("publish rule-set: %w", err)
	}
	return nil
}

// writeAtomic keeps the previous index intact if writing or validation fails.
func writeAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create catalog directory: %w", err)
	}
	f, err := os.CreateTemp(dir, ".routecraft-index-*")
	if err != nil {
		return fmt.Errorf("create temporary catalog: %w", err)
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return fmt.Errorf("write catalog: %w", err)
	}
	if err = os.Rename(name, path); err != nil {
		return fmt.Errorf("publish catalog: %w", err)
	}
	return nil
}
