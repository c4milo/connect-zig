package main

// The fixed messages of bench/inputs.zig, built the same way: every value follows from its
// index, so Zig and Go encode the same message.

import (
	"fmt"
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
