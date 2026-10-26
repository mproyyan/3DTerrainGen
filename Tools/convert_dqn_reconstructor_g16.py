"""Export the frozen DQN V3 reconstructor without changing its weights."""
import copy
import hashlib
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

ROOT = Path('/Users/daffaburanenugraha/Developer/cpt_super_learn')
sys.path.insert(0, str(ROOT))
from schemagan3d.train_v3 import _models
from scripts.coreml_conversion.convert_model_c_v2 import replace_instance_norm

CHECKPOINT = ROOT / 'results/schemagan3d_v3_training_continuation/mse_continuation/best.pt'
CONFIG = ROOT / 'results/schemagan3d_v3_training_continuation/mse_continuation_config.json'
DEST = Path('/private/tmp/DQNReconstructorG16.mlpackage')
EXPECTED_SHA = '5694bb7b43efd7054a99fac8b74dadc5d74ebe6d291f42a8393b57fe9da52b64'

class Wrapper(torch.nn.Module):
    def __init__(self, backbone):
        super().__init__()
        self.backbone = backbone
    def forward(self, sparse, mask, idw):
        return self.backbone(sparse, mask, idw)[1]

def main():
    assert hashlib.sha256(CHECKPOINT.read_bytes()).hexdigest() == EXPECTED_SHA
    if not hasattr(np, '_core'):
        sys.modules.setdefault('numpy._core', np.core)
        sys.modules.setdefault('numpy._core.multiarray', np.core.multiarray)
        sys.modules.setdefault('numpy._core.numeric', np.core.numeric)
    saved = torch.load(CHECKPOINT, map_location='cpu', weights_only=False)
    assert saved['epoch'] == 26 and saved['model_variant'] == 'idw_guided_residual'
    assert saved['objective_variant'] == 'mse_only'
    config = json.loads(CONFIG.read_text())
    model, _ = _models(config)
    model.load_state_dict(saved['generator_state'], strict=True)
    model.eval()
    adapted = copy.deepcopy(model)
    assert replace_instance_norm(adapted) > 0
    adapted.eval()
    sample = tuple(torch.zeros((1, 1, 16, 16, 16), dtype=torch.float32) for _ in range(3))
    sample[1][0, 0, :, 8, 8] = 1
    sample[0][0, 0, :, 8, 8] = 0.2
    sample[2][:] = 0.2
    with torch.no_grad():
        expected = Wrapper(model)(*sample).numpy()
        adapted_result = Wrapper(adapted)(*sample).numpy()
        assert np.max(np.abs(expected - adapted_result)) < 1e-5
        traced = torch.jit.trace(Wrapper(adapted).eval(), sample, strict=True)
    np.savez('/private/tmp/dqn_reconstructor_g16_parity.npz',
             sparse=sample[0].numpy(), mask=sample[1].numpy(),
             idw=sample[2].numpy(), expected=expected)
    if DEST.exists():
        raise FileExistsError(f"Refusing to overwrite {DEST}")
    mlmodel = ct.convert(
            traced, convert_to='mlprogram',
            inputs=[ct.TensorType(name=name, shape=(1, 1, 16, 16, 16), dtype=np.float32)
                    for name in ('sparse', 'mask', 'idw')],
            outputs=[ct.TensorType(name='reconstruction', dtype=np.float32)],
            minimum_deployment_target=ct.target.iOS16,
            compute_precision=ct.precision.FLOAT32,
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )
    mlmodel.save(str(DEST))
    print('checkpoint_sha256', EXPECTED_SHA)
    print('model', DEST)
    print('parity_fixture', '/private/tmp/dqn_reconstructor_g16_parity.npz')
    print('Compile and compare this package against the saved PyTorch parity fixture before deployment.')

if __name__ == '__main__':
    main()
