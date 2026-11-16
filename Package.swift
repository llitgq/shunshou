// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shunshou",
    platforms: [.macOS("15.0")],   // 系统翻译框架 TranslationSession 要 15+；产品最低要求 macOS 15
    targets: [
        // sherpa-onnx v2.0.1 静态库（语音输入 v22）：头文件 + 13 个 .a 全静态链进二进制，
        // 运行时零 dylib 依赖。systemLibrary 本身不带 settings——头搜索路径与链接 flags
        // 统一挂在下游 Shunshou target 的 unsafeFlags 上（见下）。
        .systemLibrary(
            name: "CSherpaOnnx",
            path: "Vendor/CSherpaOnnx"
        ),
        .executableTarget(
            name: "Shunshou",
            dependencies: ["CSherpaOnnx"],
            path: "Sources/Shunshou",
            swiftSettings: [
                // modulemap 里 shim.h → "sherpa-onnx/c-api/c-api.h" 按这个根解析
                .unsafeFlags(["-I", "Vendor/sherpa-onnx/include"])
            ],
            linkerSettings: [
                // 链接顺序照 Cadenza build.sh（c-api → core → onnxruntime → kaldi 系 → fst 系）
                .unsafeFlags([
                    "-L", "Vendor/sherpa-onnx/lib",
                    "-lsherpa-onnx-c-api", "-lsherpa-onnx-core", "-lonnxruntime",
                    "-lkaldi-native-fbank-core", "-lkaldi-decoder-core", "-lkissfft-float",
                    "-lsherpa-onnx-fst", "-lsherpa-onnx-fstfar", "-lsherpa-onnx-kaldifst-core",
                    "-lssentencepiece_core", "-lutf8proc",
                    "-lc++", "-lz",
                ])
            ]
        )
    ]
)
