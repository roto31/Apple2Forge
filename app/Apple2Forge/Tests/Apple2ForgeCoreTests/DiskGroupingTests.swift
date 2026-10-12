import Apple2ForgeCore
import Foundation
import Testing

struct DiskGroupingTests {
    @Test func decodeGroupedJSON() throws {
        let json = """
        [{"title": "Quest", "paths": ["/a.dsk", "/b.dsk"], "sideCount": 2}]
        """
        let groups = try JSONDecoder().decode([DiskBuildGroup].self, from: Data(json.utf8))
        #expect(groups.count == 1)
        #expect(groups[0].title == "Quest")
        #expect(groups[0].sideCount == 2)
    }

    @Test func fallbackOnePerDisk() {
        let urls = [URL(filePath: "/tmp/A.dsk"), URL(filePath: "/tmp/B.dsk")]
        let groups = DiskGrouping.fallbackSingleGroups(urls)
        #expect(groups.count == 2)
        #expect(groups[0].sideCount == 1)
    }
}
