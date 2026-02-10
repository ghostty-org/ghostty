import Testing
@testable import Ghostree

struct DiffParserTests {
    @Test func parsesModifiedFileWithHunks() async throws {
        let diff = """
diff --git a/foo.swift b/foo.swift
index 1111111..2222222 100644
--- a/foo.swift
+++ b/foo.swift
@@ -1,3 +1,4 @@
 line1
-line2
+line2 changed
 line3
+line4
@@ -10,1 +11,2 @@
 context
+new line

"""

        let doc = DiffParser.parseUnified(text: diff, source: .workingTree(scope: .all))
        #expect(doc.files.count == 1)

	        let file = doc.files[0]
	        #expect(file.primaryPath == "foo.swift")
	        #expect(file.status == .modified)
	        #expect(file.hunks.count == 2)
	        #expect(file.additions == 3)
	        #expect(file.deletions == 1)

        let firstHunk = file.hunks[0]
        #expect(firstHunk.oldStart == 1)
        #expect(firstHunk.newStart == 1)
    }

    @Test func parsesRenameMetadata() async throws {
        let diff = """
diff --git a/old.txt b/new.txt
similarity index 100%
rename from old.txt
rename to new.txt

"""

        let doc = DiffParser.parseUnified(text: diff, source: .workingTree(scope: .all))
        #expect(doc.files.count == 1)
        let file = doc.files[0]
        #expect(file.status == .renamed)
        #expect(file.pathOld == "old.txt")
        #expect(file.pathNew == "new.txt")
        #expect(file.additions == 0)
        #expect(file.deletions == 0)
    }

    @Test func parsesAddedFileWithLineNumbers() async throws {
        let diff = """
diff --git a/new.md b/new.md
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/new.md
@@ -0,0 +1,2 @@
+hello
+world

"""

        let doc = DiffParser.parseUnified(text: diff, source: .workingTree(scope: .all))
        #expect(doc.files.count == 1)
        let file = doc.files[0]
        #expect(file.status == .added)
        #expect(file.additions == 2)
        #expect(file.deletions == 0)
        #expect(file.hunks.count == 1)

        let lines = file.hunks[0].lines
        #expect(lines.count == 2)
        #expect(lines[0].newLine == 1)
        #expect(lines[1].newLine == 2)
        #expect(lines[0].oldLine == nil)
    }

    @Test func parsesBinaryDiffAsFallback() async throws {
        let diff = """
diff --git a/image.png b/image.png
new file mode 100644
index 0000000..e69de29
Binary files /dev/null and b/image.png differ

"""

        let doc = DiffParser.parseUnified(text: diff, source: .workingTree(scope: .all))
        #expect(doc.files.count == 1)
        let file = doc.files[0]
        #expect(file.isBinary == true)
        #expect(file.hunks.isEmpty)
        #expect(file.fallbackText != nil)
    }

    @Test func parsesCombinedDiffAsUnsupportedFallback() async throws {
        let diff = """
diff --cc conflict.txt
index 1111111,2222222..0000000
--- a/conflict.txt
+++ b/conflict.txt

"""

        let doc = DiffParser.parseUnified(text: diff, source: .workingTree(scope: .all))
        #expect(doc.files.count == 1)
        let file = doc.files[0]
        #expect(file.isCombinedUnsupported == true)
        #expect(file.hunks.isEmpty)
        #expect(file.fallbackText != nil)
    }

    @Test func capsHugeDiffsPerFile() async throws {
        var lines: [String] = []
        lines.reserveCapacity(10_100)
        lines.append("diff --git a/big.txt b/big.txt")
        lines.append("index 1111111..2222222 100644")
        lines.append("--- a/big.txt")
        lines.append("+++ b/big.txt")
        lines.append("@@ -0,0 +1,10001 @@")
        for i in 0..<10001 {
            lines.append("+line \(i)")
        }
        lines.append("")

        let diff = lines.joined(separator: "\n")
        let doc = DiffParser.parseUnified(text: diff, source: .workingTree(scope: .all))
        #expect(doc.files.count == 1)
        let file = doc.files[0]
        #expect(file.isTooLargeToRender == true)
        #expect(file.hunks.isEmpty)
        #expect(file.fallbackText?.contains("Diff too large") == true)
        #expect(file.additions == 10001)
    }
}
