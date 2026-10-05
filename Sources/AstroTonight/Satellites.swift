import Foundation
import Combine

// MARK: - Satellite passes (SGP4)
//
// A faithful Swift port of the standard Vallado SGP4/SDP4 propagator
// (the same algorithm as python-sgp4's pure-Python model, which mirrors
// Vallado's C++ sgp4unit.cpp). Double throughout, WGS-72 gravity
// constants (the standard for CelesTrak TLEs), improved ('i') ops mode.
//
// Port notes:
// - Python's floored `%` on doubles is reproduced by `fmodPos(_:_:)`.
//   The one place the reference uses truncating semantics
//   (`nodep` in dpper / `nodem` in sgp4) uses
//   `truncatingRemainder(dividingBy:)` to match exactly.
// - On propagation error the throwing-free core returns nil; the public
//   `SGP4.propagate(tle:at:)` maps that to a NaN state (documented).
// - Units: position km, velocity km/s, output frame TEME
//   (True Equator, Mean Equinox of date).

// MARK: - TLE

/// A parsed two-line element set plus its name line.
struct TLE {
    let name: String
    let line1: String
    let line2: String
    /// Full Julian date of the element epoch (display / age only).
    /// Propagation must use `jdsatepoch`/`jdsatepochF`: the reference
    /// keeps the epoch split so the fraction retains full precision
    /// instead of being rounded by the ~2.4e6 magnitude.
    let epochJulianDate: Double
    /// Split epoch, exactly as the reference stores it: whole days from
    /// the calendar formula, fraction rounded to the 8 decimals a TLE
    /// carries. `tsince` must be computed as
    /// `((jdWhole - jdsatepoch) + (jdFrac - jdsatepochF)) * 1440`.
    let jdsatepoch: Double
    let jdsatepochF: Double

    // Orbital elements in SGP4 working units (radians, rad/min).
    let bstar: Double
    let ndot: Double
    let nddot: Double
    let ecco: Double
    let argpo: Double
    let inclo: Double
    let mo: Double
    let noKozai: Double
    let nodeo: Double

    /// Failable initializer: returns nil when either line fails the
    /// strict TLE column checks (same positions python-sgp4 checks).
    init?(name: String, line1: String, line2: String) {
        let l1 = Array(line1.trimmingCharacters(in: .whitespacesAndNewlines))
        let l2 = Array(line2.trimmingCharacters(in: .whitespacesAndNewlines))
        guard l1.count >= 69, l2.count >= 69,
              l1[0] == "1", l1[1] == " ",
              l1[8] == " ", l1[23] == ".", l1[32] == " ",
              l1[34] == ".", l1[43] == " ", l1[52] == " ",
              l1[61] == " ", l1[63] == " ",
              l2[0] == "2", l2[1] == " ",
              l2[7] == " ", l2[11] == ".", l2[16] == " ",
              l2[20] == ".", l2[25] == " ", l2[33] == " ",
              l2[37] == ".", l2[42] == " ", l2[46] == ".",
              l2[51] == " ",
              String(l1[2..<7]) == String(l2[2..<7])
        else { return nil }

        func field(_ c: [Character], _ r: Range<Int>) -> String {
            String(c[r]).trimmingCharacters(in: .whitespaces)
        }
        /// Implied-decimal field with a separate sign character, e.g.
        /// line1 columns 44-51 (nddot) or 53-60 (bstar).
        func expField(_ c: [Character], signAt: Int,
                      digits: Range<Int>, exp: Range<Int>) -> Double? {
            let sign: String = c[signAt] == "-" ? "-" : ""
            guard let mantissa = Double(sign + "." + String(c[digits])),
                  let e = Int(field(c, exp))
            else { return nil }
            return mantissa * pow(10.0, Double(e))
        }

        let deg2rad = Double.pi / 180.0
        let xpdotp = 1440.0 / (2.0 * Double.pi)

        guard let twoDigitYear = Int(field(l1, 18..<20)),
              let epochDays = Double(field(l1, 20..<32)),
              let ndotRaw = Double(field(l1, 33..<43)),
              let nddot = expField(l1, signAt: 44, digits: 45..<50, exp: 50..<52),
              let bstar = expField(l1, signAt: 53, digits: 54..<59, exp: 59..<61),
              let inclo = Double(field(l2, 8..<16)),
              let nodeo = Double(field(l2, 17..<25)),
              let argpo = Double(field(l2, 34..<42)),
              let mo = Double(field(l2, 43..<51)),
              let noKozaiRevDay = Double(field(l2, 52..<63))
        else { return nil }
        let ecco = Double("0." + String(l2[26..<33])
            .replacingOccurrences(of: " ", with: "0")) ?? -1.0
        guard ecco >= 0.0 else { return nil }

        let year = twoDigitYear < 57 ? twoDigitYear + 2000 : twoDigitYear + 1900
        // Split epoch JD exactly the way the reference does: integer part
        // from the calendar formula, fraction rounded to the 8 decimals a
        // TLE carries.
        let dayInt = floor(epochDays)
        let frac = epochDays - dayInt
        let jdEpoch = Double(year * 365 + (year - 1) / 4) + dayInt + 1721044.5
        let jdEpochF = (frac * 1e8).rounded() / 1e8

        self.name = name.trimmingCharacters(in: .whitespaces)
        self.line1 = line1
        self.line2 = line2
        self.epochJulianDate = jdEpoch + jdEpochF
        self.jdsatepoch = jdEpoch
        self.jdsatepochF = jdEpochF
        self.bstar = bstar
        self.ndot = ndotRaw / (xpdotp * 1440.0)
        self.nddot = nddot / (xpdotp * 1440.0 * 1440.0)
        self.ecco = ecco
        self.argpo = argpo * deg2rad
        self.inclo = inclo * deg2rad
        self.mo = mo * deg2rad
        self.noKozai = noKozaiRevDay / xpdotp
        self.nodeo = nodeo * deg2rad
    }

    /// Epoch as a `Date` (for TLE-age display).
    var epochDate: Date {
        Date(timeIntervalSince1970: (epochJulianDate - 2440587.5) * 86400.0)
    }
}

// MARK: - State

/// ECI-ish satellite state from SGP4. Position in km, velocity in km/s,
/// both in the TEME frame. A failed propagation is represented by NaN
/// components (see `SGP4.propagate(tle:at:)`).
struct SatelliteState {
    var position: SIMD3<Double>
    var velocity: SIMD3<Double>

    var isValid: Bool {
        position.x.isFinite && velocity.x.isFinite
    }

    static let invalid = SatelliteState(
        position: SIMD3<Double>(.nan, .nan, .nan),
        velocity: SIMD3<Double>(.nan, .nan, .nan))
}

// MARK: - SGP4 record

/// All persistent SGP4 state (the `satrec` struct). Fresh instances are
/// zeroed, which matches the reference's explicit zeroing at the top of
/// `sgp4init`.
struct SGP4Record {
    var bstar = 0.0
    var ndot = 0.0
    var nddot = 0.0
    var ecco = 0.0
    var argpo = 0.0
    var inclo = 0.0
    var mo = 0.0
    var noKozai = 0.0
    var nodeo = 0.0
    var tumin = 0.0
    var mu = 0.0
    var radiusearthkm = 0.0
    var xke = 0.0
    var j2 = 0.0
    var j3 = 0.0
    var j4 = 0.0
    var j3oj2 = 0.0
    var jdsatepoch = 0.0
    var jdsatepochF = 0.0
    var t = 0.0
    var error = 0
    var method = "n"
    var operationmode = "i"
    var initFlag = "y"
    var isimp = 0
    var irez = 0
    var a = 0.0
    var alta = 0.0
    var altp = 0.0
    var am = 0.0
    var em = 0.0
    var im = 0.0
    var Om = 0.0
    var om = 0.0
    var mm = 0.0
    var nm = 0.0
    var noUnkozai = 0.0
    var argpdot = 0.0
    var nodedot = 0.0
    var mdot = 0.0
    var gsto = 0.0
    var con41 = 0.0
    var x1mth2 = 0.0
    var x7thm1 = 0.0
    var aycof = 0.0
    var xlcof = 0.0
    var xmcof = 0.0
    var omgcof = 0.0
    var nodecf = 0.0
    var t2cof = 0.0
    var t3cof = 0.0
    var t4cof = 0.0
    var t5cof = 0.0
    var cc1 = 0.0
    var cc4 = 0.0
    var cc5 = 0.0
    var d2 = 0.0
    var d3 = 0.0
    var d4 = 0.0
    var delmo = 0.0
    var sinmao = 0.0
    var eta = 0.0
    // Deep-space fields.
    var d2201 = 0.0
    var d2211 = 0.0
    var d3210 = 0.0
    var d3222 = 0.0
    var d4410 = 0.0
    var d4422 = 0.0
    var d5220 = 0.0
    var d5232 = 0.0
    var d5421 = 0.0
    var d5433 = 0.0
    var dedt = 0.0
    var del1 = 0.0
    var del2 = 0.0
    var del3 = 0.0
    var didt = 0.0
    var dmdt = 0.0
    var dnodt = 0.0
    var domdt = 0.0
    var e3 = 0.0
    var ee2 = 0.0
    var peo = 0.0
    var pgho = 0.0
    var pho = 0.0
    var pinco = 0.0
    var plo = 0.0
    var se2 = 0.0
    var se3 = 0.0
    var sgh2 = 0.0
    var sgh3 = 0.0
    var sgh4 = 0.0
    var sh2 = 0.0
    var sh3 = 0.0
    var si2 = 0.0
    var si3 = 0.0
    var sl2 = 0.0
    var sl3 = 0.0
    var sl4 = 0.0
    var xgh2 = 0.0
    var xgh3 = 0.0
    var xgh4 = 0.0
    var xh2 = 0.0
    var xh3 = 0.0
    var xi2 = 0.0
    var xi3 = 0.0
    var xl2 = 0.0
    var xl3 = 0.0
    var xl4 = 0.0
    var xlamo = 0.0
    var xli = 0.0
    var xni = 0.0
    var xfact = 0.0
    var zmol = 0.0
    var zmos = 0.0
    var atime = 0.0
}

/// Scratch values shared between `dscom` and `dsinit` (the long return
/// tuple of the reference, as a named struct).
private struct DSComLocals {
    var snodm = 0.0, cnodm = 0.0, sinim = 0.0, cosim = 0.0
    var sinomm = 0.0, cosomm = 0.0
    var day = 0.0, em = 0.0, emsq = 0.0, gam = 0.0, rtemsq = 0.0
    var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, s5 = 0.0, s6 = 0.0, s7 = 0.0
    var ss1 = 0.0, ss2 = 0.0, ss3 = 0.0, ss4 = 0.0, ss5 = 0.0, ss6 = 0.0, ss7 = 0.0
    var sz1 = 0.0, sz2 = 0.0, sz3 = 0.0
    var sz11 = 0.0, sz12 = 0.0, sz13 = 0.0
    var sz21 = 0.0, sz22 = 0.0, sz23 = 0.0
    var sz31 = 0.0, sz32 = 0.0, sz33 = 0.0
    var nm = 0.0
    var z1 = 0.0, z2 = 0.0, z3 = 0.0
    var z11 = 0.0, z12 = 0.0, z13 = 0.0
    var z21 = 0.0, z22 = 0.0, z23 = 0.0
    var z31 = 0.0, z32 = 0.0, z33 = 0.0
}

// MARK: - SGP4 propagator

/// Vallado SGP4/SDP4, ported from the reference implementation
/// (python-sgp4's pure-Python model, itself a line-for-line port of
/// Vallado's C++). WGS-72 constants, improved ('i') operation mode.
enum SGP4 {
    static let twopi = 2.0 * Double.pi
    static let deg2rad = Double.pi / 180.0
    static let minutesPerDay = 1440.0

    /// WGS-72 gravity constants (the standard for CelesTrak TLEs).
    static func wgs72() -> (tumin: Double, mu: Double, radiusearthkm: Double,
                            xke: Double, j2: Double, j3: Double,
                            j4: Double, j3oj2: Double) {
        let mu = 398600.8
        let radiusearthkm = 6378.135
        let xke = 60.0 / sqrt(radiusearthkm * radiusearthkm
                              * radiusearthkm / mu)
        let j2 = 0.001082616
        let j3 = -0.00000253881
        let j4 = -0.00000165597
        return (1.0 / xke, mu, radiusearthkm, xke, j2, j3, j4, j3 / j2)
    }

    /// Python-style floored modulo into [0, m): reproduces the reference
    /// implementation's use of `%` on doubles.
    static func fmodPos(_ x: Double, _ m: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }

    // MARK: gstime

    /// Greenwich sidereal time, radians in [0, 2pi). Vallado 2004, eq 3-45.
    static func gstime(jdut1: Double) -> Double {
        let tut1 = (jdut1 - 2451545.0) / 36525.0
        var temp = -6.2e-6 * tut1 * tut1 * tut1 + 0.093104 * tut1 * tut1
            + (876600.0 * 3600 + 8640184.812866) * tut1 + 67310.54841
        temp = fmodPos(temp * deg2rad / 240.0, twopi)
        if temp < 0.0 { temp += twopi }
        return temp
    }

    // MARK: initl

    /// Auxiliary epoch quantities; un-Kozais the mean motion.
    /// - Parameter epoch: days since 1950 Jan 0.0 (the SGP4 epoch).
    static func initl(xke: Double, j2: Double, ecco: Double, epoch: Double,
                      inclo: Double, no: Double, opsmode: String)
        -> (no: Double, method: String, ainv: Double, ao: Double,
            con41: Double, con42: Double, cosio: Double, cosio2: Double,
            eccsq: Double, omeosq: Double, posq: Double, rp: Double,
            rteosq: Double, sinio: Double, gsto: Double)
    {
        let x2o3 = 2.0 / 3.0
        let eccsq = ecco * ecco
        let omeosq = 1.0 - eccsq
        let rteosq = sqrt(omeosq)
        let cosio = cos(inclo)
        let cosio2 = cosio * cosio

        let ak = pow(xke / no, x2o3)
        let d1 = 0.75 * j2 * (3.0 * cosio2 - 1.0) / (rteosq * omeosq)
        var del_ = d1 / (ak * ak)
        let adel = ak * (1.0 - del_ * del_
                        - del_ * (1.0 / 3.0 + 134.0 * del_ * del_ / 81.0))
        del_ = d1 / (adel * adel)
        let noOut = no / (1.0 + del_)

        let ao = pow(xke / noOut, x2o3)
        let sinio = sin(inclo)
        let po = ao * omeosq
        let con42 = 1.0 - 5.0 * cosio2
        let con41 = -con42 - cosio2 - cosio2
        let ainv = 1.0 / ao
        let posq = po * po
        let rp = ao * (1.0 - ecco)

        let gsto: Double
        if opsmode == "a" {
            let ts70 = epoch - 7305.0
            let ds70 = floor(ts70 + 1.0e-8)
            let tfrac = ts70 - ds70
            let c1 = 1.72027916940703639e-2
            let thgr70 = 1.7321343856509374
            let fk5r = 5.07551419432269442e-15
            let c1p2p = c1 + twopi
            var g = fmodPos(thgr70 + c1 * ds70 + c1p2p * tfrac
                            + ts70 * ts70 * fk5r, twopi)
            if g < 0.0 { g += twopi }
            gsto = g
        } else {
            gsto = gstime(jdut1: epoch + 2433281.5)
        }
        return (noOut, "n", ainv, ao, con41, con42, cosio, cosio2,
                eccsq, omeosq, posq, rp, rteosq, sinio, gsto)
    }

    // MARK: dpper

    /// Deep-space long-period periodic contributions. By design the
    /// periodics are zero at epoch.
    static func dpper(rec: inout SGP4Record, inclo: Double,
                      init initFlag: String,
                      ep: Double, inclp: Double, nodep: Double,
                      argpp: Double, mp: Double, opsmode: String)
        -> (ep: Double, inclp: Double, nodep: Double,
            argpp: Double, mp: Double)
    {
        let zns = 1.19459e-5
        let zes = 0.01675
        let znl = 1.5835218e-4
        let zel = 0.05490

        var zm = rec.zmos + zns * rec.t
        if initFlag == "y" { zm = rec.zmos }
        var zf = zm + 2.0 * zes * sin(zm)
        var sinzf = sin(zf)
        var f2 = 0.5 * sinzf * sinzf - 0.25
        var f3 = -0.5 * sinzf * cos(zf)
        let ses = rec.se2 * f2 + rec.se3 * f3
        let sis = rec.si2 * f2 + rec.si3 * f3
        let sls = rec.sl2 * f2 + rec.sl3 * f3 + rec.sl4 * sinzf
        let sghs = rec.sgh2 * f2 + rec.sgh3 * f3 + rec.sgh4 * sinzf
        let shs = rec.sh2 * f2 + rec.sh3 * f3
        zm = rec.zmol + znl * rec.t
        if initFlag == "y" { zm = rec.zmol }
        zf = zm + 2.0 * zel * sin(zm)
        sinzf = sin(zf)
        f2 = 0.5 * sinzf * sinzf - 0.25
        f3 = -0.5 * sinzf * cos(zf)
        let sel = rec.ee2 * f2 + rec.e3 * f3
        let sil = rec.xi2 * f2 + rec.xi3 * f3
        let sll = rec.xl2 * f2 + rec.xl3 * f3 + rec.xl4 * sinzf
        let sghl = rec.xgh2 * f2 + rec.xgh3 * f3 + rec.xgh4 * sinzf
        let shll = rec.xh2 * f2 + rec.xh3 * f3
        var pe = ses + sel
        var pinc = sis + sil
        let pl = sls + sll
        var pgh = sghs + sghl
        var ph = shs + shll

        var epOut = ep
        var inclpOut = inclp
        var nodepOut = nodep
        var argppOut = argpp
        var mpOut = mp

        if initFlag == "n" {
            pe -= rec.peo
            pinc -= rec.pinco
            let plAdj = pl - rec.plo
            pgh -= rec.pgho
            ph -= rec.pho
            inclpOut += pinc
            epOut += pe
            let sinip = sin(inclpOut)
            let cosip = cos(inclpOut)

            if inclpOut >= 0.2 {
                ph /= sinip
                pgh -= cosip * ph
                argppOut += pgh
                nodepOut += ph
                mpOut += plAdj
            } else {
                // Lyddane modification for low inclinations.
                let sinop = sin(nodepOut)
                let cosop = cos(nodepOut)
                var alfdp = sinip * sinop
                var betdp = sinip * cosop
                let dalf = ph * cosop + pinc * cosip * sinop
                let dbet = -ph * sinop + pinc * cosip * cosop
                alfdp += dalf
                betdp += dbet
                // Reference: nodep % twopi if nodep >= 0 else
                // -(-nodep % twopi) -- exactly truncatingRemainder.
                nodepOut = nodepOut.truncatingRemainder(dividingBy: twopi)
                if nodepOut < 0.0 && opsmode == "a" { nodepOut += twopi }
                let xls = mpOut + argppOut + plAdj + pgh
                    + (cosip - pinc * sinip) * nodepOut
                let xnoh = nodepOut
                nodepOut = atan2(alfdp, betdp)
                if nodepOut < 0.0 && opsmode == "a" { nodepOut += twopi }
                if abs(xnoh - nodepOut) > Double.pi {
                    if nodepOut < xnoh { nodepOut += twopi }
                    else { nodepOut -= twopi }
                }
                mpOut += plAdj
                argppOut = xls - mpOut - cosip * nodepOut
            }
        }
        return (epOut, inclpOut, nodepOut, argppOut, mpOut)
    }

    // MARK: dscom

    /// Deep-space common items used by both the secular and periodic
    /// subroutines. Writes the shared terms into the record and returns
    /// the remaining locals needed by `dsinit`.
    static func dscom(epoch: Double, ep: Double, argpp: Double, tc: Double,
                      inclp: Double, nodep: Double, np: Double,
                      rec: inout SGP4Record) -> DSComLocals {
        let zes = 0.01675
        let zel = 0.05490
        let c1ss = 2.9864797e-6
        let c1l = 4.7968065e-7
        let zsinis = 0.39785416
        let zcosis = 0.91744867
        let zcosgs = 0.1945905
        let zsings = -0.98088458

        var L = DSComLocals()
        L.nm = np
        L.em = ep
        L.snodm = sin(nodep)
        L.cnodm = cos(nodep)
        L.sinomm = sin(argpp)
        L.cosomm = cos(argpp)
        L.sinim = sin(inclp)
        L.cosim = cos(inclp)
        L.emsq = L.em * L.em
        let betasq = 1.0 - L.emsq
        L.rtemsq = sqrt(betasq)

        rec.peo = 0.0
        rec.pinco = 0.0
        rec.plo = 0.0
        rec.pgho = 0.0
        rec.pho = 0.0
        let day = epoch + 18261.5 + tc / 1440.0
        L.day = day
        let xnodce = fmodPos(4.5236020 - 9.2422029e-4 * day, twopi)
        let stem = sin(xnodce)
        let ctem = cos(xnodce)
        let zcosil = 0.91375164 - 0.03568096 * ctem
        let zsinil = sqrt(1.0 - zcosil * zcosil)
        let zsinhl = 0.089683511 * stem / zsinil
        let zcoshl = sqrt(1.0 - zsinhl * zsinhl)
        let gam = 5.8351514 + 0.0019443680 * day
        L.gam = gam
        var zx = 0.39785416 * stem / zsinil
        let zy = zcoshl * ctem + 0.91744867 * zsinhl * stem
        zx = atan2(zx, zy)
        zx = gam + zx - xnodce
        let zcosgl = cos(zx)
        let zsingl = sin(zx)

        var zcosg = zcosgs
        var zsing = zsings
        var zcosi = zcosis
        var zsini = zsinis
        var zcosh = L.cnodm
        var zsinh = L.snodm
        var cc = c1ss
        let xnoi = 1.0 / L.nm

        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var s5 = 0.0, s6 = 0.0, s7 = 0.0
        var z1 = 0.0, z2 = 0.0, z3 = 0.0
        var z11 = 0.0, z12 = 0.0, z13 = 0.0
        var z21 = 0.0, z22 = 0.0, z23 = 0.0
        var z31 = 0.0, z32 = 0.0, z33 = 0.0

        for lsflg in 1...2 {
            let a1 = zcosg * zcosh + zsing * zcosi * zsinh
            let a3 = -zsing * zcosh + zcosg * zcosi * zsinh
            let a7 = -zcosg * zsinh + zsing * zcosi * zcosh
            let a8 = zsing * zsini
            let a9 = zsing * zsinh + zcosg * zcosi * zcosh
            let a10 = zcosg * zsini
            let a2 = L.cosim * a7 + L.sinim * a8
            let a4 = L.cosim * a9 + L.sinim * a10
            let a5 = -L.sinim * a7 + L.cosim * a8
            let a6 = -L.sinim * a9 + L.cosim * a10

            let x1 = a1 * L.cosomm + a2 * L.sinomm
            let x2 = a3 * L.cosomm + a4 * L.sinomm
            let x3 = -a1 * L.sinomm + a2 * L.cosomm
            let x4 = -a3 * L.sinomm + a4 * L.cosomm
            let x5 = a5 * L.sinomm
            let x6 = a6 * L.sinomm
            let x7 = a5 * L.cosomm
            let x8 = a6 * L.cosomm

            z31 = 12.0 * x1 * x1 - 3.0 * x3 * x3
            z32 = 24.0 * x1 * x2 - 6.0 * x3 * x4
            z33 = 12.0 * x2 * x2 - 3.0 * x4 * x4
            z1 = 3.0 * (a1 * a1 + a2 * a2) + z31 * L.emsq
            z2 = 6.0 * (a1 * a3 + a2 * a4) + z32 * L.emsq
            z3 = 3.0 * (a3 * a3 + a4 * a4) + z33 * L.emsq
            z11 = -6.0 * a1 * a5
                + L.emsq * (-24.0 * x1 * x7 - 6.0 * x3 * x5)
            z12 = -6.0 * (a1 * a6 + a3 * a5)
                + L.emsq * (-24.0 * (x2 * x7 + x1 * x8)
                            - 6.0 * (x3 * x6 + x4 * x5))
            z13 = -6.0 * a3 * a6
                + L.emsq * (-24.0 * x2 * x8 - 6.0 * x4 * x6)
            z21 = 6.0 * a2 * a5 + L.emsq * (24.0 * x1 * x5 - 6.0 * x3 * x7)
            z22 = 6.0 * (a4 * a5 + a2 * a6)
                + L.emsq * (24.0 * (x2 * x5 + x1 * x6)
                            - 6.0 * (x4 * x7 + x3 * x8))
            z23 = 6.0 * a4 * a6 + L.emsq * (24.0 * x2 * x6 - 6.0 * x4 * x8)
            z1 = z1 + z1 + betasq * z31
            z2 = z2 + z2 + betasq * z32
            z3 = z3 + z3 + betasq * z33
            s3 = cc * xnoi
            s2 = -0.5 * s3 / L.rtemsq
            s4 = s3 * L.rtemsq
            s1 = -15.0 * L.em * s4
            s5 = x1 * x3 + x2 * x4
            s6 = x2 * x3 + x1 * x4
            s7 = x2 * x4 - x1 * x3

            if lsflg == 1 {
                L.ss1 = s1; L.ss2 = s2; L.ss3 = s3; L.ss4 = s4
                L.ss5 = s5; L.ss6 = s6; L.ss7 = s7
                L.sz1 = z1; L.sz2 = z2; L.sz3 = z3
                L.sz11 = z11; L.sz12 = z12; L.sz13 = z13
                L.sz21 = z21; L.sz22 = z22; L.sz23 = z23
                L.sz31 = z31; L.sz32 = z32; L.sz33 = z33
                zcosg = zcosgl
                zsing = zsingl
                zcosi = zcosil
                zsini = zsinil
                zcosh = zcoshl * L.cnodm + zsinhl * L.snodm
                zsinh = L.snodm * zcoshl - L.cnodm * zsinhl
                cc = c1l
            }
        }
        L.s1 = s1; L.s2 = s2; L.s3 = s3; L.s4 = s4
        L.s5 = s5; L.s6 = s6; L.s7 = s7
        L.z1 = z1; L.z2 = z2; L.z3 = z3
        L.z11 = z11; L.z12 = z12; L.z13 = z13
        L.z21 = z21; L.z22 = z22; L.z23 = z23
        L.z31 = z31; L.z32 = z32; L.z33 = z33

        rec.zmol = fmodPos(4.7199672 + 0.22997150 * day - gam, twopi)
        rec.zmos = fmodPos(6.2565837 + 0.017201977 * day, twopi)

        rec.se2 = 2.0 * L.ss1 * L.ss6
        rec.se3 = 2.0 * L.ss1 * L.ss7
        rec.si2 = 2.0 * L.ss2 * L.sz12
        rec.si3 = 2.0 * L.ss2 * (L.sz13 - L.sz11)
        rec.sl2 = -2.0 * L.ss3 * L.sz2
        rec.sl3 = -2.0 * L.ss3 * (L.sz3 - L.sz1)
        rec.sl4 = -2.0 * L.ss3 * (-21.0 - 9.0 * L.emsq) * zes
        rec.sgh2 = 2.0 * L.ss4 * L.sz32
        rec.sgh3 = 2.0 * L.ss4 * (L.sz33 - L.sz31)
        rec.sgh4 = -18.0 * L.ss4 * zes
        rec.sh2 = -2.0 * L.ss2 * L.sz22
        rec.sh3 = -2.0 * L.ss2 * (L.sz23 - L.sz21)

        rec.ee2 = 2.0 * s1 * s6
        rec.e3 = 2.0 * s1 * s7
        rec.xi2 = 2.0 * s2 * z12
        rec.xi3 = 2.0 * s2 * (z13 - z11)
        rec.xl2 = -2.0 * s3 * z2
        rec.xl3 = -2.0 * s3 * (z3 - z1)
        rec.xl4 = -2.0 * s3 * (-21.0 - 9.0 * L.emsq) * zel
        rec.xgh2 = 2.0 * s4 * z32
        rec.xgh3 = 2.0 * s4 * (z33 - z31)
        rec.xgh4 = -18.0 * s4 * zel
        rec.xh2 = -2.0 * s2 * z22
        rec.xh3 = -2.0 * s2 * (z23 - z21)

        return L
    }

    // MARK: dsinit

    /// Deep-space resonance initialization. Resonance coefficients are
    /// written into the record; the singly-averaged elements it refines
    /// are internal (the reference's caller discards them).
    static func dsinit(rec: inout SGP4Record, com: DSComLocals,
                       ecco: Double, eccsq: Double, em: Double,
                       argpm: Double, inclm: Double, mm: Double,
                       nm: Double, nodem: Double,
                       xpidot: Double, t: Double, tc: Double,
                       gsto: Double, mo: Double, mdot: Double,
                       no: Double, nodeo: Double, nodedot: Double,
                       argpo: Double) {
        let q22 = 1.7891679e-6
        let q31 = 2.1460748e-6
        let q33 = 2.2123015e-7
        let root22 = 1.7891679e-6
        let root44 = 7.3636953e-9
        let root54 = 2.1765803e-9
        let rptim = 4.37526908801129966e-3
        let root32 = 3.7393792e-7
        let root52 = 1.1428639e-7
        let x2o3 = 2.0 / 3.0
        let znl = 1.5835218e-4
        let zns = 1.19459e-5

        var emL = em
        var argpmL = argpm
        var inclmL = inclm
        var mmL = mm
        var nmL = nm
        var nodemL = nodem
        var emsqL = com.emsq

        var irez = 0
        if 0.0034906585 < nmL && nmL < 0.0052359877 { irez = 1 }
        if 8.26e-3 <= nmL && nmL <= 9.24e-3 && emL >= 0.5 { irez = 2 }
        rec.irez = irez

        let ses = com.ss1 * zns * com.ss5
        let sis = com.ss2 * zns * (com.sz11 + com.sz13)
        let sls = -zns * com.ss3 * (com.sz1 + com.sz3 - 14.0 - 6.0 * com.emsq)
        let sghs = com.ss4 * zns * (com.sz31 + com.sz33 - 6.0)
        var shs = -zns * com.ss2 * (com.sz21 + com.sz23)
        if inclmL < 5.2359877e-2 || inclmL > Double.pi - 5.2359877e-2 {
            shs = 0.0
        }
        if com.sinim != 0.0 { shs = shs / com.sinim }
        let sgs = sghs - com.cosim * shs

        let dedt = ses + com.s1 * znl * com.s5
        let didt = sis + com.s2 * znl * (com.z11 + com.z13)
        let dmdt = sls - znl * com.s3 * (com.z1 + com.z3 - 14.0 - 6.0 * com.emsq)
        let sghl = com.s4 * znl * (com.z31 + com.z33 - 6.0)
        var shll = -znl * com.s2 * (com.z21 + com.z23)
        if inclmL < 5.2359877e-2 || inclmL > Double.pi - 5.2359877e-2 {
            shll = 0.0
        }
        var domdt = sgs + sghl
        var dnodt = shs
        if com.sinim != 0.0 {
            domdt -= com.cosim / com.sinim * shll
            dnodt += shll / com.sinim
        }
        rec.dedt = dedt
        rec.didt = didt
        rec.dmdt = dmdt
        rec.dnodt = dnodt
        rec.domdt = domdt

        let theta = fmodPos(gsto + tc * rptim, twopi)
        emL += dedt * t
        inclmL += didt * t
        argpmL += domdt * t
        nodemL += dnodt * t
        mmL += dmdt * t

        if irez != 0 {
            let aonv = pow(nmL / rec.xke, x2o3)

            if irez == 2 {
                let cosisq = com.cosim * com.cosim
                let emo = emL
                emL = ecco
                let emsqo = emsqL
                emsqL = eccsq
                let eoc = emL * emsqL
                let g201 = -0.306 - (emL - 0.64) * 0.440
                var g211: Double, g310: Double, g322: Double
                var g410: Double, g422: Double, g520: Double
                if emL <= 0.65 {
                    g211 = 3.616 - 13.2470 * emL + 16.2900 * emsqL
                    g310 = -19.302 + 117.3900 * emL - 228.4190 * emsqL
                        + 156.5910 * eoc
                    g322 = -18.9068 + 109.7927 * emL - 214.6334 * emsqL
                        + 146.5816 * eoc
                    g410 = -41.122 + 242.6940 * emL - 471.0940 * emsqL
                        + 313.9530 * eoc
                    g422 = -146.407 + 841.8800 * emL - 1629.014 * emsqL
                        + 1083.4350 * eoc
                    g520 = -532.114 + 3017.977 * emL - 5740.032 * emsqL
                        + 3708.2760 * eoc
                } else {
                    g211 = -72.099 + 331.819 * emL - 508.738 * emsqL
                        + 266.724 * eoc
                    g310 = -346.844 + 1582.851 * emL - 2415.925 * emsqL
                        + 1246.113 * eoc
                    g322 = -342.585 + 1554.908 * emL - 2366.899 * emsqL
                        + 1215.972 * eoc
                    g410 = -1052.797 + 4758.686 * emL - 7193.992 * emsqL
                        + 3651.957 * eoc
                    g422 = -3581.690 + 16178.110 * emL - 24462.770 * emsqL
                        + 12422.520 * eoc
                    if emL > 0.715 {
                        g520 = -5149.66 + 29936.92 * emL - 54087.36 * emsqL
                            + 31324.56 * eoc
                    } else {
                        g520 = 1464.74 - 4664.75 * emL + 3763.64 * emsqL
                    }
                }
                var g533: Double, g521: Double, g532: Double
                if emL < 0.7 {
                    g533 = -919.22770 + 4988.6100 * emL - 9064.7700 * emsqL
                        + 5542.21 * eoc
                    g521 = -822.71072 + 4568.6173 * emL - 8491.4146 * emsqL
                        + 5337.524 * eoc
                    g532 = -853.66600 + 4690.2500 * emL - 8624.7700 * emsqL
                        + 5341.4 * eoc
                } else {
                    g533 = -37995.780 + 161616.52 * emL - 229838.20 * emsqL
                        + 109377.94 * eoc
                    g521 = -51752.104 + 218913.95 * emL - 309468.16 * emsqL
                        + 146349.42 * eoc
                    g532 = -40023.880 + 170470.89 * emL - 242699.48 * emsqL
                        + 115605.82 * eoc
                }

                let sini2 = com.sinim * com.sinim
                let f220 = 0.75 * (1.0 + 2.0 * com.cosim + cosisq)
                let f221 = 1.5 * sini2
                let f321 = 1.875 * com.sinim
                    * (1.0 - 2.0 * com.cosim - 3.0 * cosisq)
                let f322 = -1.875 * com.sinim
                    * (1.0 + 2.0 * com.cosim - 3.0 * cosisq)
                let f441 = 35.0 * sini2 * f220
                let f442 = 39.3750 * sini2 * sini2
                let f522 = 9.84375 * com.sinim
                    * (sini2 * (1.0 - 2.0 * com.cosim - 5.0 * cosisq)
                       + 0.33333333 * (-2.0 + 4.0 * com.cosim + 6.0 * cosisq))
                let f523 = com.sinim
                    * (4.92187512 * sini2 * (-2.0 - 4.0 * com.cosim
                                            + 10.0 * cosisq)
                       + 6.56250012 * (1.0 + 2.0 * com.cosim - 3.0 * cosisq))
                let f542 = 29.53125 * com.sinim
                    * (2.0 - 8.0 * com.cosim
                       + cosisq * (-12.0 + 8.0 * com.cosim + 10.0 * cosisq))
                let f543 = 29.53125 * com.sinim
                    * (-2.0 - 8.0 * com.cosim
                       + cosisq * (12.0 + 8.0 * com.cosim - 10.0 * cosisq))
                let xno2 = nmL * nmL
                let ainv2 = aonv * aonv
                var temp1 = 3.0 * xno2 * ainv2
                var temp = temp1 * root22
                rec.d2201 = temp * f220 * g201
                rec.d2211 = temp * f221 * g211
                temp1 = temp1 * aonv
                temp = temp1 * root32
                rec.d3210 = temp * f321 * g310
                rec.d3222 = temp * f322 * g322
                temp1 = temp1 * aonv
                temp = 2.0 * temp1 * root44
                rec.d4410 = temp * f441 * g410
                rec.d4422 = temp * f442 * g422
                temp1 = temp1 * aonv
                temp = temp1 * root52
                rec.d5220 = temp * f522 * g520
                rec.d5232 = temp * f523 * g532
                temp = 2.0 * temp1 * root54
                rec.d5421 = temp * f542 * g521
                rec.d5433 = temp * f543 * g533
                rec.xlamo = fmodPos(mo + nodeo + nodeo - theta - theta, twopi)
                rec.xfact = mdot + dmdt + 2.0 * (nodedot + dnodt - rptim) - no
                emL = emo
                emsqL = emsqo
            }

            if irez == 1 {
                let g200 = 1.0 + emsqL * (-2.5 + 0.8125 * emsqL)
                let g310 = 1.0 + 2.0 * emsqL
                let g300 = 1.0 + emsqL * (-6.0 + 6.60937 * emsqL)
                let f220 = 0.75 * (1.0 + com.cosim) * (1.0 + com.cosim)
                let f311 = 0.9375 * com.sinim * com.sinim
                    * (1.0 + 3.0 * com.cosim) - 0.75 * (1.0 + com.cosim)
                var f330 = 1.0 + com.cosim
                f330 = 1.875 * f330 * f330 * f330
                var del1 = 3.0 * nmL * nmL * aonv * aonv
                let del2 = 2.0 * del1 * f220 * g200 * q22
                let del3 = 3.0 * del1 * f330 * g300 * q33 * aonv
                del1 = del1 * f311 * g310 * q31 * aonv
                rec.del1 = del1
                rec.del2 = del2
                rec.del3 = del3
                rec.xlamo = fmodPos(mo + nodeo + argpo - theta, twopi)
                rec.xfact = mdot + xpidot - rptim + dmdt + domdt + dnodt - no
            }

            rec.xli = rec.xlamo
            rec.xni = no
            rec.atime = 0.0
            nmL = no
        }
    }

    // MARK: dspace

    /// Deep-space contributions to the mean elements (third-body
    /// averaged effects plus resonance integration). Updates the
    /// integrator state in the record and returns the refined elements.
    static func dspace(rec: inout SGP4Record, t: Double, tc: Double,
                       em: Double, argpm: Double, inclm: Double,
                       mm: Double, nm: Double, nodem: Double)
        -> (em: Double, argpm: Double, inclm: Double, mm: Double,
            nm: Double, nodem: Double)
    {
        let fasx2 = 0.13130908
        let fasx4 = 2.8843198
        let fasx6 = 0.37448087
        let g22 = 5.7686396
        let g32 = 0.95240898
        let g44 = 1.8014998
        let g52 = 1.0508330
        let g54 = 4.4108898
        let rptim = 4.37526908801129966e-3
        let stepp = 720.0
        let stepn = -720.0
        let step2 = 259200.0

        let theta = fmodPos(rec.gsto + tc * rptim, twopi)
        var emL = em + rec.dedt * t
        var inclmL = inclm + rec.didt * t
        var argpmL = argpm + rec.domdt * t
        var nodemL = nodem + rec.dnodt * t
        var mmL = mm + rec.dmdt * t
        var nmL = nm

        if rec.irez != 0 {
            if rec.atime == 0.0 || t * rec.atime <= 0.0
                || abs(t) < abs(rec.atime) {
                rec.atime = 0.0
                rec.xni = rec.noUnkozai
                rec.xli = rec.xlamo
            }
            let delt: Double = t > 0.0 ? stepp : stepn

            var iretn = 381
            var ft = 0.0
            var xndt = 0.0
            var xldot = 0.0
            var xnddt = 0.0
            while iretn == 381 {
                if rec.irez != 2 {
                    xndt = rec.del1 * sin(rec.xli - fasx2)
                        + rec.del2 * sin(2.0 * (rec.xli - fasx4))
                        + rec.del3 * sin(3.0 * (rec.xli - fasx6))
                    xldot = rec.xni + rec.xfact
                    xnddt = rec.del1 * cos(rec.xli - fasx2)
                        + 2.0 * rec.del2 * cos(2.0 * (rec.xli - fasx4))
                        + 3.0 * rec.del3 * cos(3.0 * (rec.xli - fasx6))
                    xnddt = xnddt * xldot
                } else {
                    let xomi = rec.argpo + rec.argpdot * rec.atime
                    let x2omi = xomi + xomi
                    let x2li = rec.xli + rec.xli
                    xndt = rec.d2201 * sin(x2omi + rec.xli - g22)
                        + rec.d2211 * sin(rec.xli - g22)
                        + rec.d3210 * sin(xomi + rec.xli - g32)
                        + rec.d3222 * sin(-xomi + rec.xli - g32)
                        + rec.d4410 * sin(x2omi + x2li - g44)
                        + rec.d4422 * sin(x2li - g44)
                        + rec.d5220 * sin(xomi + rec.xli - g52)
                        + rec.d5232 * sin(-xomi + rec.xli - g52)
                        + rec.d5421 * sin(xomi + x2li - g54)
                        + rec.d5433 * sin(-xomi + x2li - g54)
                    xldot = rec.xni + rec.xfact
                    xnddt = rec.d2201 * cos(x2omi + rec.xli - g22)
                        + rec.d2211 * cos(rec.xli - g22)
                        + rec.d3210 * cos(xomi + rec.xli - g32)
                        + rec.d3222 * cos(-xomi + rec.xli - g32)
                        + rec.d5220 * cos(xomi + rec.xli - g52)
                        + rec.d5232 * cos(-xomi + rec.xli - g52)
                        + 2.0 * (rec.d4410 * cos(x2omi + x2li - g44)
                                 + rec.d4422 * cos(x2li - g44)
                                 + rec.d5421 * cos(xomi + x2li - g54)
                                 + rec.d5433 * cos(-xomi + x2li - g54))
                    xnddt = xnddt * xldot
                }

                if abs(t - rec.atime) >= stepp {
                    iretn = 381
                } else {
                    ft = t - rec.atime
                    iretn = 0
                }
                if iretn == 381 {
                    rec.xli = rec.xli + xldot * delt + xndt * step2
                    rec.xni = rec.xni + xndt * delt + xnddt * step2
                    rec.atime = rec.atime + delt
                }
            }

            nmL = rec.xni + xndt * ft + xnddt * ft * ft * 0.5
            let xl = rec.xli + xldot * ft + xndt * ft * ft * 0.5
            if rec.irez != 1 {
                mmL = xl - 2.0 * nodemL + 2.0 * theta
            } else {
                mmL = xl - nodemL - argpmL + theta
            }
            let dndt = nmL - rec.noUnkozai
            nmL = rec.noUnkozai + dndt
        }
        return (emL, argpmL, inclmL, mmL, nmL, nodemL)
    }

    // MARK: sgp4init

    /// Initialize a record from a parsed TLE (WGS-72, improved mode).
    /// Ends with a zero-epoch propagation, exactly like the reference.
    static func initialize(from tle: TLE) -> SGP4Record {
        var rec = SGP4Record()
        let g = wgs72()
        rec.tumin = g.tumin
        rec.mu = g.mu
        rec.radiusearthkm = g.radiusearthkm
        rec.xke = g.xke
        rec.j2 = g.j2
        rec.j3 = g.j3
        rec.j4 = g.j4
        rec.j3oj2 = g.j3oj2

        rec.error = 0
        rec.operationmode = "i"
        rec.bstar = tle.bstar
        rec.ndot = tle.ndot
        rec.nddot = tle.nddot
        rec.ecco = tle.ecco
        rec.argpo = tle.argpo
        rec.inclo = tle.inclo
        rec.mo = tle.mo
        rec.noKozai = tle.noKozai
        rec.nodeo = tle.nodeo

        let ss = 78.0 / rec.radiusearthkm + 1.0
        let qzms2ttemp = (120.0 - 78.0) / rec.radiusearthkm
        let qzms2t = qzms2ttemp * qzms2ttemp * qzms2ttemp * qzms2ttemp
        let x2o3 = 2.0 / 3.0

        rec.initFlag = "y"
        rec.t = 0.0

        let epoch = tle.epochJulianDate - 2433281.5
        rec.jdsatepoch = tle.jdsatepoch
        rec.jdsatepochF = tle.jdsatepochF

        let il = initl(xke: rec.xke, j2: rec.j2, ecco: rec.ecco,
                       epoch: epoch, inclo: rec.inclo, no: rec.noKozai,
                       opsmode: rec.operationmode)
        rec.noUnkozai = il.no
        rec.method = il.method
        rec.con41 = il.con41
        rec.gsto = il.gsto
        rec.a = pow(rec.noUnkozai * rec.tumin, -2.0 / 3.0)
        rec.alta = rec.a * (1.0 + rec.ecco) - 1.0
        rec.altp = rec.a * (1.0 - rec.ecco) - 1.0

        if il.omeosq >= 0.0 || rec.noUnkozai >= 0.0 {
            rec.isimp = 0
            if il.rp < 220.0 / rec.radiusearthkm + 1.0 { rec.isimp = 1 }
            var sfour = ss
            var qzms24 = qzms2t
            let perige = (il.rp - 1.0) * rec.radiusearthkm

            if perige < 156.0 {
                sfour = perige - 78.0
                if perige < 98.0 { sfour = 20.0 }
                let qzms24temp = (120.0 - sfour) / rec.radiusearthkm
                qzms24 = qzms24temp * qzms24temp * qzms24temp * qzms24temp
                sfour = sfour / rec.radiusearthkm + 1.0
            }

            let pinvsq = 1.0 / il.posq
            let tsi = 1.0 / (il.ao - sfour)
            rec.eta = il.ao * rec.ecco * tsi
            let etasq = rec.eta * rec.eta
            let eeta = rec.ecco * rec.eta
            let psisq = abs(1.0 - etasq)
            let coef = qzms24 * pow(tsi, 4.0)
            let coef1 = coef / pow(psisq, 3.5)
            let cc2 = coef1 * rec.noUnkozai
                * (il.ao * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq))
                   + 0.375 * rec.j2 * tsi / psisq * rec.con41
                   * (8.0 + 3.0 * etasq * (8.0 + etasq)))
            rec.cc1 = rec.bstar * cc2
            var cc3 = 0.0
            if rec.ecco > 1.0e-4 {
                cc3 = -2.0 * coef * tsi * rec.j3oj2 * rec.noUnkozai
                    * il.sinio / rec.ecco
            }
            rec.x1mth2 = 1.0 - il.cosio2
            rec.cc4 = 2.0 * rec.noUnkozai * coef1 * il.ao * il.omeosq
                * (rec.eta * (2.0 + 0.5 * etasq)
                   + rec.ecco * (0.5 + 2.0 * etasq)
                   - rec.j2 * tsi / (il.ao * psisq)
                   * (-3.0 * rec.con41
                      * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta))
                      + 0.75 * rec.x1mth2
                      * (2.0 * etasq - eeta * (1.0 + etasq))
                      * cos(2.0 * rec.argpo)))
            rec.cc5 = 2.0 * coef1 * il.ao * il.omeosq
                * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq)
            let cosio4 = il.cosio2 * il.cosio2
            let temp1 = 1.5 * rec.j2 * pinvsq * rec.noUnkozai
            let temp2 = 0.5 * temp1 * rec.j2 * pinvsq
            let temp3 = -0.46875 * rec.j4 * pinvsq * pinvsq * rec.noUnkozai
            rec.mdot = rec.noUnkozai + 0.5 * temp1 * il.rteosq * rec.con41
                + 0.0625 * temp2 * il.rteosq
                * (13.0 - 78.0 * il.cosio2 + 137.0 * cosio4)
            rec.argpdot = -0.5 * temp1 * il.con42
                + 0.0625 * temp2 * (7.0 - 114.0 * il.cosio2 + 395.0 * cosio4)
                + temp3 * (3.0 - 36.0 * il.cosio2 + 49.0 * cosio4)
            let xhdot1 = -temp1 * il.cosio
            rec.nodedot = xhdot1
                + (0.5 * temp2 * (4.0 - 19.0 * il.cosio2)
                   + 2.0 * temp3 * (3.0 - 7.0 * il.cosio2)) * il.cosio
            let xpidot = rec.argpdot + rec.nodedot
            rec.omgcof = rec.bstar * cc3 * cos(rec.argpo)
            rec.xmcof = 0.0
            if rec.ecco > 1.0e-4 {
                rec.xmcof = -x2o3 * coef * rec.bstar / eeta
            }
            rec.nodecf = 3.5 * il.omeosq * xhdot1 * rec.cc1
            rec.t2cof = 1.5 * rec.cc1
            let temp4 = 1.5e-12
            if abs(il.cosio + 1.0) > 1.5e-12 {
                rec.xlcof = -0.25 * rec.j3oj2 * il.sinio
                    * (3.0 + 5.0 * il.cosio) / (1.0 + il.cosio)
            } else {
                rec.xlcof = -0.25 * rec.j3oj2 * il.sinio
                    * (3.0 + 5.0 * il.cosio) / temp4
            }
            rec.aycof = -0.5 * rec.j3oj2 * il.sinio
            let delmotemp = 1.0 + rec.eta * cos(rec.mo)
            rec.delmo = delmotemp * delmotemp * delmotemp
            rec.sinmao = sin(rec.mo)
            rec.x7thm1 = 7.0 * il.cosio2 - 1.0

            if twopi / rec.noUnkozai >= 225.0 {
                rec.method = "d"
                rec.isimp = 1
                let tc = 0.0
                let inclm = rec.inclo
                let com = dscom(epoch: epoch, ep: rec.ecco,
                                argpp: rec.argpo, tc: tc, inclp: rec.inclo,
                                nodep: rec.nodeo, np: rec.noUnkozai,
                                rec: &rec)
                let dp = dpper(rec: &rec, inclo: inclm, init: rec.initFlag,
                               ep: rec.ecco, inclp: rec.inclo,
                               nodep: rec.nodeo, argpp: rec.argpo,
                               mp: rec.mo, opsmode: rec.operationmode)
                rec.ecco = dp.ep
                rec.inclo = dp.inclp
                rec.nodeo = dp.nodep
                rec.argpo = dp.argpp
                rec.mo = dp.mp
                dsinit(rec: &rec, com: com, ecco: rec.ecco, eccsq: il.eccsq,
                       em: com.em, argpm: 0.0, inclm: inclm, mm: 0.0,
                       nm: com.nm, nodem: 0.0, xpidot: xpidot, t: rec.t,
                       tc: tc, gsto: rec.gsto, mo: rec.mo, mdot: rec.mdot,
                       no: rec.noUnkozai, nodeo: rec.nodeo,
                       nodedot: rec.nodedot, argpo: rec.argpo)
            }

            if rec.isimp != 1 {
                let cc1sq = rec.cc1 * rec.cc1
                rec.d2 = 4.0 * il.ao * tsi * cc1sq
                let temp = rec.d2 * tsi * rec.cc1 / 3.0
                rec.d3 = (17.0 * il.ao + sfour) * temp
                rec.d4 = 0.5 * temp * il.ao * tsi
                    * (221.0 * il.ao + 31.0 * sfour) * rec.cc1
                rec.t3cof = rec.d2 + 2.0 * cc1sq
                rec.t4cof = 0.25 * (3.0 * rec.d3 + rec.cc1
                                    * (12.0 * rec.d2 + 10.0 * cc1sq))
                rec.t5cof = 0.2 * (3.0 * rec.d4 + 12.0 * rec.cc1 * rec.d3
                                   + 6.0 * rec.d2 * rec.d2
                                   + 15.0 * cc1sq * (2.0 * rec.d2 + cc1sq))
            }
        }

        // Propagate to zero epoch to initialize, like the reference.
        _ = propagateCore(&rec, tsince: 0.0)
        rec.initFlag = "n"
        return rec
    }

    // MARK: sgp4

    /// Core propagator. Returns nil on error (`rec.error` holds the
    /// reference error code: 1 eccentricity, 2 mean motion, 3 perturbed
    /// eccentricity, 4 semilatus rectum, 6 decayed).
    static func propagateCore(_ rec: inout SGP4Record,
                              tsince: Double) -> SatelliteState? {
        let temp4 = 1.5e-12
        let x2o3 = 2.0 / 3.0
        let vkmpersec = rec.radiusearthkm * rec.xke / 60.0

        rec.t = tsince
        rec.error = 0

        let xmdf = rec.mo + rec.mdot * rec.t
        let argpdf = rec.argpo + rec.argpdot * rec.t
        let nodedf = rec.nodeo + rec.nodedot * rec.t
        var argpm = argpdf
        var mm = xmdf
        let t2 = rec.t * rec.t
        var nodem = nodedf + rec.nodecf * t2
        var tempa = 1.0 - rec.cc1 * rec.t
        var tempe = rec.bstar * rec.cc4 * rec.t
        var templ = rec.t2cof * t2

        if rec.isimp != 1 {
            let delomg = rec.omgcof * rec.t
            let delmtemp = 1.0 + rec.eta * cos(xmdf)
            let delm = rec.xmcof
                * (delmtemp * delmtemp * delmtemp - rec.delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * rec.t
            let t4 = t3 * rec.t
            tempa = tempa - rec.d2 * t2 - rec.d3 * t3 - rec.d4 * t4
            tempe = tempe + rec.bstar * rec.cc5 * (sin(mm) - rec.sinmao)
            templ = templ + rec.t3cof * t3 + t4 * (rec.t4cof + rec.t * rec.t5cof)
        }

        var nm = rec.noUnkozai
        var em = rec.ecco
        var inclm = rec.inclo
        if rec.method == "d" {
            let ds = dspace(rec: &rec, t: rec.t, tc: rec.t,
                            em: em, argpm: argpm, inclm: inclm,
                            mm: mm, nm: nm, nodem: nodem)
            em = ds.em
            argpm = ds.argpm
            inclm = ds.inclm
            mm = ds.mm
            nm = ds.nm
            nodem = ds.nodem
        }

        if nm <= 0.0 {
            rec.error = 2
            return nil
        }

        let am = pow(rec.xke / nm, x2o3) * tempa * tempa
        nm = rec.xke / pow(am, 1.5)
        em = em - tempe

        if em >= 1.0 || em < -0.001 {
            rec.error = 1
            return nil
        }
        if em < 1.0e-6 { em = 1.0e-6 }
        mm = mm + rec.noUnkozai * templ
        let xlm = mm + argpm + nodem
        let emsq = em * em

        // Reference: truncating semantics for nodem, floored for the rest.
        nodem = nodem.truncatingRemainder(dividingBy: twopi)
        argpm = fmodPos(argpm, twopi)
        let xlmN = fmodPos(xlm, twopi)
        mm = fmodPos(xlmN - argpm - nodem, twopi)

        // Singly-averaged mean elements, recovered for inspection.
        rec.am = am
        rec.em = em
        rec.im = inclm
        rec.Om = nodem
        rec.om = argpm
        rec.mm = mm
        rec.nm = nm

        let sinim = sin(inclm)
        let cosim = cos(inclm)

        var ep = em
        var xincp = inclm
        var argpp = argpm
        var nodep = nodem
        var mp = mm
        var sinip = sinim
        var cosip = cosim
        if rec.method == "d" {
            let dp = dpper(rec: &rec, inclo: rec.inclo, init: "n",
                           ep: ep, inclp: xincp, nodep: nodep,
                           argpp: argpp, mp: mp,
                           opsmode: rec.operationmode)
            ep = dp.ep
            xincp = dp.inclp
            nodep = dp.nodep
            argpp = dp.argpp
            mp = dp.mp
            if xincp < 0.0 {
                xincp = -xincp
                nodep = nodep + Double.pi
                argpp = argpp - Double.pi
            }
            if ep < 0.0 || ep > 1.0 {
                rec.error = 3
                return nil
            }
        }

        if rec.method == "d" {
            sinip = sin(xincp)
            cosip = cos(xincp)
            rec.aycof = -0.5 * rec.j3oj2 * sinip
            if abs(cosip + 1.0) > 1.5e-12 {
                rec.xlcof = -0.25 * rec.j3oj2 * sinip
                    * (3.0 + 5.0 * cosip) / (1.0 + cosip)
            } else {
                rec.xlcof = -0.25 * rec.j3oj2 * sinip
                    * (3.0 + 5.0 * cosip) / temp4
            }
        }

        let axnl = ep * cos(argpp)
        let tempA = 1.0 / (am * (1.0 - ep * ep))
        let aynl = ep * sin(argpp) + tempA * rec.aycof
        let xl = mp + argpp + nodep + tempA * rec.xlcof * axnl

        // Solve Kepler's equation.
        let u = fmodPos(xl - nodep, twopi)
        var eo1 = u
        var tem5 = 9999.9
        var ktr = 1
        while abs(tem5) >= 1.0e-12 && ktr <= 10 {
            let sineo1 = sin(eo1)
            let coseo1 = cos(eo1)
            tem5 = 1.0 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 {
                tem5 = tem5 > 0.0 ? 0.95 : -0.95
            }
            eo1 = eo1 + tem5
            ktr = ktr + 1
        }

        let coseo1 = cos(eo1)
        let sineo1 = sin(eo1)
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1.0 - el2)
        if pl < 0.0 {
            rec.error = 4
            return nil
        }

        let rl = am * (1.0 - ecose)
        let rdotl = sqrt(am) * esine / rl
        let rvdotl = sqrt(pl) / rl
        let betal = sqrt(1.0 - el2)
        let tempB = esine / (1.0 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * tempB)
        let cosu = am / rl * (coseo1 - axnl + aynl * tempB)
        let su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1.0 - 2.0 * sinu * sinu
        let tempC = 1.0 / pl
        let temp1 = 0.5 * rec.j2 * tempC
        let temp2 = temp1 * tempC

        if rec.method == "d" {
            let cosisq = cosip * cosip
            rec.con41 = 3.0 * cosisq - 1.0
            rec.x1mth2 = 1.0 - cosisq
            rec.x7thm1 = 7.0 * cosisq - 1.0
        }

        let mrt = rl * (1.0 - 1.5 * temp2 * betal * rec.con41)
            + 0.5 * temp1 * rec.x1mth2 * cos2u
        let suAdj = su - 0.25 * temp2 * rec.x7thm1 * sin2u
        let xnode = nodep + 1.5 * temp2 * cosip * sin2u
        let xinc = xincp + 1.5 * temp2 * cosip * sinip * cos2u
        let mvt = rdotl - nm * temp1 * rec.x1mth2 * sin2u / rec.xke
        let rvdot = rvdotl + nm * temp1
            * (rec.x1mth2 * cos2u + 1.5 * rec.con41) / rec.xke

        let sinsu = sin(suAdj)
        let cossu = cos(suAdj)
        let snod = sin(xnode)
        let cnod = cos(xnode)
        let sini = sin(xinc)
        let cosi = cos(xinc)
        let xmx = -snod * cosi
        let xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu
        let uy = xmy * sinsu + snod * cossu
        let uz = sini * sinsu
        let vx = xmx * cossu - cnod * sinsu
        let vy = xmy * cossu - snod * sinsu
        let vz = sini * cossu

        let mr = mrt * rec.radiusearthkm
        let r = SIMD3<Double>(mr * ux, mr * uy, mr * uz)
        let v = SIMD3<Double>((mvt * ux + rvdot * vx) * vkmpersec,
                              (mvt * uy + rvdot * vy) * vkmpersec,
                              (mvt * uz + rvdot * vz) * vkmpersec)
        if mrt < 1.0 {
            rec.error = 6
        }
        return SatelliteState(position: r, velocity: v)
    }

    // MARK: Public API

    /// Propagate a TLE to minutes since its epoch. Returns
    /// `.invalid` (NaN components) if the propagation fails.
    static func propagate(tle: TLE,
                          at minutesSinceEpoch: Double) -> SatelliteState {
        var rec = initialize(from: tle)
        if let state = propagateCore(&rec, tsince: minutesSinceEpoch) {
            return state
        }
        return .invalid
    }

    /// Efficient path: initialize once, then propagate the same record
    /// many times (used by the pass scanner).
    static func propagate(_ rec: inout SGP4Record,
                          tsince: Double) -> SatelliteState? {
        propagateCore(&rec, tsince: tsince)
    }
}

// MARK: - Frames & visibility

/// TEME -> topocentric alt/az and the satellite-sunlit test.
enum SatelliteMath {
    /// Topocentric altitude/azimuth (degrees, az eastward from north)
    /// for a TEME position vector (km) and a geodetic observer.
    ///
    /// Chain: TEME -> pseudo-Earth-fixed via the GMST rotation (Vallado's
    /// standard approximation; polar motion and nutation ignored,
    /// sub-arcminute) -> SEZ topocentric with a WGS-84 geodetic observer
    /// at sea level.
    static func altAz(ofTeme rTeme: SIMD3<Double>, julianDate jd: Double,
                      lat: Double, lon: Double) -> (alt: Double, az: Double) {
        let theta = AstroMath.gmstDegrees(julianDate: jd) * AstroMath.deg2rad
        let c = cos(theta)
        let s = sin(theta)
        // R3(theta): PEF = R3 * TEME.
        let x = c * rTeme.x + s * rTeme.y
        let y = -s * rTeme.x + c * rTeme.y
        let z = rTeme.z

        // Observer ECEF, WGS-84 geodetic, h = 0.
        let latR = lat * AstroMath.deg2rad
        let lonR = lon * AstroMath.deg2rad
        let a = 6378.137
        let f = 1.0 / 298.257223563
        let e2 = f * (2.0 - f)
        let slat = sin(latR)
        let n = a / sqrt(1.0 - e2 * slat * slat)
        let ox = n * cos(latR) * cos(lonR)
        let oy = n * cos(latR) * sin(lonR)
        let oz = n * (1.0 - e2) * slat

        let rx = x - ox
        let ry = y - oy
        let rz = z - oz
        let clat = cos(latR)
        let slon = sin(lonR)
        let clon = cos(lonR)
        let east = -slon * rx + clon * ry
        let north = -slat * clon * rx - slat * slon * ry + clat * rz
        let up = clat * clon * rx + clat * slon * ry + slat * rz
        let range = sqrt(rx * rx + ry * ry + rz * rz)
        let alt = asin(max(-1.0, min(1.0, up / range))) * AstroMath.rad2deg
        var az = atan2(east, north) * AstroMath.rad2deg
        if az < 0 { az += 360.0 }
        return (alt, az)
    }

    /// Cylindrical Earth-shadow test: true when the satellite is sunlit.
    /// Approximation: the shadow is treated as a cylinder of Earth radius
    /// (penumbra ignored), and the sun direction comes from AstroMath's
    /// low-precision model, whose frame differs from TEME by <0.5 deg --
    /// plenty for a lit/shadow boolean.
    static func isSunlit(teme: SIMD3<Double>,
                         julianDate jd: Double) -> Bool {
        let sun = AstroMath.sunRaDec(julianDate: jd)
        let raR = sun.ra * AstroMath.deg2rad
        let decR = sun.dec * AstroMath.deg2rad
        let shat = SIMD3<Double>(cos(decR) * cos(raR),
                                 cos(decR) * sin(raR),
                                 sin(decR))
        let d = teme.x * shat.x + teme.y * shat.y + teme.z * shat.z
        if d >= 0 { return true }  // day side of Earth
        let r2 = teme.x * teme.x + teme.y * teme.y + teme.z * teme.z
        let perp2 = r2 - d * d
        let earthR = 6378.137
        return perp2 >= earthR * earthR
    }

    /// Sun altitude (degrees) for the visibility check.
    static func sunAltitude(julianDate jd: Double,
                            lat: Double, lon: Double) -> Double {
        let sun = AstroMath.sunRaDec(julianDate: jd)
        return AstroMath.altAz(ra: sun.ra, dec: sun.dec, julianDate: jd,
                               lat: lat, lon: lon).alt
    }
}

// MARK: - SatellitePass

/// One above-horizon pass of a satellite.
struct SatellitePass: Identifiable {
    let id = UUID()
    let name: String
    let rise: Date
    let culmination: Date
    let set: Date
    let maxElevation: Double
    /// True when the sky is dark enough (Sun below -6 deg) AND the
    /// satellite itself is sunlit at culmination.
    let visible: Bool
    /// When `visible` is false, true means the Sun (not Earth's shadow)
    /// is the reason -- i.e. a daylight pass.
    let daylight: Bool
}

// MARK: - SatelliteTracker

/// Loads TLEs (bundled snapshot + CelesTrak refresh) and predicts
/// satellite passes. All heavy work runs off the main thread.
@MainActor
final class SatelliteTracker: ObservableObject {
    @Published private(set) var passes: [SatellitePass] = []
    @Published private(set) var tleAgeDays: Double?
    @Published private(set) var satelliteCount = 0
    @Published private(set) var hasData = false
    @Published private(set) var isComputing = false
    @Published private(set) var lastRefreshError: String?

    private struct Entry {
        let name: String
        var rec: SGP4Record
        let epochJD: Double
        /// Split epoch for the reference's precision-preserving
        /// `((jdWhole - jdsatepoch) + (jdFrac - jdsatepochF)) * 1440`.
        let jdsatepoch: Double
        let jdsatepochF: Double
    }
    private var entries: [Entry] = []

    static let stationsURL = URL(
        string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=tle")!
    static let visualURL = URL(
        string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=visual&FORMAT=tle")!

    init() {
        loadBundled()
    }

    // MARK: TLE loading

    /// Parse 3-line TLE sets from raw text into initialized records.
    private func parseTLEs(_ text: String) -> [Entry] {
        let lines = text.components(separatedBy: .newlines)
        var out: [Entry] = []
        var i = 0
        while i + 2 < lines.count {
            let name = lines[i]
            let l1 = i + 1 < lines.count ? lines[i + 1] : ""
            let l2 = i + 2 < lines.count ? lines[i + 2] : ""
            if let tle = TLE(name: name, line1: l1, line2: l2) {
                out.append(Entry(name: tle.name,
                                 rec: SGP4.initialize(from: tle),
                                 epochJD: tle.epochJulianDate,
                                 jdsatepoch: tle.jdsatepoch,
                                 jdsatepochF: tle.jdsatepochF))
            }
            i += 3
        }
        return out
    }

    private func adopt(_ newEntries: [Entry]) {
        guard !newEntries.isEmpty else { return }
        entries = newEntries
        satelliteCount = newEntries.count
        hasData = true
        let now = Date()
        let oldest = newEntries.map { now.timeIntervalSince(
            Date(timeIntervalSince1970: ($0.epochJD - 2440587.5) * 86400.0))
        }.max() ?? 0
        tleAgeDays = oldest / 86400.0
        lastRefreshError = nil
    }

    /// Load the bundled snapshot shipped in Resources/tle.txt.
    func loadBundled() {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "tle", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        adopt(parseTLEs(text))
    }

    /// Refresh TLEs from CelesTrak (10 s timeout). Both the stations and
    /// visual groups must download and parse; on any failure the current
    /// snapshot is kept and the error is reported.
    func refreshFromNetwork() async {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        do {
            async let stations = session.data(from: Self.stationsURL)
            async let visual = session.data(from: Self.visualURL)
            let (sData, _) = try await stations
            let (vData, _) = try await visual
            guard let sText = String(data: sData, encoding: .utf8),
                  let vText = String(data: vData, encoding: .utf8)
            else { throw TLEError.badEncoding }
            let combined = sText + "\n" + vText
            let parsed = parseTLEs(combined)
            guard !parsed.isEmpty else { throw TLEError.noSatellites }
            adopt(parsed)
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    // MARK: Pass prediction

    /// Predict passes above 10 deg max elevation over the next 48 h.
    /// Scans in 30 s steps on a background thread, then refines rise,
    /// set, and culmination times.
    func predictPasses(latitude: Double, longitude: Double) async {
        let entries = self.entries
        guard !entries.isEmpty else { return }
        isComputing = true
        let now = Date()
        let result = await Task.detached(priority: .userInitiated) {
            Self.computePasses(entries: entries,
                               lat: latitude, lon: longitude, now: now)
        }.value
        passes = result
        isComputing = false
    }

    /// Pure computation: called off the main thread.
    private static func computePasses(entries: [Entry], lat: Double,
                                      lon: Double, now: Date)
        -> [SatellitePass]
    {
        var out: [SatellitePass] = []
        for entry in entries {
            out += scanEntry(entry: entry, lat: lat, lon: lon, now: now)
        }
        return out.sorted { $0.rise < $1.rise }
    }

    /// Scan one satellite for passes over the next 48 h in 30 s steps.
    private static func scanEntry(entry: Entry, lat: Double,
                                  lon: Double, now: Date) -> [SatellitePass] {
        var out: [SatellitePass] = []
        var rec = entry.rec
        let horizon: TimeInterval = 48 * 3600
        let step: TimeInterval = 30
        let n = Int(horizon / step)

        // Elevation at a moment; nil when propagation fails.
        func elevation(at t: Date) -> (el: Double, pos: SIMD3<Double>)? {
            let jd = AstroMath.julianDate(t)
            // Split JD exactly like the reference's (jd, fr) pair so the
            // epoch fraction keeps full precision in `tsince`.
            let jdWhole = floor(jd - 0.5) + 0.5
            let jdFrac = jd - jdWhole
            let tsince = ((jdWhole - entry.jdsatepoch)
                          + (jdFrac - entry.jdsatepochF)) * 1440.0
            guard let st = SGP4.propagate(&rec, tsince: tsince)
            else { return nil }
            let top = SatelliteMath.altAz(ofTeme: st.position,
                                          julianDate: jd,
                                          lat: lat, lon: lon)
            return (top.alt, st.position)
        }

        // Bisect the 0-degree elevation crossing between t0 and t1.
        func refineCrossing(t0: Date, t1: Date, rising: Bool) -> Date {
            var lo = t0
            var hi = t1
            for _ in 0..<24 {
                let mid = Date(timeIntervalSince1970:
                    (lo.timeIntervalSince1970 + hi.timeIntervalSince1970) / 2)
                guard let m = elevation(at: mid) else { break }
                if (rising && m.el <= 0) || (!rising && m.el > 0) {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            return Date(timeIntervalSince1970:
                (lo.timeIntervalSince1970 + hi.timeIntervalSince1970) / 2)
        }

        // Ternary-search the elevation maximum between t0 and t1.
        func refineMaximum(t0: Date, t1: Date)
            -> (date: Date, el: Double, pos: SIMD3<Double>)
        {
            var lo = t0.timeIntervalSince1970
            var hi = t1.timeIntervalSince1970
            for _ in 0..<48 {
                let m1 = lo + (hi - lo) / 3
                let m2 = hi - (hi - lo) / 3
                let e1 = elevation(at: Date(timeIntervalSince1970: m1))?.el
                    ?? -90
                let e2 = elevation(at: Date(timeIntervalSince1970: m2))?.el
                    ?? -90
                if e1 < e2 { lo = m1 } else { hi = m2 }
            }
            let bt = (lo + hi) / 2
            if let b = elevation(at: Date(timeIntervalSince1970: bt)) {
                return (Date(timeIntervalSince1970: bt), b.el, b.pos)
            }
            return (Date(timeIntervalSince1970: bt), -90,
                    SIMD3<Double>(0, 0, 0))
        }

        var riseT: Date?
        var maxEl = -90.0
        var maxPos = SIMD3<Double>(0, 0, 0)

        func closePass(setT: Date) {
            guard let rT = riseT, maxEl > 10.0 else { return }
            let rise = refineCrossing(t0: rT.addingTimeInterval(-step),
                                      t1: rT, rising: true)
            let set = refineCrossing(t0: setT.addingTimeInterval(-step),
                                     t1: setT, rising: false)
            let culm = refineMaximum(t0: rise, t1: set)
            let jd = AstroMath.julianDate(culm.date)
            let sunAlt = SatelliteMath.sunAltitude(julianDate: jd,
                                                   lat: lat, lon: lon)
            let lit = SatelliteMath.isSunlit(teme: culm.pos, julianDate: jd)
            let visible = sunAlt < -6.0 && lit
            out.append(SatellitePass(
                name: entry.name, rise: rise, culmination: culm.date,
                set: set, maxElevation: culm.el, visible: visible,
                daylight: !visible && sunAlt >= -6.0))
        }

        var prevT: Date?
        var prevEl: Double?
        var i = 0
        while i <= n {
            let t = now.addingTimeInterval(Double(i) * step)
            if let cur = elevation(at: t) {
                if let pEl = prevEl {
                    if riseT == nil && pEl <= 0 && cur.el > 0 {
                        riseT = t
                        maxEl = cur.el
                        maxPos = cur.pos
                    } else if riseT != nil {
                        if cur.el > maxEl {
                            maxEl = cur.el
                            maxPos = cur.pos
                        }
                        if cur.el <= 0 {
                            closePass(setT: t)
                            riseT = nil
                            maxEl = -90.0
                        }
                    }
                } else if cur.el > 0 {
                    // Already up at the window start.
                    riseT = t
                    maxEl = cur.el
                    maxPos = cur.pos
                }
                prevEl = cur.el
                prevT = t
            } else {
                // Propagation failure: close any open pass at last good time.
                if riseT != nil, let pT = prevT {
                    closePass(setT: pT)
                }
                riseT = nil
                prevEl = nil
                prevT = nil
            }
            i += 1
        }
        // Pass still open at the window end.
        if riseT != nil {
            closePass(setT: now.addingTimeInterval(horizon))
        }
        return out
    }
}

enum TLEError: LocalizedError {
    case badEncoding
    case noSatellites
    var errorDescription: String? {
        switch self {
        case .badEncoding: return "The TLE download was not valid text."
        case .noSatellites: return "No valid satellite entries were found."
        }
    }
}
