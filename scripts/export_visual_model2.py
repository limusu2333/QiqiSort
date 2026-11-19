"""Developer-only, pinned official MobileCLIP2 image encoder to portable CoreML."""
import hashlib
import json
from pathlib import Path
import sys
import time

import coremltools as ct
import numpy as np
from PIL import Image, ImageOps
import torch

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / '.build/visual-model2'
sys.path.insert(0, str(WORK / 'source'))
import mobileclip

torch.set_num_threads(4)
acquisition = json.loads((WORK / 'acquisition.json').read_text())
weights = WORK / 'mobileclip2_s2.pt'
assert hashlib.sha256(weights.read_bytes()).hexdigest() == '37c2d839a856491f2fcc82c40dc28672dbd0907235b4cd4c38dfff6457f0c09f'


class ImageEncoder(torch.nn.Module):
    def __init__(self, encoder):
        super().__init__()
        self.encoder = encoder

    def forward(self, image):
        return torch.nn.functional.normalize(self.encoder(image), dim=-1)


def main():
    started = time.monotonic()
    # S2 architecture is shared; create_model_and_transforms loads ALL official
    # checkpoint keys strictly, then folds training branches for inference.
    original, _, preprocess = mobileclip.create_model_and_transforms('mobileclip_s2', pretrained=str(weights))
    original.eval()
    encoder = ImageEncoder(original.image_encoder).eval()
    example = torch.rand(1, 3, 256, 256)
    with torch.no_grad():
        traced = torch.jit.trace(encoder, example)
    path = WORK / 'MobileCLIP2.mlpackage'
    if path.exists():
        model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
    else:
        model = ct.convert(traced, inputs=[ct.ImageType(name='image', shape=example.shape,
            scale=1/255, color_layout=ct.colorlayout.RGB)],
            outputs=[ct.TensorType(name='embedding', dtype=np.float32)],
            minimum_deployment_target=ct.target.macOS14,
            compute_precision=ct.precision.FLOAT16,
            compute_units=ct.ComputeUnit.CPU_ONLY)
        model.author = 'Apple; GATHER image-only export'
        model.short_description = 'MobileCLIP2-S2 official weights; normalized 512-dimensional image embedding'
        model.version = acquisition['revision']
        model.user_defined_metadata['source_sha256'] = hashlib.sha256(weights.read_bytes()).hexdigest()
        model.user_defined_metadata['preprocessing'] = 'RGB center crop 256; input RGB / 255; no mean or std normalization'
        model.save(str(path))
    rows = []
    paths = sorted((ROOT / '.build/wangcheng-20261115/input').glob('*.jpg'))[:8]
    assert len(paths) == 8, 'Need eight real parity photos'
    for photo in paths:
        image = ImageOps.exif_transpose(Image.open(photo)).convert('RGB')
        tensor = preprocess(image).unsqueeze(0)
        with torch.no_grad():
            expected = encoder(tensor).numpy().reshape(-1)
        # Use exactly the official resized/cropped pixels to isolate export precision.
        pixels = np.asarray(torch.round(tensor[0].permute(1, 2, 0) * 255).to(torch.uint8))
        begin = time.monotonic()
        actual = np.asarray(model.predict({'image': Image.fromarray(pixels)})['embedding']).reshape(-1)
        seconds = time.monotonic() - begin
        cosine = float(np.dot(expected, actual) / (np.linalg.norm(expected) * np.linalg.norm(actual)))
        assert actual.shape == (512,) and np.isfinite(actual).all() and cosine > .999, (photo, cosine)
        rows.append({'photo': photo.name, 'cosine': cosine, 'seconds': seconds,
            'maxAbsoluteError': float(np.max(np.abs(expected - actual)))})
    receipt = dict(acquisition, preprocessing=str(preprocess), parity=rows,
        minimumCosine=min(row['cosine'] for row in rows), seconds=time.monotonic() - started)
    (WORK / 'export-receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps({'package':str(path),'minimumCosine':receipt['minimumCosine'],
        'seconds':receipt['seconds']}, indent=2))


if __name__ == '__main__':
    main()
