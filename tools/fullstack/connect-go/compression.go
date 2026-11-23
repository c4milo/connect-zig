package main

import (
	"io"

	"connectrpc.com/connect"
	"github.com/andybalholm/brotli"
	"github.com/klauspost/compress/zstd"
)

// The brotli level the receiver answers in, which no client of the check asks for: an export's
// answer is empty. It is andybalholm/brotli's default.
const brotliLevel = brotli.DefaultCompression

// compressions gives the handler zstd, with klauspost/compress, and brotli, with
// andybalholm/brotli, beside the gzip connect-go holds, so it reads an export in each. Each
// keeps its library's defaults: with GOMAXPROCS=1, klauspost's decoder decodes on the handler's
// goroutine.
func compressions() connect.HandlerOption {
	return connect.WithHandlerOptions(
		connect.WithCompression("zstd", newZstdDecompressor, newZstdCompressor),
		connect.WithCompression("br", newBrotliDecompressor, newBrotliCompressor),
	)
}

// zstdDecompressor keeps its decoder when connect-go's pool closes it, so the pool can use it
// again: klauspost's Close ends the decoder for good.
type zstdDecompressor struct{ *zstd.Decoder }

func (zstdDecompressor) Close() error { return nil }

func newZstdDecompressor() connect.Decompressor {
	decoder, err := zstd.NewReader(nil)
	if err != nil {
		panic(err)
	}
	return zstdDecompressor{decoder}
}

func newZstdCompressor() connect.Compressor {
	encoder, err := zstd.NewWriter(nil)
	if err != nil {
		panic(err)
	}
	return encoder
}

// brotliDecompressor adds the Close that andybalholm's reader lacks.
type brotliDecompressor struct{ *brotli.Reader }

func (brotliDecompressor) Close() error { return nil }

func newBrotliDecompressor() connect.Decompressor {
	return brotliDecompressor{brotli.NewReader(nil)}
}

func newBrotliCompressor() connect.Compressor {
	return brotli.NewWriterLevel(io.Discard, brotliLevel)
}
