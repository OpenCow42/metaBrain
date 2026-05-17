@testable import MetaBrainCore
import Testing

@Test func unifiedTextPatchAppliesReplacementInsertionAndDeletion() throws {
    let patch = """
    --- a/notes
    +++ b/notes
    @@ -1,3 +1,4 @@
     alpha
    -beta
    +delta
     gamma
    +omega
    """

    let patched = try UnifiedTextPatch(patch).applying(to: "alpha\nbeta\ngamma\n")

    #expect(patched == "alpha\ndelta\ngamma\nomega\n")
}

@Test func unifiedTextPatchAppliesMultipleOrderedHunks() throws {
    let patch = """
    @@ -1,2 +1,2 @@
    -one
    +ONE
     two
    @@ -4,2 +4,2 @@
     four
    -five
    +FIVE
    """

    let patched = try UnifiedTextPatch(patch).applying(to: "one\ntwo\nthree\nfour\nfive\n")

    #expect(patched == "ONE\ntwo\nthree\nfour\nFIVE\n")
}

@Test func unifiedTextPatchCanInsertIntoEmptyBody() throws {
    let patch = """
    @@ -0,0 +1,2 @@
    +alpha
    +beta
    """

    let patched = try UnifiedTextPatch(patch).applying(to: "")

    #expect(patched == "alpha\nbeta\n")
}

@Test func unifiedTextPatchPreservesMissingFinalNewlineMarkers() throws {
    let patch = """
    @@ -1,2 +1,2 @@
     alpha
    -beta
    \\ No newline at end of file
    +delta
    \\ No newline at end of file
    """

    let patched = try UnifiedTextPatch(patch).applying(to: "alpha\nbeta")

    #expect(patched == "alpha\ndelta")
}

@Test func unifiedTextPatchRejectsContextMismatch() throws {
    let patch = """
    @@ -1,2 +1,2 @@
     alpha
    -beta
    +delta
    """

    #expect(throws: MetaBrainPatchError.contextMismatch(line: 3, expected: "beta", actual: "wrong")) {
        try UnifiedTextPatch(patch).applying(to: "alpha\nwrong\n")
    }
}

@Test func unifiedTextPatchRejectsMissingContextAtEndOfBody() throws {
    let patch = """
    @@ -1 +1 @@
    -alpha
    +beta
    """

    #expect(throws: MetaBrainPatchError.contextMismatch(line: 2, expected: "alpha", actual: nil)) {
        try UnifiedTextPatch(patch).applying(to: "")
    }
}

@Test func unifiedTextPatchRejectsMultiFileDiffsAndUnsupportedPatches() throws {
    let multiFilePatch = """
    diff --git a/one b/one
    --- a/one
    +++ b/one
    @@ -1 +1 @@
    -one
    +ONE
    diff --git a/two b/two
    --- a/two
    +++ b/two
    @@ -1 +1 @@
    -two
    +TWO
    """
    let binaryPatch = """
    GIT binary patch
    literal 0
    """

    #expect(throws: MetaBrainPatchError.multipleFilesUnsupported) {
        try UnifiedTextPatch(multiFilePatch).applying(to: "one\n")
    }
    #expect(throws: MetaBrainPatchError.unsupportedPatch("binary patches are not supported")) {
        try UnifiedTextPatch(binaryPatch).applying(to: "")
    }
}

@Test func unifiedTextPatchRejectsMalformedFileHeaders() throws {
    let missingPlusHeader = """
    --- a/one
    @@ -1 +1 @@
    -one
    +ONE
    """
    let repeatedFileHeader = """
    --- a/one
    +++ b/one
    --- a/two
    +++ b/two
    @@ -1 +1 @@
    -one
    +ONE
    """

    #expect(throws: MetaBrainPatchError.malformedFileHeader(line: 1)) {
        try UnifiedTextPatch(missingPlusHeader).applying(to: "one\n")
    }
    #expect(throws: MetaBrainPatchError.multipleFilesUnsupported) {
        try UnifiedTextPatch(repeatedFileHeader).applying(to: "one\n")
    }
}

@Test func unifiedTextPatchRejectsMalformedHunkHeaders() throws {
    let missingClosingHeader = """
    @@ -1 +1
    -one
    +ONE
    """
    let missingOldPrefix = """
    @@ 1 +1 @@
    -one
    +ONE
    """
    let invalidStart = """
    @@ -x +1 @@
    -one
    +ONE
    """
    let invalidCount = """
    @@ -1,x +1 @@
    -one
    +ONE
    """

    #expect(throws: MetaBrainPatchError.malformedHunkHeader(line: 1, text: "@@ -1 +1")) {
        try UnifiedTextPatch(missingClosingHeader).applying(to: "one\n")
    }
    #expect(throws: MetaBrainPatchError.malformedHunkHeader(line: 1, text: "@@ 1 +1 @@")) {
        try UnifiedTextPatch(missingOldPrefix).applying(to: "one\n")
    }
    #expect(throws: MetaBrainPatchError.malformedHunkHeader(line: 1, text: "@@ -x +1 @@")) {
        try UnifiedTextPatch(invalidStart).applying(to: "one\n")
    }
    #expect(throws: MetaBrainPatchError.malformedHunkHeader(line: 1, text: "@@ -1,x +1 @@")) {
        try UnifiedTextPatch(invalidCount).applying(to: "one\n")
    }
}

@Test func unifiedTextPatchRejectsMalformedHunkBodies() throws {
    let emptyBodyLine = """
    @@ -1,2 +1,2 @@

     two
    """
    let unknownBodyLine = """
    @@ -1 +1 @@
    !one
    """
    let extraBodyLine = """
    @@ -1 +1 @@
    -one
    +ONE
    +extra
    """
    let missingBodyLines = """
    @@ -1,2 +1,2 @@
     one
    """
    let looseLineAfterFooter = """
    @@ -1 +1 @@
    -one
    +ONE
    footer
    +loose
    """

    #expect(throws: MetaBrainPatchError.malformedHunkBody(line: 2, text: "")) {
        try UnifiedTextPatch(emptyBodyLine).applying(to: "one\ntwo\n")
    }
    #expect(throws: MetaBrainPatchError.malformedHunkBody(line: 2, text: "!one")) {
        try UnifiedTextPatch(unknownBodyLine).applying(to: "one\n")
    }
    #expect(throws: MetaBrainPatchError.hunkLineCountMismatch(line: 1)) {
        try UnifiedTextPatch(extraBodyLine).applying(to: "one\n")
    }
    #expect(throws: MetaBrainPatchError.hunkLineCountMismatch(line: 1)) {
        try UnifiedTextPatch(missingBodyLines).applying(to: "one\ntwo\n")
    }
    #expect(throws: MetaBrainPatchError.malformedHunkBody(line: 5, text: "+loose")) {
        try UnifiedTextPatch(looseLineAfterFooter).applying(to: "one\n")
    }
}

@Test func unifiedTextPatchHandlesBlankFooterAndContextWithoutFinalNewline() throws {
    let blankFooterPatch = """
    @@ -1 +1 @@
    -alpha
    +beta

    footer
    """
    let contextNoNewlinePatch = """
    @@ -1 +1 @@
     alpha
    \\ No newline at end of file
    """

    #expect(try UnifiedTextPatch(blankFooterPatch).applying(to: "alpha\n") == "beta\n")
    #expect(try UnifiedTextPatch(contextNoNewlinePatch).applying(to: "alpha") == "alpha")
}

@Test func unifiedTextPatchRejectsOutOfOrderAndOutOfRangeHunks() throws {
    let outOfOrderPatch = """
    @@ -2 +2 @@
    -beta
    +BETA
    @@ -1 +1 @@
    -alpha
    +ALPHA
    """
    let outOfRangePatch = """
    @@ -3 +3 @@
    -gamma
    +GAMMA
    """

    #expect(throws: MetaBrainPatchError.hunkOutOfOrder(line: 4)) {
        try UnifiedTextPatch(outOfOrderPatch).applying(to: "alpha\nbeta\n")
    }
    #expect(throws: MetaBrainPatchError.hunkOutOfRange(line: 1)) {
        try UnifiedTextPatch(outOfRangePatch).applying(to: "alpha\n")
    }
}

@Test func unifiedTextPatchRejectsRenameMetadata() throws {
    let patch = """
    rename from old
    rename to new
    """

    #expect(throws: MetaBrainPatchError.unsupportedPatch("rename from")) {
        try UnifiedTextPatch(patch).applying(to: "")
    }
}

@Test func patchErrorDescriptionsCoverAllCases() {
    let errors: [MetaBrainPatchError] = [
        .documentNotFound,
        .noHunks,
        .multipleFilesUnsupported,
        .unsupportedPatch("binary patches are not supported"),
        .malformedFileHeader(line: 1),
        .malformedHunkHeader(line: 2, text: "@@ bad"),
        .malformedHunkBody(line: 3, text: "!bad"),
        .hunkLineCountMismatch(line: 4),
        .hunkOutOfOrder(line: 5),
        .hunkOutOfRange(line: 6),
        .contextMismatch(line: 7, expected: "old", actual: "new"),
        .contextMismatch(line: 8, expected: "old", actual: nil)
    ]

    for error in errors {
        #expect(!error.description.isEmpty)
        #expect(error.errorDescription == error.description)
    }
}
