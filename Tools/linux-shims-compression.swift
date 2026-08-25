// Substitut du cadre Compression, pour Tools/run-tests.sh et Tools/typecheck.sh sur Linux.
// Ce fichier ne fait pas partie de l'app. Il ne décompresse rien : les tests portent sur la
// lecture de l'archive et le traitement du XML, avec des pièces rangées sans compression.
#if !canImport(Compression)
import Foundation

let COMPRESSION_ZLIB: Int32 = 0

func compression_decode_buffer(
    _ destination: UnsafeMutablePointer<UInt8>,
    _ destinationSize: Int,
    _ source: UnsafePointer<UInt8>,
    _ sourceSize: Int,
    _ scratch: UnsafeMutableRawPointer?,
    _ algorithm: Int32
) -> Int {
    0
}
#endif
