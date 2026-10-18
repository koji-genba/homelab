"""Export the pinned safetensors as FP32 ONNX, preserving TEI Candle's GELU."""
import hashlib
import json
from pathlib import Path
import shutil

from huggingface_hub import snapshot_download
import onnx
import torch
import transformers
from transformers import AutoModelForSequenceClassification, AutoTokenizer

MODEL = 'cl-nagoya/ruri-v3-reranker-310m'
REVISION = 'bb46934ee9ed09f850b9fcff17501b3ef7ddb2b3'
SOURCE = Path('/source')
DEST = Path('/model')


def main():
    snapshot_download(
        MODEL, revision=REVISION, local_dir=SOURCE, token=False, max_workers=2,
        allow_patterns=['model.safetensors', 'config.json', 'tokenizer.json',
                        'tokenizer_config.json', 'special_tokens_map.json', 'README.md'],
    )
    card = (SOURCE / 'README.md').read_text()
    if 'license: apache-2.0' not in card:
        raise ValueError('Review model redistribution license before building')
    # Downloaded model repositories are data; never execute remote model code
    # or load pickle weights. Both MLP and classification head use tanh GELU in
    # TEI Candle (linear.rs HiddenAct::Gelu), unlike Transformers' default erf.
    torch.set_num_threads(6)
    activation = dict(hidden_activation='gelu_pytorch_tanh',
                      classifier_activation='gelu_pytorch_tanh')
    model = AutoModelForSequenceClassification.from_pretrained(
        SOURCE, local_files_only=True, trust_remote_code=False, use_safetensors=True,
        dtype=torch.float32, attn_implementation='eager', reference_compile=False,
        **activation,
    ).eval()
    tokenizer = AutoTokenizer.from_pretrained(
        SOURCE, local_files_only=True, trust_remote_code=False,
    )

    class Logits(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, input_ids, attention_mask):
            return self.inner(input_ids=input_ids, attention_mask=attention_mask).logits

    DEST.mkdir()
    inputs = tokenizer(['検索クエリ', '比較'], ['候補文書', '別の文章です'],
                       padding=True, return_tensors='pt')
    with torch.inference_mode():
        torch.onnx.export(
            Logits(model), (inputs['input_ids'], inputs['attention_mask']), DEST / 'model.onnx',
            input_names=['input_ids', 'attention_mask'], output_names=['logits'],
            dynamic_axes={
                'input_ids': {0: 'batch_size', 1: 'sequence_length'},
                'attention_mask': {0: 'batch_size', 1: 'sequence_length'},
                'logits': {0: 'batch_size'},
            },
            opset_version=17, dynamo=False, external_data=False,
        )
    onnx.checker.check_model(str(DEST / 'model.onnx'))
    for name in ['config.json', 'tokenizer.json', 'tokenizer_config.json', 'special_tokens_map.json']:
        shutil.copyfile(SOURCE / name, DEST / name)
    config = json.loads((DEST / 'config.json').read_text())
    config.update(activation)
    (DEST / 'config.json').write_text(json.dumps(config, indent=2) + '\n')
    for name in ['LICENSE', 'NOTICE']:
        shutil.copyfile(Path('/build') / name, DEST / name)
    shutil.copyfile(SOURCE / 'README.md', DEST / 'MODEL_CARD.md')
    with (DEST / 'model.onnx').open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    manifest = dict(model=MODEL, revision=REVISION, model_sha256=digest,
                    torch=torch.__version__, transformers=transformers.__version__,
                    onnx=onnx.__version__, opset=17, dtype='float32',
                    dynamic_axes=['batch_size', 'sequence_length'], **activation)
    (DEST / 'export.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (DEST / 'SHA256SUMS').write_text(digest + '  model.onnx\n')
    print(json.dumps(manifest), flush=True)
    # HF local-dir bookkeeping is unnecessary in the reference image.
    shutil.rmtree(SOURCE / '.cache', ignore_errors=True)


if __name__ == '__main__':
    main()
