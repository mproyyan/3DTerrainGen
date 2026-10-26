import Foundation

/// Published offline research results, never a measurement of the current site.
enum ModelEvaluationMetrics {
    // SchemaGAN V3 MSE continuation, epoch 26: 400 synthetic validation volumes.
    // Mean per-volume RMSE on hidden valid voxels, in physical Ic units.
    private static let schemaGANRMSE: [Int: Double] = [
        1: 0.17925, 2: 0.16734, 3: 0.15935, 5: 0.14912, 8: 0.13668
    ]

    // DQN V3 final hybrid: 1,000 synthetic test-ID volumes per CPT count.
    // Reconstruction RMSE AFTER adding the policy's recommended CPT.
    private static let dqnAfterRMSE: [Int: Double] = [
        1: 0.168331, 2: 0.158812, 3: 0.151702, 5: 0.141324, 8: 0.129344
    ]

    static func summary(observedCPTCount: Int, windowed: Bool) -> String? {
        guard let schemaGAN = schemaGANRMSE[observedCPTCount],
              let dqn = dqnAfterRMSE[observedCPTCount] else { return nil }
        let caveat = windowed ? " Windowed belum dievaluasi dengan protokol ini." : ""
        return String(format:
            "Referensi sintetis (%d CPT): SchemaGAN rekonstruktor DQN RMSE Ic %.5f (validasi); kebijakan DQN V3 RMSE Ic setelah CPT pilihan %.6f (uji). Visual 3D memakai Model C Flexible. Dataset berbeda; bukan akurasi area ini.%@",
            observedCPTCount, schemaGAN, dqn, caveat)
    }
}
