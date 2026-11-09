import Foundation

struct HardLayerIndication: Sendable {
    let depth: Double
    let confirmedUntilDepth: Double
    let startQcMPa: Double
    let meanQcMPa: Double
}

/// Configurable PoC criterion only. This is experimental, has not been validated
/// for foundation design, and is not ground-truth hard-layer depth.
enum HardLayerAnalysisService {
    static let qcThresholdMPa = 19.613
    static let minimumContinuousThicknessM = 0.50

    static func measuredSamples(for point: CPTPoint) -> [CPTSample]? {
        guard point.dataOrigin == .entered, point.interpretation != nil,
              !point.csv.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }
        return try? CPTProcessor.parse(point.csv)
    }

    static func indication(for point: CPTPoint) -> HardLayerIndication? {
        guard let samples = measuredSamples(for:point) else { return nil }
        return indication(samples:samples)
    }

    static func indication(samples: [CPTSample]) -> HardLayerIndication? {
        guard !samples.isEmpty else { return nil }
        var startDepth: Double?, startQc = 0.0, sumQc = 0.0, count = 0
        var previousDepth = -Double.infinity
        for sample in samples {
            guard sample.depth.isFinite, sample.qcMPa.isFinite,
                  sample.depth > previousDepth else { return nil }
            previousDepth = sample.depth
            if sample.qcMPa >= qcThresholdMPa {
                if startDepth == nil {
                    startDepth = sample.depth; startQc = sample.qcMPa
                    sumQc = 0; count = 0
                }
                sumQc += sample.qcMPa; count += 1
                if let startDepth,
                   sample.depth - startDepth >= minimumContinuousThicknessM - 1e-9 {
                    return .init(depth:startDepth, confirmedUntilDepth:sample.depth,
                                 startQcMPa:startQc, meanQcMPa:sumQc / Double(count))
                }
            } else {
                startDepth = nil; sumQc = 0; count = 0
            }
        }
        return nil
    }

    /// Uses the same boundary-aware cell mapping as SchemaGAN input. A tap on an
    /// adjacent reconstructed cell must not inherit a measured CPT's qc profile.
    static func measuredPoint(gridX: Int, gridY: Int, volume: ReconstructionVolume,
                              points: [CPTPoint], boundary: [GeoPoint]) -> CPTPoint? {
        let polygon = boundary.map { CoordinateTransformer.localMeters($0,origin:volume.terrainOrigin) }
        return points.compactMap { point -> (CPTPoint,Double)? in
            guard measuredSamples(for:point) != nil else { return nil }
            let local = CoordinateTransformer.localMeters(point.coordinate,origin:volume.terrainOrigin)
            guard let mapping = try? V42CPTGridMapper.map(local,name:point.name,polygon:polygon,
                west:volume.westMeters,south:volume.southMeters,nx:volume.grid.nx,ny:volume.grid.ny,
                dx:volume.grid.spacingMeters,dy:volume.grid.northSpacingMeters,validXY:volume.validXY),
                mapping.x == gridX, mapping.y == gridY,
                (0..<volume.grid.nz).contains(where: { volume.observed[volume.grid.index(x:gridX,y:gridY,z:$0)] })
            else { return nil }
            return (point,hypot(local.x-volume.east(x:gridX),local.y-volume.north(y:gridY)))
        }.min(by: { $0.1 < $1.1 })?.0
    }
}
