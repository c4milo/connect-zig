// The reference of the CEL differential check: protovalidate-go, which runs cel-go.
//
// Usage: reference <descriptor set> <messages.txt>
//
// It validates each message of messages.txt as each type M0, M1 and so on of diff.v1, and
// prints one line for each pair: the type's number, the message's number, and the verdict.
package main

import (
	"bufio"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"

	"buf.build/go/protovalidate"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

// verdict is what the check compares: "valid", "invalid:" and the violation's message,
// "fails" for an expression that fails as it runs, and "refused" for one that does not compile.
func verdict(validator protovalidate.Validator, message proto.Message) string {
	err := validator.Validate(message)
	if err == nil {
		return "valid"
	}
	var invalid *protovalidate.ValidationError
	if errors.As(err, &invalid) {
		return "invalid:" + invalid.Violations[0].Proto.GetMessage()
	}
	var compilation *protovalidate.CompilationError
	if errors.As(err, &compilation) {
		return "refused"
	}
	return "fails"
}

func main() {
	if len(os.Args) != 3 {
		fail(errors.New("usage: reference <descriptor set> <messages.txt>"))
	}
	files := readFiles(os.Args[1])
	payloads := readPayloads(os.Args[2])
	validator, err := protovalidate.New()
	if err != nil {
		fail(err)
	}
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	for index := 0; ; index++ {
		descriptor, err := files.FindDescriptorByName(protoreflect.FullName(fmt.Sprintf("diff.v1.M%d", index)))
		if err != nil {
			return
		}
		for number, payload := range payloads {
			message := dynamicpb.NewMessage(descriptor.(protoreflect.MessageDescriptor))
			if err := proto.Unmarshal(payload, message); err != nil {
				fail(err)
			}
			fmt.Fprintf(out, "%d %d %s\n", index, number, verdict(validator, message))
		}
	}
}

// readFiles reads the descriptor set at path into the registry of its files.
func readFiles(path string) *protoregistry.Files {
	encoded, err := os.ReadFile(path)
	if err != nil {
		fail(err)
	}
	set := &descriptorpb.FileDescriptorSet{}
	if err := proto.Unmarshal(encoded, set); err != nil {
		fail(err)
	}
	files, err := protodesc.NewFiles(set)
	if err != nil {
		fail(err)
	}
	return files
}

// readPayloads reads the messages file at path: one encoded message a line, in hexadecimal.
func readPayloads(path string) [][]byte {
	text, err := os.ReadFile(path)
	if err != nil {
		fail(err)
	}
	var payloads [][]byte
	for _, line := range strings.Fields(string(text)) {
		payload, err := hex.DecodeString(line)
		if err != nil {
			fail(err)
		}
		payloads = append(payloads, payload)
	}
	return payloads
}
