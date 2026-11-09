// Command bench is the Go counterpart of bench/main.zig: google.golang.org/protobuf on the same
// eight messages, timed the same way, printed as the same Markdown table.
//
// Run it from bench/go with `go run . [--quick] [--write <dir>]`. Binary encoding uses
// deterministic marshaling, which writes map entries in key order, as the Zig benchmark does.
// Encoding appends to a buffer the benchmark keeps, as Zig writes into the caller's buffer.
// Decoding copies every string and bytes field and allocates every message.
package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	benchv1 "github.com/c4milo/connect-zig/bench/go/gen/bench/v1"
)

const bytesPerMegabyte = 1_000_000

var operations = []string{
	"binary encode",
	"binary decode",
	"binary decode+walk",
	"JSON encode",
	"JSON decode",
	"JSON decode+walk",
}

// A benchmark message: its input, a constructor for decoding, and its walk.
type message struct {
	name       string
	input      proto.Message
	newMessage func() proto.Message
	walk       func(proto.Message) uint64
	binary     []byte
	json       []byte
	sum        uint64
}

var deterministic = proto.MarshalOptions{Deterministic: true}

// sink keeps the compiler from dropping work whose result nothing reads.
var sink uint64

func main() {
	quickFlag := flag.Bool("quick", false, "take 3 short batches an operation: a smoke test")
	writeFlag := flag.String("write", "", "write each binary encoding and walk sum into this directory")
	flag.Parse()
	current := full
	if *quickFlag {
		current = quick
	}
	if err := run(current, *writeFlag); err != nil {
		fmt.Fprintln(os.Stderr, "bench:", err)
		os.Exit(1)
	}
}

func run(current settings, directory string) error {
	messages := []*message{
		{name: "small", input: newSmall(), newMessage: func() proto.Message { return new(benchv1.Small) },
			walk: func(m proto.Message) uint64 { return walkSmall(m.(*benchv1.Small)) }},
		{name: "medium", input: newMedium(), newMessage: func() proto.Message { return new(benchv1.Medium) },
			walk: func(m proto.Message) uint64 { return walkMedium(m.(*benchv1.Medium)) }},
		{name: "large", input: newLarge(), newMessage: func() proto.Message { return new(benchv1.Large) },
			walk: func(m proto.Message) uint64 { return walkLarge(m.(*benchv1.Large)) }},
		{name: "deep", input: newDeep(), newMessage: func() proto.Message { return new(benchv1.Deep) },
			walk: func(m proto.Message) uint64 { return walkDeep(m.(*benchv1.Deep)) }},
		{name: "varints", input: newVarints(), newMessage: func() proto.Message { return new(benchv1.Varints) },
			walk: func(m proto.Message) uint64 { return walkVarints(m.(*benchv1.Varints)) }},
		{name: "strings", input: newStrings(), newMessage: func() proto.Message { return new(benchv1.Strings) },
			walk: func(m proto.Message) uint64 { return walkStrings(m.(*benchv1.Strings)) }},
		{name: "tree", input: newTree(treeLevelsCount), newMessage: func() proto.Message { return new(benchv1.Tree) },
			walk: func(m proto.Message) uint64 { return walkTree(m.(*benchv1.Tree)) }},
		{name: "packed", input: newPacked(), newMessage: func() proto.Message { return new(benchv1.Packed) },
			walk: func(m proto.Message) uint64 { return walkPacked(m.(*benchv1.Packed)) }},
	}
	fmt.Print("| message | operation | bytes | ns/op | MB/s |\n| --- | --- | ---: | ---: | ---: |\n")
	for _, m := range messages {
		if err := m.prepare(); err != nil {
			return fmt.Errorf("%s: %w", m.name, err)
		}
		if directory != "" {
			if err := m.write(directory); err != nil {
				return err
			}
		}
		for _, operation := range operations {
			ns, err := medianNs(current, m.runner(operation))
			if err != nil {
				return fmt.Errorf("%s, %s: %w", m.name, operation, err)
			}
			size := m.bytes(operation)
			megabytesPerSecond := float64(size) / ns * 1e9 / bytesPerMegabyte
			fmt.Printf("| %s | %s | %d | %.1f | %.1f |\n", m.name, operation, size, ns, megabytesPerSecond)
		}
	}
	return nil
}

// prepare encodes the message once in each form, and checks that both decode back to it.
func (m *message) prepare() error {
	var err error
	if m.binary, err = deterministic.Marshal(m.input); err != nil {
		return err
	}
	if m.json, err = protojson.Marshal(m.input); err != nil {
		return err
	}
	m.sum = m.walk(m.input)
	decoded := m.newMessage()
	if err := proto.Unmarshal(m.binary, decoded); err != nil {
		return err
	}
	again, err := deterministic.Marshal(decoded)
	if err != nil {
		return err
	}
	if m.walk(decoded) != m.sum || !bytes.Equal(again, m.binary) {
		return errors.New("the binary encoding does not decode back to the message")
	}
	fromJSON := m.newMessage()
	if err := protojson.Unmarshal(m.json, fromJSON); err != nil {
		return err
	}
	if m.walk(fromJSON) != m.sum {
		return errors.New("the JSON encoding does not decode back to the message")
	}
	return nil
}

func (m *message) write(directory string) error {
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(directory, m.name+".bin"), m.binary, 0o644); err != nil {
		return err
	}
	sum := strconv.FormatUint(m.sum, 10) + "\n"
	return os.WriteFile(filepath.Join(directory, m.name+".sum"), []byte(sum), 0o644)
}

func (m *message) bytes(operation string) int {
	if operation[0] == 'J' {
		return len(m.json)
	}
	return len(m.binary)
}

// runner returns a function that runs the operation n times.
func (m *message) runner(operation string) func(n uint64) error {
	switch operation {
	case "binary encode":
		buffer := make([]byte, 0, len(m.binary))
		return func(n uint64) error {
			for i := uint64(0); i < n; i++ {
				out, err := deterministic.MarshalAppend(buffer[:0], m.input)
				if err != nil {
					return err
				}
				sink += uint64(len(out))
			}
			return nil
		}
	case "binary decode", "binary decode+walk":
		return m.decoder(proto.Unmarshal, m.binary, operation == "binary decode+walk")
	case "JSON encode":
		buffer := make([]byte, 0, len(m.json))
		return func(n uint64) error {
			for i := uint64(0); i < n; i++ {
				out, err := protojson.MarshalOptions{}.MarshalAppend(buffer[:0], m.input)
				if err != nil {
					return err
				}
				sink += uint64(len(out))
			}
			return nil
		}
	default:
		return m.decoder(protojson.Unmarshal, m.json, operation == "JSON decode+walk")
	}
}

func (m *message) decoder(unmarshal func([]byte, proto.Message) error, input []byte, walk bool) func(n uint64) error {
	return func(n uint64) error {
		for i := uint64(0); i < n; i++ {
			decoded := m.newMessage()
			if err := unmarshal(input, decoded); err != nil {
				return err
			}
			if walk {
				sink += m.walk(decoded)
			}
		}
		return nil
	}
}
