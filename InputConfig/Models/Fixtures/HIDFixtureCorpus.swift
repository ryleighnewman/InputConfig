import Foundation

/// Every fixture the bench runs, gathered from the per family files. A
/// family file is an `extension HIDFixtureCorpus` with a `static let` of
/// fixtures and one of sequences; add a family here and nowhere else.
enum HIDFixtureCorpus {
    static var all: [HIDFixture] {
        access + playStation + xbox + nintendo + valve + elgato + logitech + sim + macroPads + externalInput + output
    }

    static var sequences: [HIDSequenceFixture] {
        accessSequences + playStationSequences + xboxSequences + nintendoSequences + valveSequences + elgatoSequences
            + logitechSequences + simSequences + macroPadsSequences + externalInputSequences + outputSequences
    }
}
