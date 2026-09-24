import Foundation

/// The catalog ships compiled into the app rather than fetched, so the pinned
/// versions and digests inherit the app's code signature and no network request
/// is needed to learn what Still would download.
enum ModelCatalog {
    static let parakeetV3 = ModelPack(
        id: "parakeet-tdt-0.6b-v3",
        purpose: String(localized: "Turns speech into accurate text on this device, in English and 24 other European languages."),
        version: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        baseURL: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/7dd20fe6b1797d35f5e3307e8b1732d9a178edfe/")!,
        minimumMemoryBytes: 4 * 1_024 * 1_024 * 1_024,
        files: [
            ModelFile(path: "Decoder.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
            ModelFile(path: "Decoder.mlmodelc/coremldata.bin", bytes: 554, sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
            ModelFile(path: "Decoder.mlmodelc/metadata.json", bytes: 3427, sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
            ModelFile(path: "Decoder.mlmodelc/model.mil", bytes: 13110, sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
            ModelFile(path: "Decoder.mlmodelc/weights/weight.bin", bytes: 23604992, sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
            ModelFile(path: "Encoder.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
            ModelFile(path: "Encoder.mlmodelc/coremldata.bin", bytes: 485, sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
            ModelFile(path: "Encoder.mlmodelc/metadata.json", bytes: 2921, sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
            ModelFile(path: "Encoder.mlmodelc/model.mil", bytes: 959769, sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
            ModelFile(path: "Encoder.mlmodelc/weights/weight.bin", bytes: 445187200, sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
            ModelFile(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
            ModelFile(path: "JointDecisionv3.mlmodelc/coremldata.bin", bytes: 521, sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
            ModelFile(path: "JointDecisionv3.mlmodelc/metadata.json", bytes: 3453, sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
            ModelFile(path: "JointDecisionv3.mlmodelc/model.mil", bytes: 11775, sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
            ModelFile(path: "JointDecisionv3.mlmodelc/weights/weight.bin", bytes: 12642764, sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
            ModelFile(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            ModelFile(path: "Preprocessor.mlmodelc/coremldata.bin", bytes: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            ModelFile(path: "Preprocessor.mlmodelc/metadata.json", bytes: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
            ModelFile(path: "Preprocessor.mlmodelc/model.mil", bytes: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
            ModelFile(path: "Preprocessor.mlmodelc/weights/weight.bin", bytes: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            ModelFile(path: "parakeet_vocab.json", bytes: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ]
    )

    static let speakerSeparation = ModelPack(
        id: "speaker-separation",
        purpose: String(localized: "Tells apart the people speaking in a recording, on this device, and recognizes voices you have named before."),
        version: "sortformer-ae9a27ab-lseend-28ce1b1f-wespeaker-df2625ac",
        baseURL: URL(string: "https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml/resolve/ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1/v3/palettized/")!,
        minimumMemoryBytes: 4 * 1_024 * 1_024 * 1_024,
        files: [
            ModelFile(path: "\(SpeakerModels.smallMeeting)/analytics/coremldata.bin", bytes: 243, sha256: "d089abd182fa99fa06fc6b1ac4a19f4facf26efe463a525d955de7738b992911"),
            ModelFile(path: "\(SpeakerModels.smallMeeting)/coremldata.bin", bytes: 842, sha256: "d1d42633c334b71b94c04714e09edf3d68a38a6496f1ae851fd08dfef7571736"),
            ModelFile(path: "\(SpeakerModels.smallMeeting)/model.mil", bytes: 1808228, sha256: "6cf150303a99908f667564a9a63e5e13a9bcc43f6cdf78575865647a22631e68"),
            ModelFile(path: "\(SpeakerModels.smallMeeting)/weights/weight.bin", bytes: 90425472, sha256: "846e44443e302dc44c914ee807f29537e01ec67d1d463a61ef277e1198527138"),
            ModelFile(path: "\(SpeakerModels.largeMeeting)/analytics/coremldata.bin", bytes: 243, sha256: "eae41bbb03511ff0e04bb217b278b49e67a9744724c28ac2c3b1ecbb6a719544", source: SpeakerModels.largeMeetingSource),
            ModelFile(path: "\(SpeakerModels.largeMeeting)/coremldata.bin", bytes: 1413, sha256: "ca07a132288cc2acbaee7e034d18c3a9d66bd5be22617b52e9e812d160268ccf", source: SpeakerModels.largeMeetingSource),
            ModelFile(path: "\(SpeakerModels.largeMeeting)/metadata.json", bytes: 7024, sha256: "f0f4925a193fd765f54f2c9854b16ce4aaae344669d10c1bd412f498d009af6a", source: SpeakerModels.largeMeetingSource),
            ModelFile(path: "\(SpeakerModels.largeMeeting)/model.mil", bytes: 207939, sha256: "036a1b0a14ffc42e0ff66a16c955b1a79cbd95409d44c4cc571b29bbec79b86d", source: SpeakerModels.largeMeetingSource),
            ModelFile(path: "\(SpeakerModels.largeMeeting)/weights/weight.bin", bytes: 44407680, sha256: "0bf5dc575c0dcb1856eb21e25f401e9e45c183c663f6b6324404b650fdcdbec2", source: SpeakerModels.largeMeetingSource),
            ModelFile(path: "\(SpeakerModels.voiceprint)/analytics/coremldata.bin", bytes: 243, sha256: "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f", source: SpeakerModels.voiceprintSource),
            ModelFile(path: "\(SpeakerModels.voiceprint)/coremldata.bin", bytes: 359, sha256: "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7", source: SpeakerModels.voiceprintSource),
            ModelFile(path: "\(SpeakerModels.voiceprint)/metadata.json", bytes: 2738, sha256: "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758", source: SpeakerModels.voiceprintSource),
            ModelFile(path: "\(SpeakerModels.voiceprint)/model.mil", bytes: 706900, sha256: "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd", source: SpeakerModels.voiceprintSource),
            ModelFile(path: "\(SpeakerModels.voiceprint)/weights/weight.bin", bytes: 7243904, sha256: "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151", source: SpeakerModels.voiceprintSource),
        ]
    )

    static let meetingMemorySmall = meetingMemory(
        id: "qwen3-1.7b-4bit",
        repository: "mlx-community/Qwen3-1.7B-4bit",
        version: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
        minimumMemoryBytes: 6 * 1_024 * 1_024 * 1_024,
        config: ModelFile(path: "config.json", bytes: 937, sha256: "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7"),
        weights: ModelFile(path: "model.safetensors", bytes: 968_080_210, sha256: "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f")
    )

    static let meetingMemoryLarge = meetingMemory(
        id: "qwen3-4b-4bit",
        repository: "mlx-community/Qwen3-4B-4bit",
        version: "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25",
        minimumMemoryBytes: 12 * 1_024 * 1_024 * 1_024,
        config: ModelFile(path: "config.json", bytes: 937, sha256: "b5efdcf3b0035a3638e7228dad4d85f5c4a23f156eb7cdb0b44c8366a5d34d9b"),
        weights: ModelFile(path: "model.safetensors", bytes: 2_263_022_529, sha256: "e240c0bdc0ebb0681bf0da0f98d9719fd6ebe269a3633f81542c13e81345651d")
    )

    static func meetingMemory(forMemory bytes: Int) -> ModelPack {
        bytes >= meetingMemoryLarge.minimumMemoryBytes ? meetingMemoryLarge : meetingMemorySmall
    }

    private static func meetingMemory(
        id: String,
        repository: String,
        version: String,
        minimumMemoryBytes: Int,
        config: ModelFile,
        weights: ModelFile
    ) -> ModelPack {
        ModelPack(
            id: id,
            purpose: String(localized: "Finds decisions, facts and proposed tasks in your recordings, on this device. Without it, Still quotes the matching sentences instead."),
            version: version,
            baseURL: URL(string: "https://huggingface.co/\(repository)/resolve/\(version)/")!,
            minimumMemoryBytes: minimumMemoryBytes,
            files: [
                config,
                ModelFile(path: "tokenizer_config.json", bytes: 9706, sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"),
                ModelFile(path: "tokenizer.json", bytes: 11_422_654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
                weights,
            ]
        )
    }
}

enum SpeakerModels {
    static let smallMeeting = "SortformerOffline_v2.1.mlmodelc"
    static let largeMeeting = "ls_eend_dih3_100ms.mlmodelc"
    static let voiceprint = "wespeaker_v2.mlmodelc"
    static let voiceprintSource = URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/df2625ac79a7ac6b65ad868fee6d80f320da4232/")!
    static let largeMeetingSource = URL(string: "https://huggingface.co/FluidInference/ls-eend-coreml/resolve/28ce1b1f8ef186729df63b3886fbaae7bc10c4a1/optimized/dih3/100ms/")!
}
