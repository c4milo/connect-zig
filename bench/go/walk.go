package main

// Reads every field of a message and folds what it read into one number, as bench/walk.zig does:
// each integer and enum as a sign-extended 64-bit value, each bool as 0 or 1, each float's bits,
// and each string's and bytes field's length, added with wrapping in field-number order.

import (
	"math"

	benchv1 "github.com/c4milo/connect-zig/bench/go/gen/bench/v1"
)

func walkSmall(m *benchv1.Small) uint64 {
	sum := uint64(int64(m.Id))
	sum += uint64(m.Created)
	if m.Active {
		sum++
	}
	sum += uint64(len(m.Name))
	sum += math.Float64bits(m.Score)
	return sum
}

func walkAddress(m *benchv1.Address) uint64 {
	if m == nil {
		return 0
	}
	return uint64(len(m.Street)) + uint64(len(m.City)) + uint64(len(m.Country)) + uint64(m.PostalCode)
}

func walkMedium(m *benchv1.Medium) uint64 {
	sum := m.Id
	sum += uint64(len(m.Name))
	sum += uint64(int64(m.Status))
	sum += walkAddress(m.Home)
	for _, sample := range m.Samples {
		sum += uint64(sample)
	}
	for _, tag := range m.Tags {
		sum += uint64(len(tag))
	}
	sum += walkCounters(m.Counters)
	switch contact := m.Contact.(type) {
	case *benchv1.Medium_Email:
		sum += uint64(len(contact.Email))
	case *benchv1.Medium_Phone:
		sum += uint64(len(contact.Phone))
	case *benchv1.Medium_Office:
		sum += walkAddress(contact.Office)
	}
	for _, address := range m.Previous {
		sum += walkAddress(address)
	}
	sum += m.Checksum
	sum += uint64(math.Float32bits(m.Ratio))
	sum += uint64(int64(m.Delta))
	return sum
}

// Addition does not depend on order, so the map is read in Go's order.
func walkCounters(counters map[string]int64) uint64 {
	var sum uint64
	for key, value := range counters {
		sum += uint64(len(key)) + uint64(value)
	}
	return sum
}

func walkRecord(m *benchv1.Record) uint64 {
	sum := m.Id
	sum += uint64(len(m.Key))
	sum += uint64(len(m.Payload))
	for _, value := range m.Values {
		sum += uint64(int64(value))
	}
	sum += math.Float64bits(m.Weight)
	sum += uint64(int64(m.Status))
	return sum
}

func walkLarge(m *benchv1.Large) uint64 {
	sum := uint64(len(m.Name))
	for _, record := range m.Records {
		sum += walkRecord(record)
	}
	return sum
}

func walkDeep(m *benchv1.Deep) uint64 {
	var sum uint64
	for node := m; node != nil; node = node.Child {
		sum += uint64(int64(node.Level))
		sum += uint64(len(node.Label))
	}
	return sum
}
