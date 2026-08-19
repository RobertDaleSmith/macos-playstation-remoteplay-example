import Foundation

/// Minimal secp256k1 implementation: enough for ECDH (public key derivation and shared secret).
///
/// Apple's CryptoKit only ships the NIST curves and the Remote Play stream handshake is fixed to
/// secp256k1, so this is a small self-contained field/point implementation. It is not constant
/// time; the key it protects is a per-session LAN streaming key, not a long-lived secret.
enum RPSecp256k1 {
    /// p = 2^256 - 2^32 - 977
    private static let p = U256(limbs: [
        0xFFFF_FFFE_FFFF_FC2F, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF,
    ])
    /// 2^256 - p, used for reduction
    private static let pComplement: UInt64 = 0x1_0000_03D1
    /// Group order n
    private static let n = U256(limbs: [
        0xBFD2_5E8C_D036_4141, 0xBAAE_DCE6_AF48_A03B, 0xFFFF_FFFF_FFFF_FFFE, 0xFFFF_FFFF_FFFF_FFFF,
    ])
    private static let gx = U256(limbs: [
        0x59F2_815B_16F8_1798, 0x029B_FCDB_2DCE_28D9, 0x55A0_6295_CE87_0B07, 0x79BE_667E_F9DC_BBAC,
    ])
    private static let gy = U256(limbs: [
        0x9C47_D08F_FB10_D4B8, 0xFD17_B448_A685_5419, 0x5DA4_FBFC_0E11_08A8, 0x483A_DA77_26A3_C465,
    ])

    // MARK: - Public API

    static func randomPrivateKey() -> [UInt8] {
        while true {
            let bytes = RPBytes.random(32)
            let k = U256(bigEndian: bytes)
            if !k.isZero && k < n { return bytes }
        }
    }

    /// Uncompressed SEC1 encoding: 0x04 || X || Y.
    static func publicKey(privateKey: [UInt8]) -> [UInt8] {
        let k = U256(bigEndian: privateKey)
        let point = scalarMultiply(k, x: gx, y: gy)
        return [0x04] + point.x.bigEndian + point.y.bigEndian
    }

    /// ECDH shared secret: x-coordinate of priv * remote, 32 bytes big-endian.
    static func sharedSecret(privateKey: [UInt8], remotePublicKey: [UInt8]) -> [UInt8]? {
        guard remotePublicKey.count == 65, remotePublicKey[0] == 0x04 else { return nil }
        let rx = U256(bigEndian: Array(remotePublicKey[1..<33]))
        let ry = U256(bigEndian: Array(remotePublicKey[33..<65]))
        guard rx < p, ry < p, isOnCurve(x: rx, y: ry) else { return nil }
        let k = U256(bigEndian: privateKey)
        let point = scalarMultiply(k, x: rx, y: ry)
        guard !point.infinity else { return nil }
        return point.x.bigEndian
    }

    static func isOnCurve(x: U256, y: U256) -> Bool {
        // y^2 == x^3 + 7
        let lhs = fmul(y, y)
        let rhs = fadd(fmul(fmul(x, x), x), U256(small: 7))
        return lhs == rhs
    }

    // MARK: - Field arithmetic mod p

    static func fadd(_ a: U256, _ b: U256) -> U256 {
        let (sum, carry) = a.addingReportingOverflow(b)
        if carry || sum >= p {
            return sum.subtracting(p)
        }
        return sum
    }

    static func fsub(_ a: U256, _ b: U256) -> U256 {
        if a >= b { return a.subtracting(b) }
        return a.subtracting(b).adding(p)
    }

    static func fmul(_ a: U256, _ b: U256) -> U256 {
        reduce(a.multipliedFullWidth(b))
    }

    /// Reduce a 512-bit product modulo p using p = 2^256 - c.
    private static func reduce(_ wide: [UInt64]) -> U256 {
        // wide: 8 limbs little-endian. value = H * 2^256 + L ≡ L + H * c
        var low = Array(wide[0..<4])
        var high = Array(wide[4..<8])
        // First fold: low + high * c  → up to 5 limbs (+ carry)
        var acc = mulSmall(high, pComplement)  // 5 limbs
        acc = addLimbs(acc, low + [0])  // 5 limbs + possible carry into 6th
        // Second fold: acc = H2 * 2^256 + L2 with H2 in acc[4..]
        low = Array(acc[0..<4])
        high = [acc.count > 4 ? acc[4] : 0, acc.count > 5 ? acc[5] : 0, 0, 0]
        acc = addLimbs(mulSmall(high, pComplement), low + [0])
        var result = U256(limbs: Array(acc[0..<4]))
        // acc[4] can be at most 1 here; fold once more by adding c.
        if acc.count > 4 && acc[4] != 0 {
            let (sum, carry) = result.addingReportingOverflow(U256(small: pComplement))
            result = sum
            if carry { result = result.adding(U256(small: pComplement)) }
        }
        while result >= p { result = result.subtracting(p) }
        return result
    }

    /// (4-limb) * small → 5 limbs
    private static func mulSmall(_ a: [UInt64], _ c: UInt64) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: 5)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (hi, lo) = a[i].multipliedFullWidth(by: c)
            let (sum, c1) = lo.addingReportingOverflow(carry)
            out[i] = sum
            carry = hi &+ (c1 ? 1 : 0)
        }
        out[4] = carry
        return out
    }

    private static func addLimbs(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let count = max(a.count, b.count)
        var out = [UInt64](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            let (s1, c1) = x.addingReportingOverflow(y)
            let (s2, c2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (c1 ? 1 : 0) + (c2 ? 1 : 0)
        }
        out[count] = carry
        return out
    }

    static func finv(_ a: U256) -> U256 {
        // Fermat: a^(p-2)
        fpow(a, p.subtracting(U256(small: 2)))
    }

    static func fpow(_ base: U256, _ exp: U256) -> U256 {
        var result = U256(small: 1)
        var b = base
        for i in 0..<256 {
            if exp.bit(i) { result = fmul(result, b) }
            b = fmul(b, b)
        }
        return result
    }

    // MARK: - Point arithmetic (Jacobian)

    struct Jacobian {
        var x: U256
        var y: U256
        var z: U256
        var infinity: Bool { z.isZero }
        static let infinity = Jacobian(x: U256(small: 1), y: U256(small: 1), z: U256(small: 0))
    }

    struct Affine {
        let x: U256
        let y: U256
        let infinity: Bool
    }

    static func toAffine(_ j: Jacobian) -> Affine {
        if j.infinity { return Affine(x: U256(small: 0), y: U256(small: 0), infinity: true) }
        let zInv = finv(j.z)
        let zInv2 = fmul(zInv, zInv)
        let zInv3 = fmul(zInv2, zInv)
        return Affine(x: fmul(j.x, zInv2), y: fmul(j.y, zInv3), infinity: false)
    }

    static func double(_ pnt: Jacobian) -> Jacobian {
        if pnt.infinity || pnt.y.isZero { return .infinity }
        // a = 0 curve: standard dbl-2009-l
        let a = fmul(pnt.x, pnt.x)
        let b = fmul(pnt.y, pnt.y)
        let c = fmul(b, b)
        let xb = fadd(pnt.x, b)
        var d = fsub(fmul(xb, xb), fadd(a, c))
        d = fadd(d, d)
        let e = fadd(fadd(a, a), a)
        let f = fmul(e, e)
        let x3 = fsub(f, fadd(d, d))
        var c8 = fadd(c, c)
        c8 = fadd(c8, c8)
        c8 = fadd(c8, c8)
        let y3 = fsub(fmul(e, fsub(d, x3)), c8)
        let z3 = fadd(fmul(pnt.y, pnt.z), fmul(pnt.y, pnt.z))
        return Jacobian(x: x3, y: y3, z: z3)
    }

    /// Add a Jacobian point and an affine point (madd-2007-bl).
    static func addMixed(_ pnt: Jacobian, ax: U256, ay: U256) -> Jacobian {
        if pnt.infinity { return Jacobian(x: ax, y: ay, z: U256(small: 1)) }
        let z1z1 = fmul(pnt.z, pnt.z)
        let u2 = fmul(ax, z1z1)
        let s2 = fmul(ay, fmul(pnt.z, z1z1))
        let h = fsub(u2, pnt.x)
        let r = fsub(s2, pnt.y)
        if h.isZero {
            if r.isZero { return double(pnt) }
            return .infinity
        }
        let hh = fmul(h, h)
        let hhh = fmul(hh, h)
        let v = fmul(pnt.x, hh)
        let x3 = fsub(fsub(fsub(fmul(r, r), hhh), v), v)
        let y3 = fsub(fmul(r, fsub(v, x3)), fmul(pnt.y, hhh))
        let z3 = fmul(pnt.z, h)
        return Jacobian(x: x3, y: y3, z: z3)
    }

    static func scalarMultiply(_ k: U256, x: U256, y: U256) -> Affine {
        var result = Jacobian.infinity
        var i = 255
        while i >= 0 {
            result = double(result)
            if k.bit(i) { result = addMixed(result, ax: x, ay: y) }
            i -= 1
        }
        return toAffine(result)
    }
}

/// Unsigned 256-bit integer, four little-endian 64-bit limbs.
struct U256: Equatable {
    var limbs: [UInt64]  // limbs[0] is least significant

    init(limbs: [UInt64]) {
        precondition(limbs.count == 4)
        self.limbs = limbs
    }

    init(small: UInt64) {
        limbs = [small, 0, 0, 0]
    }

    init(bigEndian bytes: [UInt8]) {
        precondition(bytes.count == 32)
        var l = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var v: UInt64 = 0
            for j in 0..<8 {
                v = (v << 8) | UInt64(bytes[(3 - i) * 8 + j])
            }
            l[i] = v
        }
        limbs = l
    }

    var bigEndian: [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<4 {
            let v = limbs[3 - i]
            for j in 0..<8 {
                out[i * 8 + j] = UInt8((v >> (56 - 8 * UInt64(j))) & 0xFF)
            }
        }
        return out
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    func bit(_ index: Int) -> Bool {
        (limbs[index / 64] >> UInt64(index % 64)) & 1 == 1
    }

    static func < (lhs: U256, rhs: U256) -> Bool {
        for i in (0..<4).reversed() {
            if lhs.limbs[i] != rhs.limbs[i] { return lhs.limbs[i] < rhs.limbs[i] }
        }
        return false
    }

    static func >= (lhs: U256, rhs: U256) -> Bool { !(lhs < rhs) }

    func addingReportingOverflow(_ other: U256) -> (U256, Bool) {
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, c1) = limbs[i].addingReportingOverflow(other.limbs[i])
            let (s2, c2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (c1 ? 1 : 0) + (c2 ? 1 : 0)
        }
        return (U256(limbs: out), carry != 0)
    }

    func adding(_ other: U256) -> U256 { addingReportingOverflow(other).0 }

    /// Wrapping subtraction (mod 2^256).
    func subtracting(_ other: U256) -> U256 {
        var out = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, b1) = limbs[i].subtractingReportingOverflow(other.limbs[i])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
        }
        return U256(limbs: out)
    }

    /// Full 512-bit product, 8 little-endian limbs.
    func multipliedFullWidth(_ other: U256) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (hi, lo) = limbs[i].multipliedFullWidth(by: other.limbs[j])
                let (s1, c1) = out[i + j].addingReportingOverflow(lo)
                let (s2, c2) = s1.addingReportingOverflow(carry)
                out[i + j] = s2
                carry = hi &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            out[i + 4] = carry
        }
        return out
    }
}
