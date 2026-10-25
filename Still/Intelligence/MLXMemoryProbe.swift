import MLX

/// MLX keeps model weights and its buffer cache in GPU-visible memory that
/// the process footprint only partly shows. Registered once a model loads, so
/// reading it never starts Metal on its own.
enum MLXMemoryProbe {
    static func register() {
        ResourceProbes.register("mlx") {
            [
                "mlxActiveMB": megabytes(Memory.activeMemory),
                "mlxCacheMB": megabytes(Memory.cacheMemory),
                "mlxPeakMB": megabytes(Memory.peakMemory),
            ]
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
    }
}
