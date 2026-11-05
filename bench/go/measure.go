package main

// Times one operation as bench/measure.zig does: finds how many iterations fill a batch of the
// target length, runs one batch to warm up, then times the runs and returns the median time of
// one iteration.

import (
	"sort"
	"time"
)

// Calibration doubles the iterations at most this many times.
const doublingsMax = 40

type settings struct {
	runs    int
	batchNs int64
}

var (
	full  = settings{runs: 11, batchNs: 20 * int64(time.Millisecond)}
	quick = settings{runs: 3, batchNs: int64(time.Millisecond)}
)

func medianNs(current settings, run func(n uint64) error) (float64, error) {
	iterations, err := calibrate(current, run)
	if err != nil {
		return 0, err
	}
	if _, err := timeBatch(run, iterations); err != nil {
		return 0, err
	}
	perIteration := make([]float64, current.runs)
	for i := range perIteration {
		elapsed, err := timeBatch(run, iterations)
		if err != nil {
			return 0, err
		}
		perIteration[i] = float64(elapsed) / float64(iterations)
	}
	sort.Float64s(perIteration)
	return perIteration[len(perIteration)/2], nil
}

func calibrate(current settings, run func(n uint64) error) (uint64, error) {
	iterations := uint64(1)
	for i := 0; i < doublingsMax; i++ {
		elapsed, err := timeBatch(run, iterations)
		if err != nil {
			return 0, err
		}
		if elapsed >= current.batchNs {
			return iterations, nil
		}
		iterations *= 2
	}
	return iterations, nil
}

func timeBatch(run func(n uint64) error, iterations uint64) (int64, error) {
	start := time.Now()
	err := run(iterations)
	return time.Since(start).Nanoseconds(), err
}
