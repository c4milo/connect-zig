package main

// The fixed messages of bench/inputs.zig, built the same way: every value follows from its
// index, so Zig and Go encode the same message.

import (
	"fmt"
	"math"
	"strings"

	benchv1 "github.com/c4milo/connect-zig/bench/go/gen/bench/v1"
)

const (
	mediumSamplesCount      = 64
	mediumTagsCount         = 16
	mediumCountersCount     = 16
	mediumPreviousCount     = 4
	sampleScale             = 1009
	sampleOffset            = 50_000
	counterScale            = 1_000_003
	previousPostalCodeFirst = 10_000
	largeRecordsCount       = 1000
	recordPayloadLen        = 128
	recordValuesCount       = 8
	recordIDFirst           = 1_000_000
	payloadRecordStep       = 31
	payloadByteStep         = 7
	valueRecordStep         = 13
	valueIndexStep          = 17
	valueModulus            = 2001
	valueOffset             = 1000
	weightStep              = 0.5
	statusCount             = 4
	deepLevelsCount         = 50
	treeFanout              = 4
	treeLevelsCount         = 4
	packedCount             = 64
	realStep                = 0.25
	// The text every ASCII string of newStrings is a prefix of, as in bench/inputs.zig.
	asciiText = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-_"
	// The phrase the large message's description repeats, as bench/inputs.zig repeats it.
	descriptionPhrase  = "A batch of records: données, 日本語のテキスト, ünïcode — end. "
	descriptionRepeats = 100
)

func newSmall() *benchv1.Small {
	return &benchv1.Small{
		Id:      12_345,
		Created: 1_700_000_000_123,
		Active:  true,
		Name:    "alice@example.com",
		Score:   98.625,
	}
}

func newMedium() *benchv1.Medium {
	samples := make([]int64, mediumSamplesCount)
	for i := range samples {
		index := int64(i)
		samples[i] = index*index*sampleScale - sampleOffset
	}
	tags := make([]string, mediumTagsCount)
	for i := range tags {
		tags[i] = fmt.Sprintf("tag-%02d", i)
	}
	counters := make(map[string]int64, mediumCountersCount)
	for i := 0; i < mediumCountersCount; i++ {
		counters[fmt.Sprintf("counter-%02d", i)] = int64(i+1) * counterScale
	}
	previous := make([]*benchv1.Address, mediumPreviousCount)
	for i := range previous {
		previous[i] = &benchv1.Address{
			Street:     fmt.Sprintf("%02d Main Street", i),
			City:       "Springfield",
			Country:    "US",
			PostalCode: uint32(previousPostalCodeFirst + i),
		}
	}
	return &benchv1.Medium{
		Id:       9_876_543_210,
		Name:     "Medium benchmark record",
		Status:   benchv1.Status_STATUS_ACTIVE,
		Home:     &benchv1.Address{Street: "1600 Amphitheatre Parkway", City: "Mountain View", Country: "US", PostalCode: 94_043},
		Samples:  samples,
		Tags:     tags,
		Counters: counters,
		Contact: &benchv1.Medium_Office{Office: &benchv1.Address{
			Street: "500 Terry Francine Street", City: "San Francisco", Country: "US", PostalCode: 94_158,
		}},
		Previous: previous,
		Checksum: 0xdead_beef_cafe_f00d,
		Ratio:    0.75,
		Delta:    -12_345,
	}
}

func newLarge() *benchv1.Large {
	records := make([]*benchv1.Record, largeRecordsCount)
	for i := range records {
		payload := make([]byte, recordPayloadLen)
		for j := range payload {
			payload[j] = byte(i*payloadRecordStep + j*payloadByteStep)
		}
		values := make([]int32, recordValuesCount)
		for j := range values {
			values[j] = int32((i*valueRecordStep+j*valueIndexStep)%valueModulus) - valueOffset
		}
		records[i] = &benchv1.Record{
			Id:      uint64(recordIDFirst + i),
			Key:     fmt.Sprintf("record-%05d", i),
			Payload: payload,
			Values:  values,
			Weight:  float64(i) * weightStep,
			Status:  benchv1.Status(i % statusCount),
		}
	}
	return &benchv1.Large{Name: "Large benchmark batch", Records: records, Description: strings.Repeat(descriptionPhrase, descriptionRepeats)}
}

func newDeep() *benchv1.Deep {
	var child *benchv1.Deep
	for i := deepLevelsCount - 1; i >= 0; i-- {
		child = &benchv1.Deep{Level: int32(i + 1), Label: fmt.Sprintf("level-%02d", i), Child: child}
	}
	return child
}

// newVarints holds every varint kind at each length from 1 to 10 bytes, as bench/inputs.zig.
func newVarints() *benchv1.Varints {
	return &benchv1.Varints{
		Int32One:      100,
		Int32Two:      300,
		Int32Negative: -1,
		Int64Three:    100_000,
		Int64Eight:    1 << 50,
		Uint32Four:    1 << 22,
		Uint32Five:    4_000_000_000,
		Uint64Six:     1 << 36,
		Uint64Ten:     math.MaxUint64,
		Sint32One:     -5,
		Sint32Three:   -50_000,
		Sint64Seven:   -(1 << 44),
		Sint64Nine:    1 << 60,
		Flag:          true,
		Status:        benchv1.Status_STATUS_CLOSED,
		Uint64Two:     200,
	}
}

func newStrings() *benchv1.Strings {
	return &benchv1.Strings{
		One:       asciiText[:1],
		Three:     asciiText[:3],
		Seven:     asciiText[:7],
		Eight:     asciiText[:8],
		Fifteen:   asciiText[:15],
		Sixteen:   asciiText[:16],
		ThirtyOne: asciiText[:31],
		ThirtyTwo: asciiText[:32],
		SixtyFour: asciiText[:64],
		Latin:     "données, ünïcode",
		Cjk:       "日本語のテキスト",
	}
}

// newTree builds a node with treeFanout children on each level, treeLevelsCount levels deep.
func newTree(levels int) *benchv1.Tree {
	node := &benchv1.Tree{}
	if levels == 0 {
		return node
	}
	for i := 0; i < treeFanout; i++ {
		node.Children = append(node.Children, newTree(levels-1))
	}
	return node
}

func newPacked() *benchv1.Packed {
	message := &benchv1.Packed{}
	for i := 0; i < packedCount; i++ {
		message.Small = append(message.Small, int32(i))
		message.Wide = append(message.Wide, uint64(1)<<i)
		message.Zigzag = append(message.Zigzag, int32(i-packedCount/2))
		message.Reals = append(message.Reals, float64(i)*realStep)
	}
	return message
}
