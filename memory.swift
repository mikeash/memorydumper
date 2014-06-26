#!/Applications/Xcode6-Beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift -i -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.9.sdk

import Foundation
import Darwin


struct Memory {
    let buffer: UInt8[]
    let isMalloc: Bool
    
    static func readIntoArray(ptr: UInt, var _ buffer: UInt8[]) -> Bool {
        let result = buffer.withUnsafePointerToElements {
            (targetPtr: UnsafePointer<UInt8>) -> kern_return_t in
            
            let ptr64 = UInt64(ptr)
            let target: UInt = reinterpretCast(targetPtr)
            let target64 = UInt64(target)
            var outsize: mach_vm_size_t = 0
            return mach_vm_read_overwrite(mach_task_self_, ptr64, mach_vm_size_t(buffer.count), target64, &outsize)
        }
        return result == KERN_SUCCESS
    }
    
    static func read(ptr: UInt) -> Memory? {
        let convertedPtr: UnsafePointer<Int> = reinterpretCast(ptr)
        var length = Int(malloc_size(convertedPtr))
        let isMalloc = length > 0
        if length == 0 {
            length = 64
        }
        
        var result = UInt8[](count: length, repeatedValue: 0)
        let success = readIntoArray(ptr, result)
        return (success
            ? Memory(buffer: result, isMalloc: isMalloc)
            : nil)
    }
}

func formatPointer(ptr: UInt) -> String {
    return NSString(format: "0x%016llx", ptr)
}


func hex(mem: UInt8[]) -> String {
    let str = NSMutableString(capacity: mem.count * 2)
    for byte in mem {
        str.appendFormat("%02x", byte)
    }
    return str
}

func printmem(mem: UInt8[]) {
    print(hex(mem))
}

struct PointerAndOffset {
    let pointer: UInt
    let offset: Int
}

func scanPointers(mem: UInt8[]) -> PointerAndOffset[] {
    var pointers = PointerAndOffset[]()
    mem.withUnsafePointerToElements {
        (memPtr: UnsafePointer<UInt8>) -> Void in
        
        let ptrptr: UnsafePointer<UInt> = reinterpretCast(memPtr)
        let count = mem.count / 8
        for i in 0..count {
            pointers.append(PointerAndOffset(pointer: ptrptr[i], offset: i * 8))
        }
    }
    return pointers
}

func scanStrings(mem: UInt8[]) -> String[] {
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
    for byte in mem {
        if byte >= lowerBound && byte <= upperBound {
            current.append(byte)
        } else {
            reset()
        }
    }
    reset()
    
    return strings
}

func printInt(x: Int, digits: Int, rightAlign: Bool = true) {
    let str = "\(x)"
    if !rightAlign {
        print(str)
    }
    
    if digits > countElements(str) {
        for i in 0..(digits - countElements(str)) {
            print(" ")
        }
    }
    
    if rightAlign {
        print(str)
    }
}

class ScanEntry {
    let parent: ScanEntry?
    var parentOffset: Int
    let address: UInt
    var index: Int
    
    init(parent: ScanEntry?, parentOffset: Int, address: UInt, index: Int) {
        self.parent = parent
        self.parentOffset = parentOffset
        self.address = address
        self.index = index
    }
}

struct ObjCClass {
    let address: UInt
    let name: String
}

func AllClasses() -> ObjCClass[] {
    var count: CUnsignedInt = 0
    let classList = objc_copyClassList(&count)
    
    var result = ObjCClass[]()
    
    for i in 0..count {
        let rawClass: AnyClass! = classList[Int(i)]
        let address: UInt = reinterpretCast(rawClass)
        let name = NSStringFromClass(rawClass)
        result.append(ObjCClass(address: address, name: name))
    }
    
    return result
}

var classMap = Dictionary<UInt, ObjCClass>()
for c in AllClasses() { classMap[c.address] = c }
//for (addr, objCClass) in classMap {
//    println("\(formatPointer(addr)) \(objCClass.name)")
//}

func dumpmem<T>(var x: T) {
    
    var count = 0
    var seen = Dictionary<UInt, Bool>()
    var toScan = Array<ScanEntry>()
    
    withUnsafePointer(&x) {
        (ptr: UnsafePointer<T>) -> Void in
        
        let firstAddr: UInt = reinterpretCast(ptr)
        let firstEntry = ScanEntry(parent: nil, parentOffset: 0, address: firstAddr, index: 0)
        seen[firstAddr] = true
        toScan.append(firstEntry)
        
        while toScan.count > 0 && count < 150 {
            let entry = toScan.removeLast()
            entry.index = count
            
            let memory: Memory! = Memory.read(entry.address)
            
            if memory {
                count++
                if let parent = entry.parent {
                    print("(")
                    printInt(parent.index, 3)
                    print(", \(formatPointer(parent.address))@")
                    printInt(entry.parentOffset, 3, rightAlign: false)
                    print(") <- ")
                } else {
                    print("                                 ")
                }
                
                printInt(entry.index, 3)
                print(" ")
                print(formatPointer(entry.address))
                print(": ")
                let pointersAndOffsets = scanPointers(memory.buffer)
                for pointerAndOffset in pointersAndOffsets {
                    let pointer = pointerAndOffset.pointer
                    let offset = pointerAndOffset.offset
                    if !seen[pointer] {
                        seen[pointer] = true
                        let newEntry = ScanEntry(parent: entry, parentOffset: offset, address: pointer, index: count)
                        toScan.insert(newEntry, atIndex: 0)
                    }
                }
                
                print("\(memory.buffer.count) bytes ")
                print(memory.isMalloc ? "<malloc> " : "<unknwn> ")
                
                printmem(memory.buffer)
//                if pointers.count > 0 {
//                    print(" ")
//                    print(pointers.map{ formatPointer($0) })
//                }
                
                if let objCClass = classMap[entry.address] {
                    print(" ObjC class \(objCClass.name)")
                }
                
                let strings = scanStrings(memory.buffer)
                if strings.count > 0 {
                    print(" -- strings: (")
                    print(", ".join(strings))
                    print(")")
                }
                println()
            }
        }
    }
    println("==========")
}


//dumpmem(42)
//let obj = NSObject()
//println(obj.description)
class TestClass {}
let obj = TestClass()
dumpmem(obj)

