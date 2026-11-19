# 研究版分发说明

本仓库为源码公开的学习研究项目，使用范围见根目录 LICENSE。第三方源码保留原许可；完整运行资源通过研究版 Release 分发，不能据此获得商业用途授权。

Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement.

MobileCLIP2-S2 的 Core ML 产物由官方检查点转换为 FP16 图像编码器；已修改模型格式与数值精度，非 Apple 官方原始分发包，未以 Apple 名义背书。

# Third-Party Components

GATHER bundles the following upstream sources and model assets. Local changes include package paths, removing declarations for the omitted MLXMNIST and StableDiffusion example modules, and excluding Metal shader sources from the C++ target. The runtime uses the matching upstream precompiled Metal library instead. Original copyright and license files are retained in vendor/ and copied into resources/licenses/ for redistribution with the complete project folder.

| Component | Pinned Source |
| --- | --- |
| Qwen3-VL-4B-Instruct-4bit | mlx-community conversion, ModelScope revision a0d14395b0ef9f23cb8c0abae8bba65e84601339; Apache-2.0 per included model card. |
| mlx-swift-lm | ml-explore/mlx-swift-lm, tag 2.29.1 |
| mlx-swift | ml-explore/mlx-swift, tag 0.29.1 |
| MLX core | ml-explore/mlx, commit ee18e1cbf0ab7937578d716cc1b62b3fb1725e27 |
| MLX Metal library | Apple-owned mlx-metal 0.29.1 release on PyPI, macOS 14 arm64; MIT license in resources/licenses/mlx-metal/ |
| mlx-c | ml-explore/mlx-c, commit d5b8715b8e540ea69a955b2d3812e67ccad4c79e |
| swift-transformers | huggingface/swift-transformers, tag 1.0.0 |
| swift-jinja | huggingface/swift-jinja, tag 2.0.0 |
| swift-numerics | apple/swift-numerics, tag 1.0.2 |
| swift-collections | apple/swift-collections, tag 1.1.4, commit 671108c96644956dddcd89dd59c203dcdb36cec7 |
| GzipSwift | 1024jp/GzipSwift, tag 6.0.1 |
| MobileCLIP2-S2 image encoder | Official apple-aiml-research/ml-mobileclip code commit 48faa0fea4b08d74188b3841771aca6ff2c92852; apple/MobileCLIP2-S2 checkpoint revision 72424e7025436db18f15c3eff6ee8c7c15ad4481. Bundled as an FP16 Core ML compiled image encoder. |
| metal-cpp, fmt, nlohmann/json | Included upstream copies inside mlx-swift 0.29.1 |

The model revision, original file sizes, and SHA-256 digests are recorded in resources/models/Qwen3-VL-4B-Instruct-4bit/source-manifest.json. The supplementary Apache-2.0 license text was obtained from QwenLM/Qwen3-VL LICENSE. No Python package described in the upstream model card is required by GATHER.

swift-collections was updated from 1.0.0 to 1.1.4 for Swift 6 Sendable compatibility with Jinja 2.0.0. The official source archive SHA-256 is 41f15c8768f726c0cd4f4b0c63eea7b241c11260b82c33f0b1f4bb8737cabe43. The previous vendored source is retained under .downloads/swift-collections-1.0.0-source for build history only and is not used at runtime.

The Swift Transformers fallback tokenizer configuration lookup was changed to resolve swift-transformers_Hub.bundle beside the executable. It no longer invokes SwiftPM's generated developer-machine fallback accessor.

The Metal library is extracted from the official mlx_metal-0.29.1-py3-none-macosx_14_0_arm64.whl release. The archive SHA-256 is 824b939b721a964a455aeea4d0e956e4cc945f3333522c1e72a077ae774bca49. The extracted mlx.metallib SHA-256 is 6268384b64f137142a70cdd0d1f266cf675b101239d7a7021e4589c77b36f92d. MLX tag v0.29.1 resolves to the same core commit already vendored here. Provenance is recorded in resources/runtime/source-manifest.json. No Python module or libmlx.dylib from the wheel is installed or used.

## Visual Memory Update (2026-11-16)

MobileCLIP2 source and model license texts, plus upstream acknowledgements, are retained in resources/licenses/mobileclip2/. Full source/checkpoint and compiled-file digests, preprocessing, and conversion parity results are in resources/models/visual-memory/mobileclip2-manifest.json. The original checkpoint SHA-256 is 37c2d839a856491f2fcc82c40dc28672dbd0907235b4cd4c38dfff6457f0c09f. The development conversion scripts are not recipient runtime dependencies. Official source: https://github.com/apple-aiml-research/ml-mobileclip ; model: https://huggingface.co/apple/MobileCLIP2-S2 . The earlier MobileCLIP artifact remains for development comparison; the active encoder identity is mobileclip2-s2-72424e70-center256-v1.

The visual cache affinity kernel was independently implemented in Swift from the Tip-Adapter cache equation. The old top-three affinity classifier was replaced by ridge learning. On 2026-11-17 the exponential kernel is also used to compare human-confirmed positive and negative examples when limiting an experience's applicability. No Tip-Adapter SDK or upstream source code is bundled. Reference: https://github.com/gaopengcuhk/Tip-Adapter .

LangMem's memory-type separation and reconciliation concepts informed the application-specific feedback design. LangMem itself is not installed or integrated, and no LangMem code or hosted service is needed at runtime. Reference: https://langchain-ai.github.io/langmem/concepts/conceptual_guide/ . Upstream results are not presented as measured GATHER accuracy.

## Trainable Personal Classifier and Storage (2026-11-16)

The native classifier independently implements fixed-feature ridge regression, corresponding to the M=0/decorrelation branch of RanPAC's official implementation (commit cf4b301d18b0c27db030f4371b72b768005ae58a). GATHER adds a bias feature, replays retained local examples for revocation, and uses task-grouped validation plus scoped VLM review. It does not bundle RanPAC's PyTorch framework, random-projection expansion or benchmark assets, and does not claim those benchmark results. Official implementation: https://github.com/RanPAC/RanPAC/blob/cf4b301d18b0c27db030f4371b72b768005ae58a/RanPAC.py .

Matrix accumulation and the positive-definite linear solve use Apple's system Accelerate BLAS/LAPACK implementation. Storage uses the system SQLite C API with full-synchronous transactions and a rollback journal. These libraries are supplied by macOS and do not require a recipient-side package installation. References: https://developer.apple.com/documentation/accelerate/solving-systems-of-linear-equations-with-lapack and https://www.sqlite.org/atomiccommit.html .

The 162-sample learning-seed.json contains only visual features and labels from the user-provided dataset's original training split; it excludes that split's validation/test entries. SHA256: 0a3898fc5d0d833e6287d0c10c07f51c33f1a2addfa81b85a9040035e5b480aa. Python/NumPy is used solely for a development numerical parity check, not the portable runtime.

Provenance clarification (2026-11-17): the seed was generated only from the original 162 training entries, not by adding the Wangcheng evaluation set. A later content audit found two identical images across those separately supplied collections. One was on the evaluation side and had a conflicting developer label; the new full comparison excludes it. The earlier sentence must not be read as a guarantee of image-level disjointness between source collections.

The positive/negative memory design also references TDA (CVPR 2024), https://github.com/kdiAAA/TDA and https://arxiv.org/abs/2403.18293 . GATHER uses human-confirmed counterexamples and scoped applicability boundaries, not TDA's unsupervised pseudo-label update loop. No TDA package or code is bundled, and its benchmark figures are not GATHER results. The outfit-condition interpreter and native workflow are application-specific integration over the existing local VLM and SQLite store.
