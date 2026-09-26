import Foundation

/// Разбор файла cookies Safari (Cookies.binarycookies). Формат: "cook",
/// число страниц и их размеры (big-endian); в странице — число cookie и их
/// смещения (little-endian); в cookie — смещения строк домена, имени, пути,
/// значения и дата истечения (секунды от 2001-01-01). Любое смещение за
/// границами — ошибка, а не падение.
nonisolated enum BinaryCookies {

    struct Cookie: Equatable, Sendable {
        let domain: String
        let name: String
        let path: String
        let value: String
        let expires: Date
    }

    enum ParseError: Error {
        case notCookieFile
        case malformed
    }

    static func parse(_ data: Data) throws -> [Cookie] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4].elementsEqual("cook".utf8) else { throw ParseError.notCookieFile }
        let pageCount = Int(try beUInt32(bytes, at: 4))
        var cursor = 8
        var pageSizes: [Int] = []
        for _ in 0..<pageCount {
            pageSizes.append(Int(try beUInt32(bytes, at: cursor)))
            cursor += 4
        }
        var cookies: [Cookie] = []
        for size in pageSizes {
            guard size >= 0, cursor + size <= bytes.count else { throw ParseError.malformed }
            cookies += try parsePage(Array(bytes[cursor..<(cursor + size)]))
            cursor += size
        }
        return cookies
    }

    private static func parsePage(_ page: [UInt8]) throws -> [Cookie] {
        let count = Int(try leUInt32(page, at: 4))
        var cookies: [Cookie] = []
        for index in 0..<count {
            let offset = Int(try leUInt32(page, at: 8 + index * 4))
            let size = Int(try leUInt32(page, at: offset))
            guard size >= 56, offset + size <= page.count else { throw ParseError.malformed }
            cookies.append(try parseCookie(Array(page[offset..<(offset + size)])))
        }
        return cookies
    }

    private static func parseCookie(_ record: [UInt8]) throws -> Cookie {
        let domainOffset = Int(try leUInt32(record, at: 16))
        let nameOffset = Int(try leUInt32(record, at: 20))
        let pathOffset = Int(try leUInt32(record, at: 24))
        let valueOffset = Int(try leUInt32(record, at: 28))
        let expires = try leDouble(record, at: 40)
        return Cookie(
            domain: try cString(record, at: domainOffset),
            name: try cString(record, at: nameOffset),
            path: try cString(record, at: pathOffset),
            value: try cString(record, at: valueOffset),
            expires: Date(timeIntervalSinceReferenceDate: expires)
        )
    }

    private static func beUInt32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw ParseError.malformed }
        return bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func leUInt32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw ParseError.malformed }
        return bytes[offset..<(offset + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func leDouble(_ bytes: [UInt8], at offset: Int) throws -> Double {
        guard offset >= 0, offset + 8 <= bytes.count else { throw ParseError.malformed }
        let bits = bytes[offset..<(offset + 8)].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Double(bitPattern: bits)
    }

    private static func cString(_ bytes: [UInt8], at offset: Int) throws -> String {
        guard offset >= 0, offset < bytes.count,
              let end = bytes[offset...].firstIndex(of: 0)
        else { throw ParseError.malformed }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }
}
