#!/usr/bin/env python3
"""Validate the Swift SGP4 port in ../Sources/AstroTonight/Satellites.swift.

Method: this file is a MECHANICAL Python translation of the Swift code
(same formulas, same order, same constants, same branches). It is then
checked against an independent truth table produced by python-sgp4
(C++-accelerated Vallado implementation) for 3 satellites x 5 timestamps.

Any transcription slip in EITHER direction (Python->Swift when writing
the port, or Swift->Python here) breaks the 1e-6 km agreement gate, so
passing means the Swift logic is bit-near-identical to the reference.

Also validates the TEME->topocentric chain against Skyfield (independent
implementation) and sanity-checks the cylindrical shadow test.
"""
import json
import math
import sys
import datetime

PI = math.pi
TWOPI = 2.0 * PI
DEG2RAD = PI / 180.0
RAD2DEG = 180.0 / PI

# ---------------------------------------------------------------------------
# Swift: SGP4.fmodPos / truncatingRemainder


def fmod_pos(x, m):
    r = math.fmod(x, m)
    return r + m if r < 0 else r


# ---------------------------------------------------------------------------
# Swift: struct TLE (init?)


class TLE:
    def __init__(self, name, line1, line2):
        l1 = list(line1.strip())
        l2 = list(line2.strip())
        ok = (
            len(l1) >= 69 and len(l2) >= 69
            and l1[0] == "1" and l1[1] == " "
            and l1[8] == " " and l1[23] == "." and l1[32] == " "
            and l1[34] == "." and l1[43] == " " and l1[52] == " "
            and l1[61] == " " and l1[63] == " "
            and l2[0] == "2" and l2[1] == " "
            and l2[7] == " " and l2[11] == "." and l2[16] == " "
            and l2[20] == "." and l2[25] == " " and l2[33] == " "
            and l2[37] == "." and l2[42] == " " and l2[46] == "."
            and l2[51] == " "
            and "".join(l1[2:7]) == "".join(l2[2:7])
        )
        if not ok:
            raise ValueError("bad TLE columns")

        def field(c, r):
            return "".join(c[r]).strip()

        def exp_field(c, sign_at, digits, exp):
            sign = "-" if c[sign_at] == "-" else ""
            mantissa = float(sign + "." + "".join(c[digits]))
            e = int(field(c, exp))
            return mantissa * (10.0 ** e)

        xpdotp = 1440.0 / TWOPI
        two_digit_year = int(field(l1, slice(18, 20)))
        epoch_days = float(field(l1, slice(20, 32)))
        ndot_raw = float(field(l1, slice(33, 43)))
        nddot = exp_field(l1, 44, slice(45, 50), slice(50, 52))
        bstar = exp_field(l1, 53, slice(54, 59), slice(59, 61))
        inclo = float(field(l2, slice(8, 16)))
        nodeo = float(field(l2, slice(17, 25)))
        ecco = float("0." + "".join(l2[26:33]).replace(" ", "0"))
        argpo = float(field(l2, slice(34, 42)))
        mo = float(field(l2, slice(43, 51)))
        no_kozai_revday = float(field(l2, slice(52, 63)))
        assert ecco >= 0.0

        year = two_digit_year + 2000 if two_digit_year < 57 \
            else two_digit_year + 1900
        day_int = math.floor(epoch_days)
        frac = epoch_days - day_int
        jd_epoch = float(year * 365 + (year - 1) // 4) + day_int + 1721044.5
        jd_epoch_f = round(frac * 1e8) / 1e8

        self.name = name.strip()
        self.epoch_jd = jd_epoch + jd_epoch_f
        self.jdsatepoch = jd_epoch
        self.jdsatepochF = jd_epoch_f
        self.bstar = bstar
        self.ndot = ndot_raw / (xpdotp * 1440.0)
        self.nddot = nddot / (xpdotp * 1440.0 * 1440.0)
        self.ecco = ecco
        self.argpo = argpo * DEG2RAD
        self.inclo = inclo * DEG2RAD
        self.mo = mo * DEG2RAD
        self.no_kozai = no_kozai_revday / xpdotp
        self.nodeo = nodeo * DEG2RAD


# ---------------------------------------------------------------------------
# Swift: struct SGP4Record


class Rec:
    def __init__(self):
        self.bstar = 0.0; self.ndot = 0.0; self.nddot = 0.0
        self.ecco = 0.0; self.argpo = 0.0; self.inclo = 0.0
        self.mo = 0.0; self.no_kozai = 0.0; self.nodeo = 0.0
        self.tumin = 0.0; self.mu = 0.0; self.radiusearthkm = 0.0
        self.xke = 0.0; self.j2 = 0.0; self.j3 = 0.0; self.j4 = 0.0
        self.j3oj2 = 0.0
        self.jdsatepoch = 0.0; self.jdsatepochF = 0.0
        self.t = 0.0; self.error = 0
        self.method = "n"; self.operationmode = "i"; self.initFlag = "y"
        self.isimp = 0; self.irez = 0
        self.a = 0.0; self.alta = 0.0; self.altp = 0.0
        self.am = 0.0; self.em = 0.0; self.im = 0.0
        self.Om = 0.0; self.om = 0.0; self.mm = 0.0; self.nm = 0.0
        self.no_unkozai = 0.0
        self.argpdot = 0.0; self.nodedot = 0.0; self.mdot = 0.0
        self.gsto = 0.0; self.con41 = 0.0
        self.x1mth2 = 0.0; self.x7thm1 = 0.0
        self.aycof = 0.0; self.xlcof = 0.0; self.xmcof = 0.0
        self.omgcof = 0.0; self.nodecf = 0.0
        self.t2cof = 0.0; self.t3cof = 0.0; self.t4cof = 0.0; self.t5cof = 0.0
        self.cc1 = 0.0; self.cc4 = 0.0; self.cc5 = 0.0
        self.d2 = 0.0; self.d3 = 0.0; self.d4 = 0.0
        self.delmo = 0.0; self.sinmao = 0.0; self.eta = 0.0
        for k in ("d2201 d2211 d3210 d3222 d4410 d4422 d5220 d5232 d5421 "
                  "d5433 dedt del1 del2 del3 didt dmdt dnodt domdt e3 ee2 "
                  "peo pgho pho pinco plo se2 se3 sgh2 sgh3 sgh4 sh2 sh3 "
                  "si2 si3 sl2 sl3 sl4 xgh2 xgh3 xgh4 xh2 xh3 xi2 xi3 "
                  "xl2 xl3 xl4 xlamo xli xni xfact zmol zmos atime").split():
            setattr(self, k, 0.0)


class DSComLocals:
    def __init__(self):
        for k in ("snodm cnodm sinim cosim sinomm cosomm day em emsq gam "
                  "rtemsq s1 s2 s3 s4 s5 s6 s7 ss1 ss2 ss3 ss4 ss5 ss6 ss7 "
                  "sz1 sz2 sz3 sz11 sz12 sz13 sz21 sz22 sz23 sz31 sz32 sz33 "
                  "nm z1 z2 z3 z11 z12 z13 z21 z22 z23 z31 z32 z33").split():
            setattr(self, k, 0.0)


def wgs72():
    mu = 398600.8
    radiusearthkm = 6378.135
    xke = 60.0 / math.sqrt(radiusearthkm ** 3 / mu)
    j2 = 0.001082616
    j3 = -0.00000253881
    j4 = -0.00000165597
    return (1.0 / xke, mu, radiusearthkm, xke, j2, j3, j4, j3 / j2)


def gstime(jdut1):
    tut1 = (jdut1 - 2451545.0) / 36525.0
    temp = (-6.2e-6 * tut1 ** 3 + 0.093104 * tut1 ** 2
            + (876600.0 * 3600 + 8640184.812866) * tut1 + 67310.54841)
    temp = fmod_pos(temp * DEG2RAD / 240.0, TWOPI)
    if temp < 0.0:
        temp += TWOPI
    return temp


def initl(xke, j2, ecco, epoch, inclo, no, opsmode):
    x2o3 = 2.0 / 3.0
    eccsq = ecco * ecco
    omeosq = 1.0 - eccsq
    rteosq = math.sqrt(omeosq)
    cosio = math.cos(inclo)
    cosio2 = cosio * cosio
    ak = (xke / no) ** x2o3
    d1 = 0.75 * j2 * (3.0 * cosio2 - 1.0) / (rteosq * omeosq)
    del_ = d1 / (ak * ak)
    adel = ak * (1.0 - del_ ** 2 - del_ * (1.0 / 3.0 + 134.0 * del_**2 / 81.0))
    del_ = d1 / (adel * adel)
    no_out = no / (1.0 + del_)
    ao = (xke / no_out) ** x2o3
    sinio = math.sin(inclo)
    po = ao * omeosq
    con42 = 1.0 - 5.0 * cosio2
    con41 = -con42 - cosio2 - cosio2
    ainv = 1.0 / ao
    posq = po * po
    rp = ao * (1.0 - ecco)
    if opsmode == "a":
        ts70 = epoch - 7305.0
        ds70 = math.floor(ts70 + 1.0e-8)
        tfrac = ts70 - ds70
        c1 = 1.72027916940703639e-2
        thgr70 = 1.7321343856509374
        fk5r = 5.07551419432269442e-15
        c1p2p = c1 + TWOPI
        g = fmod_pos(thgr70 + c1 * ds70 + c1p2p * tfrac
                     + ts70 * ts70 * fk5r, TWOPI)
        if g < 0.0:
            g += TWOPI
        gsto = g
    else:
        gsto = gstime(epoch + 2433281.5)
    return (no_out, "n", ainv, ao, con41, con42, cosio, cosio2,
            eccsq, omeosq, posq, rp, rteosq, sinio, gsto)

# ---------------------------------------------------------------------------
# Swift: SGP4.dpper


def dpper(rec, inclo, initFlag, ep, inclp, nodep, argpp, mp, opsmode):
    zns = 1.19459e-5
    zes = 0.01675
    znl = 1.5835218e-4
    zel = 0.05490

    zm = rec.zmos + zns * rec.t
    if initFlag == "y":
        zm = rec.zmos
    zf = zm + 2.0 * zes * math.sin(zm)
    sinzf = math.sin(zf)
    f2 = 0.5 * sinzf * sinzf - 0.25
    f3 = -0.5 * sinzf * math.cos(zf)
    ses = rec.se2 * f2 + rec.se3 * f3
    sis = rec.si2 * f2 + rec.si3 * f3
    sls = rec.sl2 * f2 + rec.sl3 * f3 + rec.sl4 * sinzf
    sghs = rec.sgh2 * f2 + rec.sgh3 * f3 + rec.sgh4 * sinzf
    shs = rec.sh2 * f2 + rec.sh3 * f3
    zm = rec.zmol + znl * rec.t
    if initFlag == "y":
        zm = rec.zmol
    zf = zm + 2.0 * zel * math.sin(zm)
    sinzf = math.sin(zf)
    f2 = 0.5 * sinzf * sinzf - 0.25
    f3 = -0.5 * sinzf * math.cos(zf)
    sel = rec.ee2 * f2 + rec.e3 * f3
    sil = rec.xi2 * f2 + rec.xi3 * f3
    sll = rec.xl2 * f2 + rec.xl3 * f3 + rec.xl4 * sinzf
    sghl = rec.xgh2 * f2 + rec.xgh3 * f3 + rec.xgh4 * sinzf
    shll = rec.xh2 * f2 + rec.xh3 * f3
    pe = ses + sel
    pinc = sis + sil
    pl = sls + sll
    pgh = sghs + sghl
    ph = shs + shll

    ep_out, inclp_out, nodep_out, argpp_out, mp_out = ep, inclp, nodep, argpp, mp

    if initFlag == "n":
        pe -= rec.peo
        pinc -= rec.pinco
        pl_adj = pl - rec.plo
        pgh -= rec.pgho
        ph -= rec.pho
        inclp_out += pinc
        ep_out += pe
        sinip = math.sin(inclp_out)
        cosip = math.cos(inclp_out)

        if inclp_out >= 0.2:
            ph /= sinip
            pgh -= cosip * ph
            argpp_out += pgh
            nodep_out += ph
            mp_out += pl_adj
        else:
            sinop = math.sin(nodep_out)
            cosop = math.cos(nodep_out)
            alfdp = sinip * sinop
            betdp = sinip * cosop
            dalf = ph * cosop + pinc * cosip * sinop
            dbet = -ph * sinop + pinc * cosip * cosop
            alfdp += dalf
            betdp += dbet
            nodep_out = math.fmod(nodep_out, TWOPI)
            if nodep_out < 0.0 and opsmode == "a":
                nodep_out += TWOPI
            xls = (mp_out + argpp_out + pl_adj + pgh
                   + (cosip - pinc * sinip) * nodep_out)
            xnoh = nodep_out
            nodep_out = math.atan2(alfdp, betdp)
            if nodep_out < 0.0 and opsmode == "a":
                nodep_out += TWOPI
            if abs(xnoh - nodep_out) > PI:
                if nodep_out < xnoh:
                    nodep_out += TWOPI
                else:
                    nodep_out -= TWOPI
            mp_out += pl_adj
            argpp_out = xls - mp_out - cosip * nodep_out

    return (ep_out, inclp_out, nodep_out, argpp_out, mp_out)


# ---------------------------------------------------------------------------
# Swift: SGP4.dscom


def dscom(epoch, ep, argpp, tc, inclp, nodep, np, rec):
    zes = 0.01675
    zel = 0.05490
    c1ss = 2.9864797e-6
    c1l = 4.7968065e-7
    zsinis = 0.39785416
    zcosis = 0.91744867
    zcosgs = 0.1945905
    zsings = -0.98088458

    L = DSComLocals()
    L.nm = np
    L.em = ep
    L.snodm = math.sin(nodep)
    L.cnodm = math.cos(nodep)
    L.sinomm = math.sin(argpp)
    L.cosomm = math.cos(argpp)
    L.sinim = math.sin(inclp)
    L.cosim = math.cos(inclp)
    L.emsq = L.em * L.em
    betasq = 1.0 - L.emsq
    L.rtemsq = math.sqrt(betasq)

    rec.peo = 0.0; rec.pinco = 0.0; rec.plo = 0.0
    rec.pgho = 0.0; rec.pho = 0.0
    day = epoch + 18261.5 + tc / 1440.0
    L.day = day
    xnodce = fmod_pos(4.5236020 - 9.2422029e-4 * day, TWOPI)
    stem = math.sin(xnodce)
    ctem = math.cos(xnodce)
    zcosil = 0.91375164 - 0.03568096 * ctem
    zsinil = math.sqrt(1.0 - zcosil * zcosil)
    zsinhl = 0.089683511 * stem / zsinil
    zcoshl = math.sqrt(1.0 - zsinhl * zsinhl)
    gam = 5.8351514 + 0.0019443680 * day
    L.gam = gam
    zx = 0.39785416 * stem / zsinil
    zy = zcoshl * ctem + 0.91744867 * zsinhl * stem
    zx = math.atan2(zx, zy)
    zx = gam + zx - xnodce
    zcosgl = math.cos(zx)
    zsingl = math.sin(zx)

    zcosg = zcosgs; zsing = zsings; zcosi = zcosis; zsini = zsinis
    zcosh = L.cnodm; zsinh = L.snodm
    cc = c1ss
    xnoi = 1.0 / L.nm

    for lsflg in (1, 2):
        a1 = zcosg * zcosh + zsing * zcosi * zsinh
        a3 = -zsing * zcosh + zcosg * zcosi * zsinh
        a7 = -zcosg * zsinh + zsing * zcosi * zcosh
        a8 = zsing * zsini
        a9 = zsing * zsinh + zcosg * zcosi * zcosh
        a10 = zcosg * zsini
        a2 = L.cosim * a7 + L.sinim * a8
        a4 = L.cosim * a9 + L.sinim * a10
        a5 = -L.sinim * a7 + L.cosim * a8
        a6 = -L.sinim * a9 + L.cosim * a10

        x1 = a1 * L.cosomm + a2 * L.sinomm
        x2 = a3 * L.cosomm + a4 * L.sinomm
        x3 = -a1 * L.sinomm + a2 * L.cosomm
        x4 = -a3 * L.sinomm + a4 * L.cosomm
        x5 = a5 * L.sinomm
        x6 = a6 * L.sinomm
        x7 = a5 * L.cosomm
        x8 = a6 * L.cosomm

        z31 = 12.0 * x1 * x1 - 3.0 * x3 * x3
        z32 = 24.0 * x1 * x2 - 6.0 * x3 * x4
        z33 = 12.0 * x2 * x2 - 3.0 * x4 * x4
        z1 = 3.0 * (a1 * a1 + a2 * a2) + z31 * L.emsq
        z2 = 6.0 * (a1 * a3 + a2 * a4) + z32 * L.emsq
        z3 = 3.0 * (a3 * a3 + a4 * a4) + z33 * L.emsq
        z11 = -6.0 * a1 * a5 + L.emsq * (-24.0 * x1 * x7 - 6.0 * x3 * x5)
        z12 = (-6.0 * (a1 * a6 + a3 * a5) + L.emsq
               * (-24.0 * (x2 * x7 + x1 * x8) - 6.0 * (x3 * x6 + x4 * x5)))
        z13 = -6.0 * a3 * a6 + L.emsq * (-24.0 * x2 * x8 - 6.0 * x4 * x6)
        z21 = 6.0 * a2 * a5 + L.emsq * (24.0 * x1 * x5 - 6.0 * x3 * x7)
        z22 = (6.0 * (a4 * a5 + a2 * a6) + L.emsq
               * (24.0 * (x2 * x5 + x1 * x6) - 6.0 * (x4 * x7 + x3 * x8)))
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

        if lsflg == 1:
            L.ss1, L.ss2, L.ss3, L.ss4 = s1, s2, s3, s4
            L.ss5, L.ss6, L.ss7 = s5, s6, s7
            L.sz1, L.sz2, L.sz3 = z1, z2, z3
            L.sz11, L.sz12, L.sz13 = z11, z12, z13
            L.sz21, L.sz22, L.sz23 = z21, z22, z23
            L.sz31, L.sz32, L.sz33 = z31, z32, z33
            zcosg = zcosgl; zsing = zsingl; zcosi = zcosil; zsini = zsinil
            zcosh = zcoshl * L.cnodm + zsinhl * L.snodm
            zsinh = L.snodm * zcoshl - L.cnodm * zsinhl
            cc = c1l

    L.s1, L.s2, L.s3, L.s4 = s1, s2, s3, s4
    L.s5, L.s6, L.s7 = s5, s6, s7
    L.z1, L.z2, L.z3 = z1, z2, z3
    L.z11, L.z12, L.z13 = z11, z12, z13
    L.z21, L.z22, L.z23 = z21, z22, z23
    L.z31, L.z32, L.z33 = z31, z32, z33

    rec.zmol = fmod_pos(4.7199672 + 0.22997150 * day - gam, TWOPI)
    rec.zmos = fmod_pos(6.2565837 + 0.017201977 * day, TWOPI)

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

# ---------------------------------------------------------------------------
# Swift: SGP4.dsinit


def dsinit(rec, com, ecco, eccsq, em, argpm, inclm, mm, nm, nodem,
           xpidot, t, tc, gsto, mo, mdot, no, nodeo, nodedot, argpo):
    q22 = 1.7891679e-6
    q31 = 2.1460748e-6
    q33 = 2.2123015e-7
    root22 = 1.7891679e-6
    root44 = 7.3636953e-9
    root54 = 2.1765803e-9
    rptim = 4.37526908801129966e-3
    root32 = 3.7393792e-7
    root52 = 1.1428639e-7
    x2o3 = 2.0 / 3.0
    znl = 1.5835218e-4
    zns = 1.19459e-5

    emL, argpmL, inclmL, mmL, nmL, nodemL = em, argpm, inclm, mm, nm, nodem
    emsqL = com.emsq

    irez = 0
    if 0.0034906585 < nmL < 0.0052359877:
        irez = 1
    if 8.26e-3 <= nmL <= 9.24e-3 and emL >= 0.5:
        irez = 2
    rec.irez = irez

    ses = com.ss1 * zns * com.ss5
    sis = com.ss2 * zns * (com.sz11 + com.sz13)
    sls = -zns * com.ss3 * (com.sz1 + com.sz3 - 14.0 - 6.0 * com.emsq)
    sghs = com.ss4 * zns * (com.sz31 + com.sz33 - 6.0)
    shs = -zns * com.ss2 * (com.sz21 + com.sz23)
    if inclmL < 5.2359877e-2 or inclmL > PI - 5.2359877e-2:
        shs = 0.0
    if com.sinim != 0.0:
        shs = shs / com.sinim
    sgs = sghs - com.cosim * shs

    dedt = ses + com.s1 * znl * com.s5
    didt = sis + com.s2 * znl * (com.z11 + com.z13)
    dmdt = sls - znl * com.s3 * (com.z1 + com.z3 - 14.0 - 6.0 * com.emsq)
    sghl = com.s4 * znl * (com.z31 + com.z33 - 6.0)
    shll = -znl * com.s2 * (com.z21 + com.z23)
    if inclmL < 5.2359877e-2 or inclmL > PI - 5.2359877e-2:
        shll = 0.0
    domdt = sgs + sghl
    dnodt = shs
    if com.sinim != 0.0:
        domdt -= com.cosim / com.sinim * shll
        dnodt += shll / com.sinim
    rec.dedt, rec.didt, rec.dmdt = dedt, didt, dmdt
    rec.dnodt, rec.domdt = dnodt, domdt

    theta = fmod_pos(gsto + tc * rptim, TWOPI)
    emL += dedt * t
    inclmL += didt * t
    argpmL += domdt * t
    nodemL += dnodt * t
    mmL += dmdt * t

    if irez != 0:
        aonv = (nmL / rec.xke) ** x2o3

        if irez == 2:
            cosisq = com.cosim * com.cosim
            emo = emL
            emL = ecco
            emsqo = emsqL
            emsqL = eccsq
            eoc = emL * emsqL
            g201 = -0.306 - (emL - 0.64) * 0.440
            if emL <= 0.65:
                g211 = 3.616 - 13.2470 * emL + 16.2900 * emsqL
                g310 = (-19.302 + 117.3900 * emL - 228.4190 * emsqL
                        + 156.5910 * eoc)
                g322 = (-18.9068 + 109.7927 * emL - 214.6334 * emsqL
                        + 146.5816 * eoc)
                g410 = (-41.122 + 242.6940 * emL - 471.0940 * emsqL
                        + 313.9530 * eoc)
                g422 = (-146.407 + 841.8800 * emL - 1629.014 * emsqL
                        + 1083.4350 * eoc)
                g520 = (-532.114 + 3017.977 * emL - 5740.032 * emsqL
                        + 3708.2760 * eoc)
            else:
                g211 = (-72.099 + 331.819 * emL - 508.738 * emsqL
                        + 266.724 * eoc)
                g310 = (-346.844 + 1582.851 * emL - 2415.925 * emsqL
                        + 1246.113 * eoc)
                g322 = (-342.585 + 1554.908 * emL - 2366.899 * emsqL
                        + 1215.972 * eoc)
                g410 = (-1052.797 + 4758.686 * emL - 7193.992 * emsqL
                        + 3651.957 * eoc)
                g422 = (-3581.690 + 16178.110 * emL - 24462.770 * emsqL
                        + 12422.520 * eoc)
                if emL > 0.715:
                    g520 = (-5149.66 + 29936.92 * emL - 54087.36 * emsqL
                            + 31324.56 * eoc)
                else:
                    g520 = (1464.74 - 4664.75 * emL + 3763.64 * emsqL)
            if emL < 0.7:
                g533 = (-919.22770 + 4988.6100 * emL - 9064.7700 * emsqL
                        + 5542.21 * eoc)
                g521 = (-822.71072 + 4568.6173 * emL - 8491.4146 * emsqL
                        + 5337.524 * eoc)
                g532 = (-853.66600 + 4690.2500 * emL - 8624.7700 * emsqL
                        + 5341.4 * eoc)
            else:
                g533 = (-37995.780 + 161616.52 * emL - 229838.20 * emsqL
                        + 109377.94 * eoc)
                g521 = (-51752.104 + 218913.95 * emL - 309468.16 * emsqL
                        + 146349.42 * eoc)
                g532 = (-40023.880 + 170470.89 * emL - 242699.48 * emsqL
                        + 115605.82 * eoc)

            sini2 = com.sinim * com.sinim
            f220 = 0.75 * (1.0 + 2.0 * com.cosim + cosisq)
            f221 = 1.5 * sini2
            f321 = 1.875 * com.sinim * (1.0 - 2.0 * com.cosim - 3.0 * cosisq)
            f322 = -1.875 * com.sinim * (1.0 + 2.0 * com.cosim - 3.0 * cosisq)
            f441 = 35.0 * sini2 * f220
            f442 = 39.3750 * sini2 * sini2
            f522 = (9.84375 * com.sinim
                    * (sini2 * (1.0 - 2.0 * com.cosim - 5.0 * cosisq)
                       + 0.33333333 * (-2.0 + 4.0 * com.cosim + 6.0 * cosisq)))
            f523 = (com.sinim
                    * (4.92187512 * sini2 * (-2.0 - 4.0 * com.cosim
                                            + 10.0 * cosisq)
                       + 6.56250012 * (1.0 + 2.0 * com.cosim - 3.0 * cosisq)))
            f542 = (29.53125 * com.sinim
                    * (2.0 - 8.0 * com.cosim
                       + cosisq * (-12.0 + 8.0 * com.cosim + 10.0 * cosisq)))
            f543 = (29.53125 * com.sinim
                    * (-2.0 - 8.0 * com.cosim
                       + cosisq * (12.0 + 8.0 * com.cosim - 10.0 * cosisq)))
            xno2 = nmL * nmL
            ainv2 = aonv * aonv
            temp1 = 3.0 * xno2 * ainv2
            temp = temp1 * root22
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
            rec.xlamo = fmod_pos(mo + nodeo + nodeo - theta - theta, TWOPI)
            rec.xfact = mdot + dmdt + 2.0 * (nodedot + dnodt - rptim) - no
            emL = emo
            emsqL = emsqo

        if irez == 1:
            g200 = 1.0 + emsqL * (-2.5 + 0.8125 * emsqL)
            g310 = 1.0 + 2.0 * emsqL
            g300 = 1.0 + emsqL * (-6.0 + 6.60937 * emsqL)
            f220 = 0.75 * (1.0 + com.cosim) * (1.0 + com.cosim)
            f311 = (0.9375 * com.sinim * com.sinim * (1.0 + 3.0 * com.cosim)
                    - 0.75 * (1.0 + com.cosim))
            f330 = 1.0 + com.cosim
            f330 = 1.875 * f330 * f330 * f330
            del1 = 3.0 * nmL * nmL * aonv * aonv
            del2 = 2.0 * del1 * f220 * g200 * q22
            del3 = 3.0 * del1 * f330 * g300 * q33 * aonv
            del1 = del1 * f311 * g310 * q31 * aonv
            rec.del1, rec.del2, rec.del3 = del1, del2, del3
            rec.xlamo = fmod_pos(mo + nodeo + argpo - theta, TWOPI)
            rec.xfact = mdot + xpidot - rptim + dmdt + domdt + dnodt - no

        rec.xli = rec.xlamo
        rec.xni = no
        rec.atime = 0.0
        nmL = no

# ---------------------------------------------------------------------------
# Swift: SGP4.dspace


def dspace(rec, t, tc, em, argpm, inclm, mm, nm, nodem):
    fasx2 = 0.13130908
    fasx4 = 2.8843198
    fasx6 = 0.37448087
    g22 = 5.7686396
    g32 = 0.95240898
    g44 = 1.8014998
    g52 = 1.0508330
    g54 = 4.4108898
    rptim = 4.37526908801129966e-3
    stepp = 720.0
    stepn = -720.0
    step2 = 259200.0

    theta = fmod_pos(rec.gsto + tc * rptim, TWOPI)
    emL = em + rec.dedt * t
    inclmL = inclm + rec.didt * t
    argpmL = argpm + rec.domdt * t
    nodemL = nodem + rec.dnodt * t
    mmL = mm + rec.dmdt * t
    nmL = nm

    if rec.irez != 0:
        if rec.atime == 0.0 or t * rec.atime <= 0.0 \
                or abs(t) < abs(rec.atime):
            rec.atime = 0.0
            rec.xni = rec.no_unkozai
            rec.xli = rec.xlamo
        delt = stepp if t > 0.0 else stepn

        iretn = 381
        ft = 0.0
        xndt = xldot = xnddt = 0.0
        while iretn == 381:
            if rec.irez != 2:
                xndt = (rec.del1 * math.sin(rec.xli - fasx2)
                        + rec.del2 * math.sin(2.0 * (rec.xli - fasx4))
                        + rec.del3 * math.sin(3.0 * (rec.xli - fasx6)))
                xldot = rec.xni + rec.xfact
                xnddt = (rec.del1 * math.cos(rec.xli - fasx2)
                         + 2.0 * rec.del2 * math.cos(2.0 * (rec.xli - fasx4))
                         + 3.0 * rec.del3 * math.cos(3.0 * (rec.xli - fasx6)))
                xnddt = xnddt * xldot
            else:
                xomi = rec.argpo + rec.argpdot * rec.atime
                x2omi = xomi + xomi
                x2li = rec.xli + rec.xli
                xndt = (rec.d2201 * math.sin(x2omi + rec.xli - g22)
                        + rec.d2211 * math.sin(rec.xli - g22)
                        + rec.d3210 * math.sin(xomi + rec.xli - g32)
                        + rec.d3222 * math.sin(-xomi + rec.xli - g32)
                        + rec.d4410 * math.sin(x2omi + x2li - g44)
                        + rec.d4422 * math.sin(x2li - g44)
                        + rec.d5220 * math.sin(xomi + rec.xli - g52)
                        + rec.d5232 * math.sin(-xomi + rec.xli - g52)
                        + rec.d5421 * math.sin(xomi + x2li - g54)
                        + rec.d5433 * math.sin(-xomi + x2li - g54))
                xldot = rec.xni + rec.xfact
                xnddt = (rec.d2201 * math.cos(x2omi + rec.xli - g22)
                         + rec.d2211 * math.cos(rec.xli - g22)
                         + rec.d3210 * math.cos(xomi + rec.xli - g32)
                         + rec.d3222 * math.cos(-xomi + rec.xli - g32)
                         + rec.d5220 * math.cos(xomi + rec.xli - g52)
                         + rec.d5232 * math.cos(-xomi + rec.xli - g52)
                         + 2.0 * (rec.d4410 * math.cos(x2omi + x2li - g44)
                                  + rec.d4422 * math.cos(x2li - g44)
                                  + rec.d5421 * math.cos(xomi + x2li - g54)
                                  + rec.d5433 * math.cos(-xomi + x2li - g54)))
                xnddt = xnddt * xldot

            if abs(t - rec.atime) >= stepp:
                iretn = 381
            else:
                ft = t - rec.atime
                iretn = 0
            if iretn == 381:
                rec.xli = rec.xli + xldot * delt + xndt * step2
                rec.xni = rec.xni + xndt * delt + xnddt * step2
                rec.atime = rec.atime + delt

        nmL = rec.xni + xndt * ft + xnddt * ft * ft * 0.5
        xl = rec.xli + xldot * ft + xndt * ft * ft * 0.5
        if rec.irez != 1:
            mmL = xl - 2.0 * nodemL + 2.0 * theta
        else:
            mmL = xl - nodemL - argpmL + theta
        dndt = nmL - rec.no_unkozai
        nmL = rec.no_unkozai + dndt

    return (emL, argpmL, inclmL, mmL, nmL, nodemL)


# ---------------------------------------------------------------------------
# Swift: SGP4.initialize / propagateCore / propagate


def initialize(tle):
    rec = Rec()
    tumin, mu, radiusearthkm, xke, j2, j3, j4, j3oj2 = wgs72()
    rec.tumin, rec.mu, rec.radiusearthkm = tumin, mu, radiusearthkm
    rec.xke, rec.j2, rec.j3, rec.j4, rec.j3oj2 = xke, j2, j3, j4, j3oj2

    rec.error = 0
    rec.operationmode = "i"
    rec.bstar = tle.bstar
    rec.ndot = tle.ndot
    rec.nddot = tle.nddot
    rec.ecco = tle.ecco
    rec.argpo = tle.argpo
    rec.inclo = tle.inclo
    rec.mo = tle.mo
    rec.no_kozai = tle.no_kozai
    rec.nodeo = tle.nodeo

    ss = 78.0 / rec.radiusearthkm + 1.0
    qzms2ttemp = (120.0 - 78.0) / rec.radiusearthkm
    qzms2t = qzms2ttemp ** 4
    x2o3 = 2.0 / 3.0

    rec.initFlag = "y"
    rec.t = 0.0

    epoch = tle.epoch_jd - 2433281.5
    rec.jdsatepoch = tle.jdsatepoch
    rec.jdsatepochF = tle.jdsatepochF

    (no_out, method, ainv, ao, con41, con42, cosio, cosio2,
     eccsq, omeosq, posq, rp, rteosq, sinio, gsto) = initl(
        rec.xke, rec.j2, rec.ecco, epoch, rec.inclo, rec.no_kozai,
        rec.operationmode)
    rec.no_unkozai = no_out
    rec.method = method
    rec.con41 = con41
    rec.gsto = gsto
    rec.a = (rec.no_unkozai * rec.tumin) ** (-2.0 / 3.0)
    rec.alta = rec.a * (1.0 + rec.ecco) - 1.0
    rec.altp = rec.a * (1.0 - rec.ecco) - 1.0

    if omeosq >= 0.0 or rec.no_unkozai >= 0.0:
        rec.isimp = 0
        if rp < 220.0 / rec.radiusearthkm + 1.0:
            rec.isimp = 1
        sfour = ss
        qzms24 = qzms2t
        perige = (rp - 1.0) * rec.radiusearthkm

        if perige < 156.0:
            sfour = perige - 78.0
            if perige < 98.0:
                sfour = 20.0
            qzms24temp = (120.0 - sfour) / rec.radiusearthkm
            qzms24 = qzms24temp ** 4
            sfour = sfour / rec.radiusearthkm + 1.0

        pinvsq = 1.0 / posq
        tsi = 1.0 / (ao - sfour)
        rec.eta = ao * rec.ecco * tsi
        etasq = rec.eta ** 2
        eeta = rec.ecco * rec.eta
        psisq = abs(1.0 - etasq)
        coef = qzms24 * tsi ** 4.0
        coef1 = coef / psisq ** 3.5
        cc2 = (coef1 * rec.no_unkozai
               * (ao * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq))
                  + 0.375 * rec.j2 * tsi / psisq * rec.con41
                  * (8.0 + 3.0 * etasq * (8.0 + etasq))))
        rec.cc1 = rec.bstar * cc2
        cc3 = 0.0
        if rec.ecco > 1.0e-4:
            cc3 = (-2.0 * coef * tsi * rec.j3oj2 * rec.no_unkozai
                   * sinio / rec.ecco)
        rec.x1mth2 = 1.0 - cosio2
        rec.cc4 = (2.0 * rec.no_unkozai * coef1 * ao * omeosq
                   * (rec.eta * (2.0 + 0.5 * etasq)
                      + rec.ecco * (0.5 + 2.0 * etasq)
                      - rec.j2 * tsi / (ao * psisq)
                      * (-3.0 * rec.con41
                         * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta))
                         + 0.75 * rec.x1mth2
                         * (2.0 * etasq - eeta * (1.0 + etasq))
                         * math.cos(2.0 * rec.argpo))))
        rec.cc5 = (2.0 * coef1 * ao * omeosq
                   * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq))
        cosio4 = cosio2 * cosio2
        temp1 = 1.5 * rec.j2 * pinvsq * rec.no_unkozai
        temp2 = 0.5 * temp1 * rec.j2 * pinvsq
        temp3 = -0.46875 * rec.j4 * pinvsq * pinvsq * rec.no_unkozai
        rec.mdot = (rec.no_unkozai + 0.5 * temp1 * rteosq * rec.con41
                    + 0.0625 * temp2 * rteosq
                    * (13.0 - 78.0 * cosio2 + 137.0 * cosio4))
        rec.argpdot = (-0.5 * temp1 * con42
                       + 0.0625 * temp2
                       * (7.0 - 114.0 * cosio2 + 395.0 * cosio4)
                       + temp3 * (3.0 - 36.0 * cosio2 + 49.0 * cosio4))
        xhdot1 = -temp1 * cosio
        rec.nodedot = (xhdot1 + (0.5 * temp2 * (4.0 - 19.0 * cosio2)
                                 + 2.0 * temp3 * (3.0 - 7.0 * cosio2))
                       * cosio)
        xpidot = rec.argpdot + rec.nodedot
        rec.omgcof = rec.bstar * cc3 * math.cos(rec.argpo)
        rec.xmcof = 0.0
        if rec.ecco > 1.0e-4:
            rec.xmcof = -x2o3 * coef * rec.bstar / eeta
        rec.nodecf = 3.5 * omeosq * xhdot1 * rec.cc1
        rec.t2cof = 1.5 * rec.cc1
        temp4 = 1.5e-12
        if abs(cosio + 1.0) > 1.5e-12:
            rec.xlcof = (-0.25 * rec.j3oj2 * sinio * (3.0 + 5.0 * cosio)
                         / (1.0 + cosio))
        else:
            rec.xlcof = (-0.25 * rec.j3oj2 * sinio * (3.0 + 5.0 * cosio)
                         / temp4)
        rec.aycof = -0.5 * rec.j3oj2 * sinio
        delmotemp = 1.0 + rec.eta * math.cos(rec.mo)
        rec.delmo = delmotemp ** 3
        rec.sinmao = math.sin(rec.mo)
        rec.x7thm1 = 7.0 * cosio2 - 1.0

        if TWOPI / rec.no_unkozai >= 225.0:
            rec.method = "d"
            rec.isimp = 1
            tc = 0.0
            inclm = rec.inclo
            com = dscom(epoch, rec.ecco, rec.argpo, tc, rec.inclo,
                        rec.nodeo, rec.no_unkozai, rec)
            (ep_, inclp_, nodep_, argpp_, mp_) = dpper(
                rec, inclm, rec.initFlag, rec.ecco, rec.inclo,
                rec.nodeo, rec.argpo, rec.mo, rec.operationmode)
            rec.ecco, rec.inclo, rec.nodeo, rec.argpo, rec.mo = \
                ep_, inclp_, nodep_, argpp_, mp_
            dsinit(rec, com, rec.ecco, eccsq, com.em, 0.0, inclm, 0.0,
                   com.nm, 0.0, xpidot, rec.t, tc, rec.gsto, rec.mo,
                   rec.mdot, rec.no_unkozai, rec.nodeo, rec.nodedot,
                   rec.argpo)

        if rec.isimp != 1:
            cc1sq = rec.cc1 * rec.cc1
            rec.d2 = 4.0 * ao * tsi * cc1sq
            temp = rec.d2 * tsi * rec.cc1 / 3.0
            rec.d3 = (17.0 * ao + sfour) * temp
            rec.d4 = (0.5 * temp * ao * tsi * (221.0 * ao + 31.0 * sfour)
                      * rec.cc1)
            rec.t3cof = rec.d2 + 2.0 * cc1sq
            rec.t4cof = 0.25 * (3.0 * rec.d3 + rec.cc1
                                * (12.0 * rec.d2 + 10.0 * cc1sq))
            rec.t5cof = 0.2 * (3.0 * rec.d4 + 12.0 * rec.cc1 * rec.d3
                               + 6.0 * rec.d2 * rec.d2
                               + 15.0 * cc1sq * (2.0 * rec.d2 + cc1sq))

    propagate_core(rec, 0.0)
    rec.initFlag = "n"
    return rec


def propagate_core(rec, tsince):
    temp4 = 1.5e-12
    x2o3 = 2.0 / 3.0
    vkmpersec = rec.radiusearthkm * rec.xke / 60.0

    rec.t = tsince
    rec.error = 0

    xmdf = rec.mo + rec.mdot * rec.t
    argpdf = rec.argpo + rec.argpdot * rec.t
    nodedf = rec.nodeo + rec.nodedot * rec.t
    argpm = argpdf
    mm = xmdf
    t2 = rec.t * rec.t
    nodem = nodedf + rec.nodecf * t2
    tempa = 1.0 - rec.cc1 * rec.t
    tempe = rec.bstar * rec.cc4 * rec.t
    templ = rec.t2cof * t2

    if rec.isimp != 1:
        delomg = rec.omgcof * rec.t
        delmtemp = 1.0 + rec.eta * math.cos(xmdf)
        delm = rec.xmcof * (delmtemp ** 3 - rec.delmo)
        temp = delomg + delm
        mm = xmdf + temp
        argpm = argpdf - temp
        t3 = t2 * rec.t
        t4 = t3 * rec.t
        tempa = tempa - rec.d2 * t2 - rec.d3 * t3 - rec.d4 * t4
        tempe = tempe + rec.bstar * rec.cc5 * (math.sin(mm) - rec.sinmao)
        templ = templ + rec.t3cof * t3 + t4 * (rec.t4cof + rec.t * rec.t5cof)

    nm = rec.no_unkozai
    em = rec.ecco
    inclm = rec.inclo
    if rec.method == "d":
        (em, argpm, inclm, mm, nm, nodem) = dspace(
            rec, rec.t, rec.t, em, argpm, inclm, mm, nm, nodem)

    if nm <= 0.0:
        rec.error = 2
        return None

    am = (rec.xke / nm) ** x2o3 * tempa * tempa
    nm = rec.xke / am ** 1.5
    em = em - tempe

    if em >= 1.0 or em < -0.001:
        rec.error = 1
        return None
    if em < 1.0e-6:
        em = 1.0e-6
    mm = mm + rec.no_unkozai * templ
    xlm = mm + argpm + nodem
    emsq = em * em

    nodem = math.fmod(nodem, TWOPI)
    argpm = fmod_pos(argpm, TWOPI)
    xlm_n = fmod_pos(xlm, TWOPI)
    mm = fmod_pos(xlm_n - argpm - nodem, TWOPI)

    rec.am, rec.em, rec.im = am, em, inclm
    rec.Om, rec.om, rec.mm, rec.nm = nodem, argpm, mm, nm

    sinim = math.sin(inclm)
    cosim = math.cos(inclm)

    ep = em
    xincp = inclm
    argpp = argpm
    nodep = nodem
    mp = mm
    sinip = sinim
    cosip = cosim
    if rec.method == "d":
        (ep, xincp, nodep, argpp, mp) = dpper(
            rec, rec.inclo, "n", ep, xincp, nodep, argpp, mp,
            rec.operationmode)
        if xincp < 0.0:
            xincp = -xincp
            nodep = nodep + PI
            argpp = argpp - PI
        if ep < 0.0 or ep > 1.0:
            rec.error = 3
            return None

    if rec.method == "d":
        sinip = math.sin(xincp)
        cosip = math.cos(xincp)
        rec.aycof = -0.5 * rec.j3oj2 * sinip
        if abs(cosip + 1.0) > 1.5e-12:
            rec.xlcof = (-0.25 * rec.j3oj2 * sinip * (3.0 + 5.0 * cosip)
                         / (1.0 + cosip))
        else:
            rec.xlcof = (-0.25 * rec.j3oj2 * sinip * (3.0 + 5.0 * cosip)
                         / temp4)

    axnl = ep * math.cos(argpp)
    temp_a = 1.0 / (am * (1.0 - ep * ep))
    aynl = ep * math.sin(argpp) + temp_a * rec.aycof
    xl = mp + argpp + nodep + temp_a * rec.xlcof * axnl

    u = fmod_pos(xl - nodep, TWOPI)
    eo1 = u
    tem5 = 9999.9
    ktr = 1
    while abs(tem5) >= 1.0e-12 and ktr <= 10:
        sineo1 = math.sin(eo1)
        coseo1 = math.cos(eo1)
        tem5 = 1.0 - coseo1 * axnl - sineo1 * aynl
        tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
        if abs(tem5) >= 0.95:
            tem5 = 0.95 if tem5 > 0.0 else -0.95
        eo1 = eo1 + tem5
        ktr = ktr + 1

    coseo1 = math.cos(eo1)
    sineo1 = math.sin(eo1)
    ecose = axnl * coseo1 + aynl * sineo1
    esine = axnl * sineo1 - aynl * coseo1
    el2 = axnl * axnl + aynl * aynl
    pl = am * (1.0 - el2)
    if pl < 0.0:
        rec.error = 4
        return None

    rl = am * (1.0 - ecose)
    rdotl = math.sqrt(am) * esine / rl
    rvdotl = math.sqrt(pl) / rl
    betal = math.sqrt(1.0 - el2)
    temp_b = esine / (1.0 + betal)
    sinu = am / rl * (sineo1 - aynl - axnl * temp_b)
    cosu = am / rl * (coseo1 - axnl + aynl * temp_b)
    su = math.atan2(sinu, cosu)
    sin2u = (cosu + cosu) * sinu
    cos2u = 1.0 - 2.0 * sinu * sinu
    temp_c = 1.0 / pl
    temp1 = 0.5 * rec.j2 * temp_c
    temp2 = temp1 * temp_c

    if rec.method == "d":
        cosisq = cosip * cosip
        rec.con41 = 3.0 * cosisq - 1.0
        rec.x1mth2 = 1.0 - cosisq
        rec.x7thm1 = 7.0 * cosisq - 1.0

    mrt = (rl * (1.0 - 1.5 * temp2 * betal * rec.con41)
           + 0.5 * temp1 * rec.x1mth2 * cos2u)
    su_adj = su - 0.25 * temp2 * rec.x7thm1 * sin2u
    xnode = nodep + 1.5 * temp2 * cosip * sin2u
    xinc = xincp + 1.5 * temp2 * cosip * sinip * cos2u
    mvt = rdotl - nm * temp1 * rec.x1mth2 * sin2u / rec.xke
    rvdot = (rvdotl + nm * temp1 * (rec.x1mth2 * cos2u + 1.5 * rec.con41)
             / rec.xke)

    sinsu = math.sin(su_adj)
    cossu = math.cos(su_adj)
    snod = math.sin(xnode)
    cnod = math.cos(xnode)
    sini = math.sin(xinc)
    cosi = math.cos(xinc)
    xmx = -snod * cosi
    xmy = cnod * cosi
    ux = xmx * sinsu + cnod * cossu
    uy = xmy * sinsu + snod * cossu
    uz = sini * sinsu
    vx = xmx * cossu - cnod * sinsu
    vy = xmy * cossu - snod * sinsu
    vz = sini * cossu

    mr = mrt * rec.radiusearthkm
    r = (mr * ux, mr * uy, mr * uz)
    v = ((mvt * ux + rvdot * vx) * vkmpersec,
         (mvt * uy + rvdot * vy) * vkmpersec,
         (mvt * uz + rvdot * vz) * vkmpersec)
    if mrt < 1.0:
        rec.error = 6
    return (r, v)


def propagate(tle, minutes_since_epoch):
    rec = initialize(tle)
    st = propagate_core(rec, minutes_since_epoch)
    if st is None:
        nan = float("nan")
        return ((nan, nan, nan), (nan, nan, nan))
    return st

# ---------------------------------------------------------------------------
# Swift: AstroMath (needed pieces, translated for the chain validation)


def julian_date_unix(ts):
    return ts / 86400.0 + 2440587.5


def gmst_degrees(jd):
    t = (jd - 2451545.0) / 36525.0
    g = (280.46061837 + 360.98564736629 * (jd - 2451545.0)
         + 0.000387933 * t * t - t * t * t / 38710000.0)
    return g % 360.0


def norm180(x):
    v = x % 360.0
    if v > 180.0:
        v -= 360.0
    return v


def lst_degrees(jd, lon):
    return (gmst_degrees(jd) + lon) % 360.0


def alt_az(ra, dec, jd, lat, lon):
    h = norm180(lst_degrees(jd, lon) - ra) * DEG2RAD
    dec_r = dec * DEG2RAD
    lat_r = lat * DEG2RAD
    sin_alt = (math.sin(dec_r) * math.sin(lat_r)
               + math.cos(dec_r) * math.cos(lat_r) * math.cos(h))
    alt = math.asin(max(-1.0, min(1.0, sin_alt))) * RAD2DEG
    y = math.sin(h)
    x = math.cos(h) * math.sin(lat_r) - math.tan(dec_r) * math.cos(lat_r)
    az = (math.atan2(y, x) * RAD2DEG + 180.0) % 360.0
    return (alt, az)


def sun_ecliptic_longitude(jd):
    d = jd - 2451543.5
    w = (282.9404 + 4.70935e-5 * d) * DEG2RAD
    e = 0.016709 - 1.151e-9 * d
    m = (356.0470 + 0.9856002585 * d) * DEG2RAD
    E = m + e * math.sin(m) * (1.0 + e * math.cos(m))
    for _ in range(2):
        E -= (E - e * math.sin(E) - m) / (1.0 - e * math.cos(E))
    xv = math.cos(E) - e
    yv = math.sqrt(1.0 - e * e) * math.sin(E)
    v = math.atan2(yv, xv) * RAD2DEG
    return (v + w * RAD2DEG) % 360.0


def sun_ra_dec(jd):
    lon = sun_ecliptic_longitude(jd) * DEG2RAD
    d = jd - 2451543.5
    oblecl = (23.4393 - 3.563e-7 * d) * DEG2RAD
    ra = math.atan2(math.sin(lon) * math.cos(oblecl), math.cos(lon)) * RAD2DEG
    dec = math.asin(max(-1.0, min(1.0, math.sin(lon) * math.sin(oblecl)))) \
        * RAD2DEG
    return (ra % 360.0, dec)


# ---------------------------------------------------------------------------
# Swift: SatelliteMath (translated)


def sat_alt_az(r_teme, jd, lat, lon):
    theta = gmst_degrees(jd) * DEG2RAD
    c, s = math.cos(theta), math.sin(theta)
    x = c * r_teme[0] + s * r_teme[1]
    y = -s * r_teme[0] + c * r_teme[1]
    z = r_teme[2]
    lat_r = lat * DEG2RAD
    lon_r = lon * DEG2RAD
    a = 6378.137
    f = 1.0 / 298.257223563
    e2 = f * (2.0 - f)
    slat = math.sin(lat_r)
    n = a / math.sqrt(1.0 - e2 * slat * slat)
    ox = n * math.cos(lat_r) * math.cos(lon_r)
    oy = n * math.cos(lat_r) * math.sin(lon_r)
    oz = n * (1.0 - e2) * slat
    rx, ry, rz = x - ox, y - oy, z - oz
    clat = math.cos(lat_r)
    slon, clon = math.sin(lon_r), math.cos(lon_r)
    east = -slon * rx + clon * ry
    north = -slat * clon * rx - slat * slon * ry + clat * rz
    up = clat * clon * rx + clat * slon * ry + slat * rz
    rng = math.sqrt(rx * rx + ry * ry + rz * rz)
    alt = math.asin(max(-1.0, min(1.0, up / rng))) * RAD2DEG
    az = math.atan2(east, north) * RAD2DEG
    if az < 0:
        az += 360.0
    return (alt, az)


def sat_is_sunlit(teme, jd):
    ra, dec = sun_ra_dec(jd)
    ra_r, dec_r = ra * DEG2RAD, dec * DEG2RAD
    shat = (math.cos(dec_r) * math.cos(ra_r),
            math.cos(dec_r) * math.sin(ra_r),
            math.sin(dec_r))
    d = teme[0] * shat[0] + teme[1] * shat[1] + teme[2] * shat[2]
    if d >= 0:
        return True
    r2 = teme[0] ** 2 + teme[1] ** 2 + teme[2] ** 2
    perp2 = r2 - d * d
    return perp2 >= 6378.137 ** 2


# ---------------------------------------------------------------------------
# Test 1: SGP4 truth table (3 sats x 5 timestamps)

print("=== Test 1: SGP4 vs python-sgp4 truth table ===")
truth = json.load(open("sgp4_truth.json"))
from sgp4.api import jday as ref_jday
max_pos_err = 0.0
max_vel_err = 0.0
worst = None
n_pts = 0
for sat in truth["satellites"]:
    tle = TLE(sat["name"], sat["line1"], sat["line2"])
    rec = initialize(tle)
    for pt in sat["points"]:
        n_pts += 1
        # (jd, fr) exactly as the reference builds them from calendar
        # fields — never a re-split single double.
        dt = datetime.datetime.fromisoformat(
            pt["iso"].replace("Z", "+00:00"))
        jd, fr = ref_jday(dt.year, dt.month, dt.day,
                          dt.hour, dt.minute, float(dt.second))
        tsince = ((jd - tle.jdsatepoch) + (fr - tle.jdsatepochF)) * 1440.0
        (r, v) = propagate_core(rec, tsince)
        assert r is not None, f"propagation failed for {sat['name']}"
        pe = math.sqrt(sum((a - b) ** 2 for a, b in zip(r, pt["r"])))
        ve = math.sqrt(sum((a - b) ** 2 for a, b in zip(v, pt["v"])))
        if pe > max_pos_err:
            max_pos_err, worst = pe, (sat["name"], pt["iso"], "pos")
        if ve > max_vel_err:
            max_vel_err, worst = ve, (sat["name"], pt["iso"], "vel")
print(f"points tested : {n_pts}")
print(f"max pos error : {max_pos_err:.3e} km  {worst if max_pos_err >= max_vel_err else ''}")
print(f"max vel error : {max_vel_err:.3e} km/s")
print("GATE (<1e-6 km):", "PASS" if max_pos_err < 1e-6 and max_vel_err < 1e-6 else "FAIL")

# ---------------------------------------------------------------------------
# Test 2: TEME->topocentric chain vs Skyfield (independent implementation)
print()
print("=== Test 2: topocentric chain vs Skyfield ===")
try:
    from skyfield.api import load, EarthSatellite, Topos
    ts = load.timescale()
    # Stratford, Ontario
    lat0, lon0 = 43.3700, -80.9800
    observer = Topos(latitude_degrees=lat0, longitude_degrees=lon0)
    max_alt_err = 0.0
    max_az_err = 0.0
    for sat in truth["satellites"]:
        sf_sat = EarthSatellite(sat["line1"], sat["line2"], sat["name"], ts)
        tle = TLE(sat["name"], sat["line1"], sat["line2"])
        rec = initialize(tle)
        for pt in sat["points"]:
            dt = datetime.datetime.fromisoformat(
                pt["iso"].replace("Z", "+00:00"))
            jd, fr = ref_jday(dt.year, dt.month, dt.day,
                              dt.hour, dt.minute, float(dt.second))
            tsince = ((jd - tle.jdsatepoch) + (fr - tle.jdsatepochF)) * 1440.0
            (r, v) = propagate_core(rec, tsince)
            my_alt, my_az = sat_alt_az(r, pt["jd"], lat0, lon0)
            t = ts.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute,
                       dt.second)
            diff = (sf_sat - observer).at(t)
            alt, az, _d = diff.altaz()
            alt_e = abs(my_alt - alt.degrees)
            az_e = abs((my_az - az.degrees + 180) % 360 - 180)
            max_alt_err = max(max_alt_err, alt_e)
            max_az_err = max(max_az_err, az_e)
    print(f"max alt disagreement: {max_alt_err:.4f} deg")
    print(f"max az  disagreement: {max_az_err:.4f} deg")
    print("GATE (<0.25 deg):",
          "PASS" if max_alt_err < 0.25 and max_az_err < 0.25 else "FAIL")
except ImportError:
    print("skyfield not available - SKIPPED")

# ---------------------------------------------------------------------------
# Test 3: sub-satellite-point sanity (el ~ 90 deg at subpoint)
# Rigorous version: convert the satellite's ECEF position to geodetic
# (lat, lon) by iteration; an observer at (lat, lon, h=0) then has the
# satellite exactly at the zenith by construction of geodetic coords.
print()
print("=== Test 3: sub-satellite point -> el ~= 90 deg ===")
_a = 6378.137
_e2 = (1.0 / 298.257223563) * (2.0 - 1.0 / 298.257223563)
worst_el = 90.0
for sat in truth["satellites"]:
    for pt in sat["points"]:
        r = pt["r"]
        jd = pt["jd"]
        theta = gmst_degrees(jd) * DEG2RAD
        c, s = math.cos(theta), math.sin(theta)
        x = c * r[0] + s * r[1]
        y = -s * r[0] + c * r[1]
        z = r[2]
        p = math.sqrt(x * x + y * y)
        phi = math.atan2(z, p * (1.0 - _e2))
        for _ in range(4):
            n_ = _a / math.sqrt(1.0 - _e2 * math.sin(phi) ** 2)
            h_ = p / math.cos(phi) - n_
            phi = math.atan2(z, p * (1.0 - _e2 * n_ / (n_ + h_)))
        slat = math.degrees(phi)
        slon = math.degrees(math.atan2(y, x))
        el, _az = sat_alt_az(r, jd, slat, slon)
        worst_el = min(worst_el, el)
print(f"min elevation at sub-satellite point: {worst_el:.6f} deg "
      f"(expect ~90)")
print("GATE (>89.99 deg):", "PASS" if worst_el > 89.99 else "FAIL")

# ---------------------------------------------------------------------------
# Test 4: cylindrical shadow sanity - eclipse fraction over one ISS orbit
print()
print("=== Test 4: shadow test sanity (ISS eclipse fraction) ===")
sat = truth["satellites"][0]
tle = TLE(sat["name"], sat["line1"], sat["line2"])
rec = initialize(tle)
jd0 = sat["points"][2]["jd"]
eclipsed = 0
total = 0
for k in range(0, 6000, 30):  # 50 h in 30 s steps
    jd = jd0 + k / 86400.0
    jd_whole = math.floor(jd - 0.5) + 0.5
    jd_frac = jd - jd_whole
    tsince = ((jd_whole - tle.jdsatepoch)
              + (jd_frac - tle.jdsatepochF)) * 1440.0
    (r, v) = propagate_core(rec, tsince)
    if r is None:
        continue
    total += 1
    if not sat_is_sunlit(r, jd):
        eclipsed += 1
frac = eclipsed / total
print(f"eclipsed {eclipsed}/{total} samples = {frac:.1%} "
      f"(ISS typically ~35-45%)")
print("GATE (25-55%):", "PASS" if 0.25 <= frac <= 0.55 else "FAIL")
