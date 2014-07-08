/*/../usr/bin/true

source="$0"
compiled="$0"c

if [[ "$source" -nt "$compiled" ]]; then
DEVELOPER_DIR=/Applications/Xcode6-Beta.app/Contents/Developer xcrun swift -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.9.sdk -g "$source" -o "$compiled"  || exit
fi

"$compiled"

exit
*/


import Foundation
import Darwin


enum PrintColor {
    case Default
    case Red
    case Green
    case Yellow
    case Blue
    case Magenta
    case Cyan
}

protocol Printer {
    func print(color: PrintColor, _ str: String)
    func print(str: String)
    func println()
    func end()
}

class TermPrinter: Printer {
    let colorCodes: Dictionary<PrintColor, String> = [
        .Default: "39",
        .Red: "31",
        .Green: "32",
        .Yellow: "33",
        .Blue: "34",
        .Magenta: "35",
        .Cyan: "36"
    ]

    func printEscape(color: PrintColor) {
        Swift.print("\x1B[\(colorCodes[color])m")
    }
    
    func print(color: PrintColor, _ str: String) {
        printEscape(color)
        Swift.print(str)
        printEscape(.Default)
    }
    
    func print(str: String) {
        print(.Default, str)
    }
    
    func println() {
        Swift.println()
    }
    
    func end() {}
}

class HTMLPrinter: Printer {
    let colorNames: Dictionary<PrintColor, String> = [
        .Default: "black",
        .Red: "darkred",
        .Green: "green",
        .Yellow: "gold",
        .Blue: "darkblue",
        .Magenta: "darkmagenta",
        .Cyan: "darkcyan"
    ]
    
    var didEnd = false
    
    init() {
        Swift.println("<div style=\"font-family: monospace\">")
    }
    
    deinit {
        assert(didEnd, "Must end printer before destroying it")
    }
    
    func escape(str: String) -> String {
        let mutable = NSMutableString(string: str)
        func replace(str: String, with: String) {
            mutable.replaceOccurrencesOfString(str, withString: with, options: NSStringCompareOptions(0), range: NSRange(location: 0, length: mutable.length()))
        }
        
        replace("&", "&amp;")
        replace("<", "&lt;")
        replace(">", "&gt;")
        replace("  ", "&nbsp; ")
        
        return mutable
    }
    
    func print(color: PrintColor, _ str: String) {
        Swift.print("<span style=\"color: \(colorNames[color])\">")
        Swift.print(escape(str))
        Swift.print("</span>")
    }
    
    func print(str: String) {
        print(.Default, str)
    }
    
    func println() {
        Swift.println("<br>")
    }
    
    func end() {
        Swift.println("</div>")
        didEnd = true
    }
}

struct Pointer: Hashable, Printable {
    let address: UInt
    
    var hashValue: Int {
        return reinterpretCast(address)
    }
    
    var description: String {
        return NSString(format: "0x%0*llx", sizeof(address.dynamicType) * 2, address)
    }

    func symbolInfo() -> Dl_info? {
        var info = Dl_info(dli_fname: "", dli_fbase: nil, dli_sname: "", dli_saddr: nil)
        let ptr: UnsafePointer<Void> = reinterpretCast(address)
        let result = dladdr(ptr, &info)
        return (result == 0 ? nil : info)
    }
    
    func symbolName() -> String? {
        if let info = symbolInfo() {
            let symbolAddress: UInt = reinterpretCast(info.dli_saddr)
            if symbolAddress == address {
                return String.fromCString(info.dli_sname)
            }
        }
        return nil
    }
}

func ==(a: Pointer, b: Pointer) -> Bool {
    return a.address == b.address
}

struct Memory {
    let buffer: UInt8[]
    let isMalloc: Bool
    
    static func readIntoArray(ptr: Pointer, var _ buffer: UInt8[]) -> Bool {
        let result = buffer.withUnsafePointerToElements {
            (targetPtr: UnsafePointer<UInt8>) -> kern_return_t in
            
            let ptr64 = UInt64(ptr.address)
            let target: UInt = reinterpretCast(targetPtr)
            let target64 = UInt64(target)
            var outsize: mach_vm_size_t = 0
            return mach_vm_read_overwrite(mach_task_self_, ptr64, mach_vm_size_t(buffer.count), target64, &outsize)
        }
        return result == KERN_SUCCESS
    }
    
    static func read(ptr: Pointer, knownSize: Int? = nil) -> Memory? {
        let convertedPtr: UnsafePointer<Int> = reinterpretCast(ptr.address)
        var length = Int(malloc_size(convertedPtr))
        let isMalloc = length > 0
        if length == 0 {
            length = 64
        }
        
        if knownSize {
            length = knownSize!
        }
        
        var result = UInt8[](count: length, repeatedValue: 0)
        let success = readIntoArray(ptr, result)
        return (success
            ? Memory(buffer: result, isMalloc: isMalloc)
            : nil)
    }
    
    func scanPointers() -> PointerAndOffset[] {
        var pointers = PointerAndOffset[]()
        buffer.withUnsafePointerToElements {
            (memPtr: UnsafePointer<UInt8>) -> Void in
            
            let ptrptr: UnsafePointer<UInt> = reinterpretCast(memPtr)
            let count = self.buffer.count / 8
            for i in 0..<count {
                pointers.append(PointerAndOffset(pointer: Pointer(address: ptrptr[i]), offset: i * 8))
            }
        }
        return pointers
    }
    
    func scanStrings() -> String[] {
        let lowerBound: UInt8 = 32
        let upperBound: UInt8 = 126
        
        var current = UInt8[]()
        var strings = String[]()
        func reset() {
            if current.count >= 4 {
                let str = NSMutableString(capacity: current.count)
                for byte in current {
                    str.appendFormat("%c", byte)
                }
                strings.append(str)
            }
            current.removeAll()
        }
        for byte in buffer {
            if byte >= lowerBound && byte <= upperBound {
                current.append(byte)
            } else {
                reset()
            }
        }
        reset()
        
        return strings
    }
    
    func hex() -> String {
        return hexFromArray(buffer)
    }
}

func hexFromArray(mem: UInt8[]) -> String {
    let spacesInterval = 8
    let str = NSMutableString(capacity: mem.count * 2)
    for (index, byte) in enumerate(mem) {
        if index > 0 && (index % spacesInterval) == 0 {
            str.appendString(" ")
        }
        str.appendFormat("%02x", byte)
    }
    return str
}

struct PointerAndOffset {
    let pointer: Pointer
    let offset: Int
}

enum Alignment {
    case Right
    case Left
}

func pad(value: Any, minWidth: Int, padChar: String = " ", align: Alignment = .Right) -> String {
    var str = "\(value)"
    var accumulator = ""
    
    if align == .Left {
        accumulator += str
    }
    
    if minWidth > countElements(str) {
        for i in 0..<(minWidth - countElements(str)) {
            accumulator += padChar
        }
    }
    
    if align == .Right {
        accumulator += str
    }
    
    return accumulator
}

func limit(str: String, maxLength: Int, continuation: String = "...") -> String {
    if countElements(str) <= maxLength {
        return str
    }
    
    let start = str.startIndex
    let truncationPoint = advance(start, maxLength)
    return str[start..<truncationPoint] + continuation
}

class ScanEntry {
    let parent: ScanEntry?
    var parentOffset: Int
    let address: Pointer
    var index: Int
    
    init(parent: ScanEntry?, parentOffset: Int, address: Pointer, index: Int) {
        self.parent = parent
        self.parentOffset = parentOffset
        self.address = address
        self.index = index
    }
}

struct ObjCClass {
    static let classMap: Dictionary<Pointer, ObjCClass> = {
        var tmpMap = Dictionary<Pointer, ObjCClass>()
        for c in AllClasses() { tmpMap[c.address] = c }
        return tmpMap
    }()
    
    static func atAddress(address: Pointer) -> ObjCClass? {
        return classMap[address]
    }
    
    let address: Pointer
    let name: String
}

func AllClasses() -> ObjCClass[] {
    var count: CUnsignedInt = 0
    let classList = objc_copyClassList(&count)
    
    var result = ObjCClass[]()
    
    for i in 0..<count {
        let rawClass: AnyClass! = classList[Int(i)]
        let address: Pointer = Pointer(address: reinterpretCast(rawClass))
        let name = NSStringFromClass(rawClass)
        result.append(ObjCClass(address: address, name: name))
    }
    
    return result
}

class ScanResult {
    let entry: ScanEntry
    let parent: ScanResult?
    let memory: Memory
    var children = ScanResult[]()
    var indent = 0
    var color: PrintColor = .Default
    
    init(entry: ScanEntry, parent: ScanResult?, memory: Memory) {
        self.entry = entry
        self.parent = parent
        self.memory = memory
    }
    
    var name: String {
        if let c = ObjCClass.atAddress(entry.address) {
            return c.name
        }
        
        let pointers = memory.scanPointers()
        if pointers.count > 0 {
            if let c = ObjCClass.atAddress(pointers[0].pointer) {
                return "<\(c.name): \(entry.address.description)>"
            }
        }
        return entry.address.description
    }
    
    func dump(p: Printer) {
        if let parent = entry.parent {
            p.print("(")
            p.print(self.parent!.color, "\(pad(parent.index, 3)), \(pad(self.parent!.name, 24))@\(pad(entry.parentOffset, 3, align: .Left))")
            p.print(") <- ")
        } else {
            p.print("Starting pointer: ")
        }
        
        p.print(color, "\(pad(entry.index, 3)) \(entry.address.description): ")
        
        p.print(color, "\(pad(memory.buffer.count, 5)) bytes ")
        p.print(color, memory.isMalloc ? "<malloc> " : "<unknwn> ")
        
        p.print(color, limit(memory.hex(), 67))
        
        if let symbolName = entry.address.symbolName() {
            p.print(" Symbol \(symbolName)")
        }
        
        if let objCClass = ObjCClass.atAddress(entry.address) {
            p.print(" ObjC class \(objCClass.name)")
        }
        
        let strings = memory.scanStrings()
        if strings.count > 0 {
            p.print(" -- strings: (")
            p.print(", ".join(strings))
            p.print(")")
        }
        p.println()
    }
    
    func recursiveDump(p: Printer) {
        var entryColorIndex = 0
        let entryColors: PrintColor[] = [ .Red, .Green, .Yellow, .Blue, .Magenta, .Cyan ]
        func nextColor() -> PrintColor {
            return entryColors[entryColorIndex++ % entryColors.count]
        }
        
        var chain = [self]
        while chain.count > 0 {
            let result = chain.removeLast()
            
            if result.children.count > 0 {
                result.color = nextColor()
            }
            
            for i in 0..<result.indent {
                p.print("  ")
            }
            result.dump(p)
            for child in result.children {
                child.indent = result.indent + 1
                chain.append(child)
            }
        }
    }
}

func dumpmem<T>(var x: T, limit: Int) -> ScanResult {
    var count = 0
    var seen = Dictionary<Pointer, Bool>()
    var toScan = Array<ScanEntry>()
    
    var results = Dictionary<Pointer, ScanResult>()
    
    return withUnsafePointer(&x) {
        (ptr: UnsafePointer<T>) -> ScanResult in
        
        let firstAddr: Pointer = Pointer(address: reinterpretCast(ptr))
        let firstEntry = ScanEntry(parent: nil, parentOffset: 0, address: firstAddr, index: 0)
        seen[firstAddr] = true
        toScan.append(firstEntry)
        
        while toScan.count > 0 && count < limit {
            let entry = toScan.removeLast()
            entry.index = count
            
            let memory: Memory! = Memory.read(entry.address, knownSize: count == 0 ? sizeof(T.self) : nil)
            
            if memory {
                count++
                let parent = entry.parent.map{ results[$0.address] }?
                let result = ScanResult(entry: entry, parent: parent, memory: memory)
                parent?.children.append(result)
                results[entry.address] = result
                
                let pointersAndOffsets = memory.scanPointers()
                for pointerAndOffset in pointersAndOffsets {
                    let pointer = pointerAndOffset.pointer
                    let offset = pointerAndOffset.offset
                    if !seen[pointer] {
                        seen[pointer] = true
                        let newEntry = ScanEntry(parent: entry, parentOffset: offset, address: pointer, index: count)
                        toScan.insert(newEntry, atIndex: 0)
                    }
                }
            }
        }
        return results[firstAddr]!
    }
}


//dumpmem(42)
//let obj = NSObject()
//println(obj.description)
class TestClass {}
let obj = TestClass()
let result = dumpmem(obj, 150)
let printer = HTMLPrinter()
result.recursiveDump(printer)
printer.end()

