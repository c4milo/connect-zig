// The validation benchmark's Go program (tools/validate_compare_check.sh): protovalidate-go over
// the schema of bench/validate/proto, with the code protoc-gen-go writes.
//
//	validate-go [--quick] <directory>
//
// It reads each case's encoded message from the directory, as bench/validate_main.zig does, and
// times two things, the median nanoseconds of one call of each: Validate of the message
// unmarshaled once, and Unmarshal of its octets with Validate of what it gives. It prints a row
// for each case with its verdict: "valid", or "invalid:" and the rule ids of the violations in
// order.
package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"buf.build/go/protovalidate"
	"google.golang.org/protobuf/proto"

	validatev1 "github.com/c4milo/connect-zig/bench/validate/go/gen/bench/validate/v1"
)

// One case: its name, the file of its message, and a new message of its type.
type benchCase struct {
	name, file string
	empty      func() proto.Message
}

var cases = []benchCase{
	{"small valid", "small_valid.binpb", func() proto.Message { return &validatev1.Small{} }},
	{"small invalid", "small_invalid.binpb", func() proto.Message { return &validatev1.Small{} }},
	{"medium valid", "medium_valid.binpb", func() proto.Message { return &validatev1.Medium{} }},
	{"medium invalid", "medium_invalid.binpb", func() proto.Message { return &validatev1.Medium{} }},
	{"rules valid", "rules_valid.binpb", func() proto.Message { return &validatev1.Rules{} }},
	{"rules invalid", "rules_invalid.binpb", func() proto.Message { return &validatev1.Rules{} }},
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	current, directory := full, ""
	for _, arg := range args {
		if arg == "--quick" {
			current = quick
		} else {
			directory = arg
		}
	}
	if directory == "" {
		return errors.New("usage: validate-go [--quick] <directory>")
	}
	// One validator for every call, as a server keeps one: it compiles each type's rules once.
	validator, err := protovalidate.New()
	if err != nil {
		return err
	}
	fmt.Println("| case | verdict | validate ns/op | decode and validate ns/op |")
	fmt.Println("| --- | --- | ---: | ---: |")
	for _, c := range cases {
		bytes, err := os.ReadFile(filepath.Join(directory, c.file))
		if err != nil {
			return err
		}
		message := c.empty()
		if err := proto.Unmarshal(bytes, message); err != nil {
			return err
		}
		verdict, err := verdictOf(validator, message)
		if err != nil {
			return err
		}
		ns, err := medianNs(current, func(n uint64) error {
			for i := uint64(0); i < n; i++ {
				_ = validator.Validate(message)
			}
			return nil
		})
		if err != nil {
			return err
		}
		bothNs, err := medianNs(current, func(n uint64) error {
			for i := uint64(0); i < n; i++ {
				fresh := c.empty()
				if err := proto.Unmarshal(bytes, fresh); err != nil {
					return err
				}
				_ = validator.Validate(fresh)
			}
			return nil
		})
		if err != nil {
			return err
		}
		fmt.Printf("| %s | %s | %.1f | %.1f |\n", c.name, verdict, ns, bothNs)
	}
	return nil
}

// verdictOf is "valid", or "invalid:" and the rule id of each violation, in order.
func verdictOf(validator protovalidate.Validator, message proto.Message) (string, error) {
	err := validator.Validate(message)
	if err == nil {
		return "valid", nil
	}
	var invalid *protovalidate.ValidationError
	if !errors.As(err, &invalid) {
		return "", err
	}
	ids := make([]string, 0, len(invalid.Violations))
	for _, violation := range invalid.Violations {
		ids = append(ids, violation.Proto.GetRuleId())
	}
	sort.Strings(ids)
	return "invalid:" + strings.Join(ids, ","), nil
}
