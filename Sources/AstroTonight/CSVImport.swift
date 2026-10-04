import Foundation

/// Minimal CSV import for user-defined targets.
///
/// Expected headers (case-insensitive): `name`, `ra`, `dec`, `type`,
/// `mag`, `size_arcmin`. RA/Dec are DECIMAL DEGREES (J2000 mean place,
/// like the vendored catalogue). `type` maps onto the catalogue's type
/// strings (`galaxy`, `nebula`, `planetary_nebula`, `supernova_remnant`,
/// `open_cluster`, `globular_cluster`, `star`); anything else becomes
/// `"other"`. `mag` and `size_arcmin` are optional.
///
/// Documented limits (not bugs): single-line fields only — a newline
/// inside quotes is not supported. Quoted fields may contain commas and
/// doubled quotes (`""`). Rows with a missing/blank name, unparsable or
/// out-of-range coordinates are skipped and counted.
enum CSVImport {
    struct Result {
        let imported: [CatalogObject]
        let skipped: Int
    }

    static func parse(_ text: String) -> Result {
        let rows = parseRows(text)
        guard let header = rows.first else {
            return Result(imported: [], skipped: 0)
        }
        // First occurrence wins — duplicate headers are malformed
        // input, not a crash.
        var cols = [String: Int]()
        for (idx, name) in header.enumerated() {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if cols[key] == nil { cols[key] = idx }
        }
        guard let ni = cols["name"], let ri = cols["ra"],
              let di = cols["dec"]
        else {
            // No usable header — every data row is unparseable.
            return Result(imported: [], skipped: max(0, rows.count - 1))
        }
        let ti = cols["type"]
        let mi = cols["mag"]
        let si = cols["size_arcmin"]

        var imported = [CatalogObject]()
        var skipped = 0
        for row in rows.dropFirst() {
            let needed = max(ni, max(ri, di))
            guard row.count > needed,
                  let ra = Double(row[ri]
                    .trimmingCharacters(in: .whitespaces)),
                  let dec = Double(row[di]
                    .trimmingCharacters(in: .whitespaces)),
                  ra >= 0, ra < 360, dec >= -90, dec <= 90
            else { skipped += 1; continue }
            let name = row[ni]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { skipped += 1; continue }
            let rawType = ti.flatMap { row.count > $0 ? row[$0] : nil }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let mag = mi.flatMap { row.count > $0
                ? Double(row[$0].trimmingCharacters(in: .whitespaces))
                : nil }
            let size = si.flatMap { row.count > $0
                ? Double(row[$0].trimmingCharacters(in: .whitespaces))
                : nil }
            imported.append(CatalogObject(
                ids: ["custom-\(UUID().uuidString)"],
                name: name, ra: ra, dec: dec,
                type: knownType(rawType),
                mag: mag, sizeArcmin: size,
                constellation: nil,
                isCustom: true))
        }
        return Result(imported: imported, skipped: skipped)
    }

    private static func knownType(_ s: String) -> String {
        switch s {
        case "galaxy", "nebula", "planetary_nebula", "supernova_remnant",
             "open_cluster", "globular_cluster", "star", "other":
            return s
        default:
            return "other"
        }
    }

    /// Split text into rows of fields. Handles quoted fields containing
    /// commas and doubled quotes; `\r\n` line endings are normalised.
    private static func parseRows(_ text: String) -> [[String]] {
        var rows = [[String]]()
        var fields = [String]()
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        func flushField() { fields.append(field); field = "" }
        func flushRow() {
            flushField()
            rows.append(fields)
            fields = []
        }
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.append(ch)
                    i += 1
                }
            } else if ch == "\"" {
                inQuotes = true
                i += 1
            } else if ch == "," {
                flushField()
                i += 1
            } else if ch == "\n" {
                flushRow()
                i += 1
            } else if ch == "\r" {
                // Swallowed; the following \n (if any) ends the row.
                i += 1
            } else {
                field.append(ch)
                i += 1
            }
        }
        // Trailing content without a final newline.
        if !field.isEmpty || !fields.isEmpty { flushRow() }
        // Drop rows that are entirely blank.
        return rows.filter { row in
            !row.allSatisfy {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }
}
